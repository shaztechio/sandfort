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

enum FedoraCloudInit {
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
            "ca-certificates", "curl", "dnf5-plugin-automatic", "firewalld",
            "gdm", "git", "jq", "NetworkManager", "policycoreutils",
            "qemu-guest-agent", "spice-vdagent"
        ]
        if tools.python { packages += ["python3", "python3-pip"] }
        if tools.nodeJS { packages += ["xz"] }
        let packageList = packages.map { "  - \($0)" }.joined(separator: "\n")
        let customSetup = try GuestProvisioningSupport.customSetupScript(from: tools.customSetupScript)
        let customWriteFile = customSetup?.writeFileEntry ?? ""
        let customCommand = customSetup?.command ?? ""
        var verificationCommands = [
            "command -v git", "command -v curl", "command -v jq",
            "rpm -q gdm", "rpm -q gnome-shell", "rpm -q NetworkManager",
            "rpm -q qemu-guest-agent", "rpm -q spice-vdagent",
            "rpm -q firewalld", "rpm -q dnf5-plugin-automatic",
            "test -x /usr/sbin/gdm"
        ]
        if tools.python {
            verificationCommands += ["command -v python3", "command -v pip3", "python3 -m venv --help >/dev/null"]
        }
        if tools.nodeJS { verificationCommands += ["command -v node", "command -v npm"] }
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
        export LANG=C.UTF-8
        installed=false
        for attempt in 1 2 3; do
          status "Installing and updating Fedora baseline packages (attempt $attempt of 3). This can take 20-45 minutes."
          if dnf5 -y upgrade --refresh \
            && dnf5 -y install \(packages.joined(separator: " ")) \
            && dnf5 -y environment install workstation-product-environment; then
            installed=true
            break
          fi
          status "Package attempt $attempt failed; waiting 15 seconds before retrying."
          sleep 15
        done
        if [[ "$installed" != true ]]; then
          status "ERROR: Fedora packages could not be installed. The VM will remain on and no baseline will be created."
          false
        fi
        \(nodeInstallCommands)
        status "Verifying every selected tool and the Fedora Workstation desktop."
        dnf5 environment info workstation-product-environment | grep -Eq '^Installed[[:space:]]*:[[:space:]]*(True|yes)$'
        \(verificationCommands.joined(separator: "\n"))
        status "Applying Fedora sandbox security settings."
        systemctl disable --now sshd.service sshd.socket || true
        systemctl mask sshd.service sshd.socket
        systemctl enable NetworkManager.service
        systemctl enable qemu-guest-agent.service
        systemctl enable --now firewalld.service
        firewall-cmd --set-default-zone=sandfort
        firewall-cmd --reload
        test "$(firewall-cmd --get-default-zone)" = sandfort
        test -z "$(firewall-cmd --zone=sandfort --list-services)"
        test -z "$(firewall-cmd --zone=sandfort --list-ports)"
        if firewall-cmd --zone=sandfort --query-service=ssh; then
          status "ERROR: The Fedora firewall unexpectedly allows SSH."
          false
        fi
        test "$(getenforce)" = Enforcing
        systemctl enable dnf5-automatic.timer
        systemctl is-enabled --quiet dnf5-automatic.timer
        systemctl set-default graphical.target
        systemctl enable gdm.service
        systemctl is-enabled --quiet gdm.service
        status "Leaving VT1 to the graphical login so no console login prompt appears."
        # Instances have a display and no serial device, so getty@tty1 would park
        # a text "login:" prompt on the framebuffer until the greeter starts and
        # look like the only way in. Masking just this instance keeps VT1 free;
        # logind still spawns autovt@tty2..6 on demand, so Ctrl+Alt+F2 remains
        # available if the desktop ever fails to come up.
        systemctl mask getty@tty1.service
        test "$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)" = masked
        systemctl is-enabled --quiet firewalld.service
        systemctl is-active --quiet firewalld.service
        systemctl is-enabled --quiet qemu-guest-agent.service
        systemctl is-enabled --quiet NetworkManager.service
        if systemctl is-enabled --quiet sshd.service || systemctl is-enabled --quiet sshd.socket; then
          status "ERROR: SSH is still enabled."
          false
        fi
        if systemctl is-active --quiet sshd.service || systemctl is-active --quiet sshd.socket; then
          status "ERROR: SSH is still running."
          false
        fi
        \(customCommand.isEmpty ? "" : "status \"Running the custom baseline setup script.\"")
        \(customCommand)
        status "Preparing a fast, clean Fedora baseline: compacting journals and package caches."
        dnf5 clean all
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
            groups: [wheel]
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
          - [sh, -c, "echo '[Sandfort] Fedora baseline setup has started. Leave this VM running until it powers itself off automatically. Installation commonly takes 20-45 minutes.' > /dev/console"]
        # sandfort packages:
        \(packageList.replacingOccurrences(of: "  - ", with: "#   - "))
        write_files:
          - path: /etc/systemd/journald.conf.d/sandfort.conf
            permissions: '0644'
            content: |
              [Journal]
              Storage=volatile
              RuntimeMaxUse=16M
          - path: /etc/ssh/sshd_config.d/99-sandfort.conf
            permissions: '0644'
            content: |
              PasswordAuthentication no
              PermitRootLogin no
              AllowTcpForwarding no
          - path: /etc/firewalld/zones/sandfort.xml
            permissions: '0644'
            content: |
              <?xml version="1.0" encoding="utf-8"?>
              <zone target="DROP">
                <short>Sandfort</short>
                <description>Blocks unsolicited inbound sandbox traffic.</description>
              </zone>
          - path: /etc/dnf/automatic.conf
            permissions: '0644'
            content: |
              [commands]
              upgrade_type = security
              download_updates = true
              apply_updates = true
              random_sleep = 900
              reboot = never
              [emitters]
              emit_via = motd
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
          message: Fedora sandbox setup verified; powering off for baseline creation
          timeout: 30
          condition: [test, -f, \(GuestProvisioningSupport.completionMarkerPath)]
        final_message: Fedora sandbox setup complete after $UPTIME seconds
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
