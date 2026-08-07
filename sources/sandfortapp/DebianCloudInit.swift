// Copyright 2026 Shazron Abdullah and Sandfort contributors
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

enum DebianCloudInit {
    static func credentials() -> SandboxCredentials {
        GuestProvisioningSupport.credentials()
    }

    static func credentials(password: String) throws -> SandboxCredentials {
        try GuestProvisioningSupport.credentials(password: password)
    }

    static func seedISO(
        credentials: SandboxCredentials,
        tools: SandboxToolSelection = .recommended,
        hardware: LinuxGuestProfile.Hardware
    ) throws -> Data {
        var packages = [
            "apparmor", "ca-certificates", "curl", "git", "jq", "network-manager",
            "qemu-guest-agent", "spice-vdagent", "task-gnome-desktop", "ufw",
            "unattended-upgrades"
        ]
        if tools.python { packages += ["python3", "python3-pip", "python3-venv"] }
        if tools.nodeJS { packages += ["xz-utils"] }
        let packageList = packages.map { "  - \($0)" }.joined(separator: "\n")
        let customSetup = try GuestProvisioningSupport.customSetupScript(from: tools.customSetupScript)
        let customWriteFile = customSetup?.writeFileEntry ?? ""
        let customCommand = customSetup?.command ?? ""
        var verificationCommands = [
            "command -v git", "command -v curl", "command -v jq",
            "dpkg-query -W task-gnome-desktop", "dpkg-query -W gdm3",
            "dpkg-query -W network-manager", "dpkg-query -W qemu-guest-agent",
            "dpkg-query -W spice-vdagent", "dpkg-query -W ufw",
            "dpkg-query -W unattended-upgrades", "test -x /usr/sbin/gdm3"
        ]
        if tools.python {
            verificationCommands += ["command -v python3", "command -v pip3", "python3 -m venv --help >/dev/null"]
        }
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
            linuxArchiveArchitecture: hardware.linuxArchiveArchitecture
        )
        let vsCodeInstallCommands = GuestProvisioningSupport.vsCodeInstallCommands(
            enabled: tools.installsVSCode,
            linuxArchiveArchitecture: hardware.linuxArchiveArchitecture
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
          systemctl unmask --runtime serial-getty@\(hardware.serialConsoleDevice).service
          systemctl start serial-getty@\(hardware.serialConsoleDevice).service
          exit "$result"
        }
        trap setup_failed ERR
        set -x
        export DEBIAN_FRONTEND=noninteractive
        export APT_LISTCHANGES_FRONTEND=none
        installed=false
        for attempt in 1 2 3; do
          status "Installing and updating Debian baseline packages (attempt $attempt of 3). This can take 20-45 minutes."
          if apt-get update \
            && apt-get upgrade -y \
            && apt-get install -y \(packages.joined(separator: " ")); then
            installed=true
            break
          fi
          status "Package attempt $attempt failed; waiting 15 seconds before retrying."
          sleep 15
        done
        if [[ "$installed" != true ]]; then
          status "ERROR: Debian packages could not be installed. The VM will remain on and no baseline will be created."
          false
        fi
        \(nodeInstallCommands)
        \(vsCodeInstallCommands)
        status "Verifying every selected tool and the Debian GNOME desktop."
        \(verificationCommands.joined(separator: "\n"))
        status "Applying Debian sandbox security settings."
        systemctl disable --now ssh.service ssh.socket || true
        systemctl mask ssh.service ssh.socket
        status "Installing a MAC-independent DHCP profile for disposable instances."
        chmod 0600 /etc/NetworkManager/system-connections/sandfort.nmconnection
        rm -f /etc/netplan/*.yaml
        rm -f /run/udev/rules.d/90-netplan.rules /run/udev/rules.d/99-netplan-*.rules
        rm -f /etc/network/interfaces.d/50-cloud-init
        printf 'auto lo\niface lo inet loopback\n' > /etc/network/interfaces
        systemctl disable networking.service || true
        systemctl enable NetworkManager.service
        # Debian's cloud image runs systemd-networkd alongside the NetworkManager
        # this profile installs. NetworkManager owns the interface, networkd
        # manages nothing, and its wait-online still blocks network-online.target
        # for its full 120-second timeout on an offline instance. That delayed
        # cloud-init-network and every target after it, so a clean instance sat
        # on a blank console for over two minutes before the greeter appeared.
        # Ubuntu has masked both since its own profile was written.
        status "Removing the unnecessary network wait from clean-session startup."
        systemctl mask systemd-networkd-wait-online.service
        systemctl mask NetworkManager-wait-online.service
        grep -Fq 'id=sandfort' /etc/NetworkManager/system-connections/sandfort.nmconnection
        grep -Fq 'type=ethernet' /etc/NetworkManager/system-connections/sandfort.nmconnection
        grep -Fq 'method=auto' /etc/NetworkManager/system-connections/sandfort.nmconnection
        if grep -Eiq 'mac-address|interface-name' /etc/NetworkManager/system-connections/sandfort.nmconnection; then
          status "ERROR: The Debian network profile is unexpectedly tied to one virtual NIC."
          false
        fi
        systemctl enable qemu-guest-agent.service
        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable
        ufw status | grep -Fq 'Status: active'
        ufw status verbose | grep -Fq 'Default: deny (incoming), allow (outgoing)'
        aa-enabled
        systemctl enable unattended-upgrades.service
        systemctl is-enabled --quiet unattended-upgrades.service
        systemctl set-default graphical.target
        printf '%s\n' /usr/sbin/gdm3 > /etc/X11/default-display-manager
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
        systemctl is-enabled --quiet qemu-guest-agent.service
        systemctl is-enabled --quiet NetworkManager.service
        if systemctl is-enabled --quiet ssh.service || systemctl is-enabled --quiet ssh.socket; then
          status "ERROR: SSH is still enabled."
          false
        fi
        if systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket; then
          status "ERROR: SSH is still running."
          false
        fi
        \(customCommand.isEmpty ? "" : "status \"Running the custom baseline setup script.\"")
        \(customCommand)
        status "Preparing a fast, clean Debian baseline: compacting journals and package caches."
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
          - [systemctl, mask, --runtime, --now, serial-getty@\(hardware.serialConsoleDevice).service]
          - [sh, -c, "echo '[Sandfort] Debian baseline setup has started. Leave this VM running until it powers itself off automatically. Installation commonly takes 20-45 minutes.' > /dev/console"]
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
          - path: /etc/apt/apt.conf.d/20auto-upgrades
            permissions: '0644'
            content: |
              APT::Periodic::Update-Package-Lists "1";
              APT::Periodic::Unattended-Upgrade "1";
          - path: /etc/NetworkManager/conf.d/10-sandfort.conf
            permissions: '0644'
            content: |
              [ifupdown]
              managed=true
          - path: /etc/cloud/cloud.cfg.d/99-sandfort-disable-network-config.cfg
            permissions: '0644'
            content: |
              network: {config: disabled}
          - path: /etc/NetworkManager/system-connections/sandfort.nmconnection
            permissions: '0600'
            content: |
              [connection]
              id=sandfort
              type=ethernet
              autoconnect=true
              autoconnect-priority=100

              [ethernet]

              [ipv4]
              method=auto

              [ipv6]
              addr-gen-mode=default
              method=auto

              [proxy]
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
          message: Debian sandbox setup verified; powering off for baseline creation
          timeout: 30
          condition: [test, -f, \(GuestProvisioningSupport.completionMarkerPath)]
        final_message: Debian sandbox setup complete after $UPTIME seconds
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
