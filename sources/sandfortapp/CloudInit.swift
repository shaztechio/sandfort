// Copyright 2026 Sandfort contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

enum UbuntuCloudInit {
    static func credentials() -> SandboxCredentials {
        GuestProvisioningSupport.credentials()
    }

    static func credentials(password: String) throws -> SandboxCredentials {
        try GuestProvisioningSupport.credentials(password: password)
    }

    static func seedISO(
        credentials: SandboxCredentials,
        tools: SandboxToolSelection = .recommended
    ) throws -> Data {
        var packages = [
            "ubuntu-desktop-minimal", "curl", "git", "jq",
            "qemu-guest-agent", "spice-vdagent", "ufw", "unattended-upgrades"
        ]
        if tools.python { packages += ["python3", "python3-pip", "python3-venv"] }
        if tools.nodeJS { packages += ["ca-certificates", "xz-utils"] }
        let packageList = packages.map { "  - \($0)" }.joined(separator: "\n")
        let customSetup = try GuestProvisioningSupport.customSetupScript(from: tools.customSetupScript)
        let customWriteFile = customSetup?.writeFileEntry ?? ""
        let customCommand = customSetup?.command ?? ""
        var verificationCommands = [
            "command -v git", "command -v curl", "command -v jq",
            "dpkg-query -W ubuntu-desktop-minimal", "dpkg-query -W qemu-guest-agent",
            "dpkg-query -W spice-vdagent", "dpkg-query -W gdm3", "test -x /usr/sbin/gdm3"
        ]
        if tools.python { verificationCommands += ["command -v python3", "command -v pip3"] }
        if tools.nodeJS { verificationCommands += ["command -v node", "command -v npm"] }
        verificationCommands += [
            GuestProvisioningSupport.terminalVerificationCommand,
            GuestProvisioningSupport.browserVerificationCommand
        ]
        if tools.installsVSCode { verificationCommands.append("command -v code") }
        let loggingSetup = tools.verboseSetupLogging == true ? """
        exec > >(tee -a /var/log/sandfort-setup.log) 2>&1
        status() { printf '\n[Sandfort] %s\n' "$*"; }
        """ : """
        exec 3>&1
        exec >> /var/log/sandfort-setup.log 2>&1
        status() {
          printf '\n[Sandfort] %s\n' "$*" >&3
          printf '\n[Sandfort] %s\n' "$*"
        }
        """
        let nodeInstallCommands = GuestProvisioningSupport.nodeLTSInstallCommands(
            enabled: tools.nodeJS,
            linuxArchiveArchitecture: "arm64"
        )
        let vsCodeInstallCommands = GuestProvisioningSupport.vsCodeInstallCommands(
            enabled: tools.installsVSCode,
            linuxArchiveArchitecture: "arm64"
        )
        let finalizerScript = """
        #!/usr/bin/env bash
        set -Eeuo pipefail
        \(loggingSetup)
        setup_failed() {
          result=$?
          trap - ERR
          set +e
          status "ERROR: Setup failed. The VM will remain on; enabling the sandbox login prompt for diagnostics."
          systemctl unmask --runtime serial-getty@ttyAMA0.service
          systemctl start serial-getty@ttyAMA0.service
          exit "$result"
        }
        trap setup_failed ERR
        set -x
        export DEBIAN_FRONTEND=noninteractive
        installed=false
        for attempt in 1 2 3; do
          status "Installing and updating baseline packages (attempt $attempt of 3). This can take 10-30 minutes."
          if apt-get update && apt-get upgrade -y && apt-get install -y \(packages.joined(separator: " ")); then
            installed=true
            break
          fi
          status "Package attempt $attempt failed; waiting 15 seconds before retrying."
          sleep 15
        done
        if [[ "$installed" != true ]]; then
          status "ERROR: Packages could not be installed. The VM will remain on and no baseline will be created."
          false
        fi
        \(nodeInstallCommands)
        \(vsCodeInstallCommands)
        status "Verifying every selected tool and the graphical desktop."
        \(verificationCommands.joined(separator: "\n"))
        status "Applying sandbox security settings."
        systemctl disable --now ssh.service || true
        status "Removing Ubuntu's unnecessary network wait from clean-session startup."
        systemctl mask systemd-networkd-wait-online.service
        systemctl mask NetworkManager-wait-online.service
        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable
        systemctl enable qemu-guest-agent.service
        systemctl set-default graphical.target
        printf '%s\\n' /usr/sbin/gdm3 > /etc/X11/default-display-manager
        systemctl unmask gdm3.service
        systemctl enable gdm3.service
        systemctl is-enabled --quiet gdm3.service
        status "Leaving VT1 to the graphical login so no console login prompt appears."
        # Instances have a display and no serial device, so getty@tty1 would park
        # a text "login:" prompt on the framebuffer until the greeter starts and
        # look like the only way in. Masking just this instance keeps VT1 free;
        # logind still spawns autovt@tty2..6 on demand, so Ctrl+Alt+F2 remains
        # available if the desktop ever fails to come up.
        systemctl mask getty@tty1.service
        test "$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)" = masked
        \(customCommand.isEmpty ? "" : "status \"Running the custom baseline setup script.\"")
        \(customCommand)
        status "Preparing a fast, clean baseline: compacting journals and package caches."
        apt-get clean
        journalctl --rotate
        journalctl --vacuum-size=16M
        systemctl mask systemd-journal-flush.service
        systemctl restart systemd-journald.service
        sync
        touch \(GuestProvisioningSupport.completionMarkerPath)
        trap - ERR
        status "Setup verified successfully. The VM will power off automatically; then click Finish Setup in the app."
        """
        let encodedFinalizer = Data(finalizerScript.utf8).base64EncodedString()
        let userData = """
        #cloud-config
        hostname: sandfort
        manage_etc_hosts: true
        disable_root: true
        ssh_pwauth: false
        users:
          - name: \(credentials.username)
            gecos: Sandbox User
            groups: [adm, sudo]
            shell: /bin/bash
            lock_passwd: false
            sudo: "ALL=(ALL) ALL"
        chpasswd:
          expire: false
          users:
            - name: \(credentials.username)
              password: '\(GuestProvisioningSupport.yamlSingleQuoted(credentials.password))'
              type: text
        bootcmd:
          - [systemctl, mask, --runtime, --now, serial-getty@ttyAMA0.service]
          - [sh, -c, "echo '[Sandfort] Baseline setup has started. Leave this VM running until it powers itself off automatically. Installation commonly takes 10-30 minutes.' > /dev/console"]
        # sandfort packages:
        \(packageList.replacingOccurrences(of: "  - ", with: "#   - "))
        write_files:
          - path: /etc/systemd/journald.conf.d/sandfort.conf
            permissions: '0644'
            content: |
              [Journal]
              Storage=volatile
              RuntimeMaxUse=16M
          - path: /etc/motd
            permissions: '0644'
            content: |
        \(GuestProvisioningSupport.indented(GuestProvisioningSupport.motd, spaces: 14))
          - path: /var/lib/sandfort/baseline-finalize.sh
            permissions: '0700'
            encoding: b64
            content: \(encodedFinalizer)
        \(customWriteFile)
        runcmd:
          - [bash, /var/lib/sandfort/baseline-finalize.sh]
        power_state:
          mode: poweroff
          message: Sandbox setup verified; powering off for baseline creation
          timeout: 30
          condition: [test, -f, \(GuestProvisioningSupport.completionMarkerPath)]
        final_message: Sandbox setup complete after $UPTIME seconds
        """
        let metaData = """
        instance-id: sandfort-\(UUID().uuidString.lowercased())
        local-hostname: sandfort
        """
        return try ISO9660Writer.make(volumeName: "cidata", files: [
            ("user-data", Data(userData.utf8)),
            ("meta-data", Data(metaData.utf8))
        ])
    }

}
