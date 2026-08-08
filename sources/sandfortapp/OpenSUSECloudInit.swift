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

enum OpenSUSECloudInit {
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
        // Leap's GNOME pattern pulls in no browser: `patterns-gnome-gnome`
        // requires only `gnome-session-wayland` and declares no recommends, and
        // `patterns-gnome-gnome_internet` would add Evolution, Polari, and a
        // BitTorrent client that a disposable sandbox must not ship. Firefox is
        // therefore requested explicitly. Its branding capability has two
        // providers, so pin the openSUSE one rather than leave the unattended
        // solver to choose.
        //
        // The same pattern ships no terminal emulator either: `gnome-console` is
        // recommended only by `patterns-gnome-gnome_basis`, which nothing pulls
        // in. GNOME Terminal is requested explicitly so the desktop is usable.
        var packages = [
            "ca-certificates", "curl", "firewalld", "gdm", "git-core", "gnome-shell",
            "gnome-terminal", "gvfs", "jq", "MozillaFirefox",
            "MozillaFirefox-branding-openSUSE",
            // Leap's GNOME pattern declares no recommends, so a desktop built
            // from it has no file manager — the third omission of that shape
            // after the browser and the terminal. Without one there is no way to
            // open anything from the desktop, materials included. gvfs and
            // udisks2 are named explicitly for the same reason: nothing here can
            // be assumed to arrive transitively.
            "NetworkManager", "nautilus", "patterns-gnome-gnome", "policycoreutils",
            "qemu-guest-agent", "spice-vdagent", "udisks2"
        ]
        if tools.python { packages += ["python313", "python313-pip"] }
        if tools.nodeJS { packages += ["xz"] }
        let packageList = packages.map { "  - \($0)" }.joined(separator: "\n")
        let customSetup = try GuestProvisioningSupport.customSetupScript(from: tools.customSetupScript)
        let customWriteFile = customSetup?.writeFileEntry ?? ""
        let customCommand = customSetup?.command ?? ""
        var verificationCommands = [
            "command -v git", "command -v curl", "command -v jq",
            "rpm -q gdm", "rpm -q gnome-shell", "rpm -q patterns-gnome-gnome",
            "rpm -q NetworkManager", "rpm -q qemu-guest-agent",
            "rpm -q spice-vdagent", "rpm -q firewalld",
            "rpm -q MozillaFirefox", "command -v firefox",
            "rpm -q gnome-terminal",
            "rpm -q nautilus", "command -v nautilus",
            "rpm -q gvfs", "rpm -q udisks2",
            "test -x /usr/sbin/gdm"
        ]
        if tools.python {
            verificationCommands += ["command -v python3", "python3.13 -m pip --version"]
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
        export LANG=C.UTF-8
        installed=false
        for attempt in 1 2 3; do
          status "Installing and updating openSUSE baseline packages (attempt $attempt of 3). This can take 20-45 minutes."
          if zypper --non-interactive --gpg-auto-import-keys refresh \
            && zypper --non-interactive update \
            && zypper --non-interactive install \(packages.joined(separator: " ")); then
            installed=true
            break
          fi
          status "Package attempt $attempt failed; waiting 15 seconds before retrying."
          sleep 15
        done
        if [[ "$installed" != true ]]; then
          status "ERROR: openSUSE packages could not be installed. The VM will remain on and no baseline will be created."
          false
        fi
        \(nodeInstallCommands)
        \(vsCodeInstallCommands)
        status "Verifying every selected tool and the openSUSE GNOME desktop."
        \(verificationCommands.joined(separator: "\n"))
        status "Applying openSUSE sandbox security settings."
        systemctl disable --now sshd.service sshd.socket || true
        systemctl mask sshd.service sshd.socket
        status "Installing a MAC-independent DHCP profile for disposable instances."
        chmod 0600 /etc/NetworkManager/system-connections/sandfort.nmconnection
        rm -f /etc/NetworkManager/system-connections/cloud-init-*
        systemctl enable NetworkManager.service
        grep -Fq 'id=sandfort' /etc/NetworkManager/system-connections/sandfort.nmconnection
        grep -Fq 'type=ethernet' /etc/NetworkManager/system-connections/sandfort.nmconnection
        grep -Fq 'method=auto' /etc/NetworkManager/system-connections/sandfort.nmconnection
        if grep -Eiq 'mac-address|interface-name' /etc/NetworkManager/system-connections/sandfort.nmconnection; then
          status "ERROR: The openSUSE network profile is unexpectedly tied to one virtual NIC."
          false
        fi
        systemctl enable qemu-guest-agent.service
        restorecon -RF /etc/NetworkManager/system-connections /etc/firewalld /usr/local/sbin /etc/systemd/system
        systemctl daemon-reload
        systemctl enable --now firewalld.service
        firewall-cmd --set-default-zone=sandfort
        firewall-cmd --reload
        test "$(firewall-cmd --get-default-zone)" = sandfort
        test -z "$(firewall-cmd --zone=sandfort --list-services)"
        test -z "$(firewall-cmd --zone=sandfort --list-ports)"
        if firewall-cmd --zone=sandfort --query-service=ssh; then
          status "ERROR: The openSUSE firewall unexpectedly allows SSH."
          false
        fi
        test "$(getenforce)" = Enforcing
        systemctl enable sandfort-security-update.timer
        systemctl is-enabled --quiet sandfort-security-update.timer
        systemctl set-default graphical.target
        systemctl enable gdm.service || systemctl enable display-manager.service
        systemctl is-enabled --quiet gdm.service || systemctl is-enabled --quiet display-manager.service
        status "Leaving VT1 to the graphical login so no console login prompt appears."
        # Instances have a display and no serial device, so getty@tty1 would park
        # a text "login:" prompt on the framebuffer until GDM starts and looks
        # like the only way in. Masking just this instance keeps VT1 free for the
        # greeter; logind still spawns autovt@tty2..6 on demand, so Ctrl+Alt+F2
        # remains available if the desktop ever fails to come up.
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
        status "Preparing a fast, clean openSUSE baseline: compacting journals and package caches."
        zypper clean --all
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
          - [systemctl, mask, --runtime, --now, serial-getty@\(hardware.serialConsoleDevice).service]
          - [sh, -c, "echo '[Sandfort] openSUSE baseline setup has started. Leave this VM running until it powers itself off automatically. Installation commonly takes 20-45 minutes.' > /dev/console"]
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
          - path: /etc/firewalld/zones/sandfort.xml
            permissions: '0644'
            content: |
              <?xml version="1.0" encoding="utf-8"?>
              <zone target="DROP">
                <short>Sandfort</short>
                <description>Blocks unsolicited inbound sandbox traffic.</description>
              </zone>
          - path: /usr/local/sbin/sandfort-security-update
            permissions: '0755'
            content: |
              #!/usr/bin/env bash
              exec zypper --non-interactive patch --category security
          - path: /etc/systemd/system/sandfort-security-update.service
            permissions: '0644'
            content: |
              [Unit]
              Description=Install openSUSE security patches for Sandfort
              After=network-online.target
              Wants=network-online.target

              [Service]
              Type=oneshot
              ExecStart=/usr/local/sbin/sandfort-security-update
          - path: /etc/systemd/system/sandfort-security-update.timer
            permissions: '0644'
            content: |
              [Unit]
              Description=Daily openSUSE security patches for Sandfort

              [Timer]
              OnCalendar=daily
              RandomizedDelaySec=15m
              Persistent=true

              [Install]
              WantedBy=timers.target
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
          message: openSUSE sandbox setup verified; powering off for baseline creation
          timeout: 30
          condition: [test, -f, \(GuestProvisioningSupport.completionMarkerPath)]
        final_message: openSUSE sandbox setup complete after $UPTIME seconds
        """
        let metaData = """
        instance-id: sandfort-\(UUID().uuidString.lowercased())
        local-hostname: sandfort
        """
        return try ISO9660Writer.make(volumeName: "cidata", files: [
            // Identifiers are supplied rather than assigned by position; these
            // are the exact two the previous index-based code produced, so the
            // seed image's bytes are unchanged.
            .init(isoIdentifier: "USER_DAT;1", name: "user-data", data: Data(userData.utf8)),
            .init(isoIdentifier: "META_DAT;1", name: "meta-data", data: Data(metaData.utf8))
        ])
    }
}
