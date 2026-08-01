import Foundation

enum CloudInit {
    static func credentials() -> SandboxCredentials {
        let words = memorablePasswordWords.shuffled().prefix(4)
        return SandboxCredentials(username: "sandfort", password: words.joined(separator: "-"))
    }

    static func credentials(password: String) throws -> SandboxCredentials {
        guard (8...128).contains(password.count),
              password.unicodeScalars.allSatisfy({ (0x21...0x7e).contains(Int($0.value)) }) else {
            throw SandboxError.invalidGuestPassword
        }
        return SandboxCredentials(username: "sandfort", password: password)
    }

    private static let memorablePasswordWords = [
        "amber", "apple", "atlas", "autumn", "bamboo", "beacon", "birch", "breeze",
        "brook", "cedar", "cherry", "cloud", "cobalt", "coral", "dawn", "delta",
        "ember", "fern", "field", "forest", "frost", "garden", "golden", "harbor",
        "hazel", "island", "ivory", "jade", "juniper", "lake", "lantern", "lemon",
        "lotus", "maple", "meadow", "mint", "moon", "moss", "ocean", "olive",
        "orchid", "pebble", "pine", "plum", "quartz", "rain", "reef", "river",
        "robin", "rose", "ruby", "sage", "shore", "silver", "sky", "solar",
        "sparrow", "spring", "stone", "sunset", "swift", "tide", "violet", "willow"
    ]

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
        let customScript = tools.customSetupScript?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customScript, customScript.utf8.count > 65_536 {
            throw SandboxError.setupScriptTooLarge
        }
        let customWriteFile: String
        let customCommand: String
        if let customScript, !customScript.isEmpty {
            let encoded = Data(customScript.utf8).base64EncodedString()
            customWriteFile = """
              - path: /var/lib/sandfort/custom-setup.sh
                permissions: '0700'
                encoding: b64
                content: \(encoded)
            """
            customCommand = "/var/lib/sandfort/custom-setup.sh"
        } else {
            customWriteFile = ""
            customCommand = ""
        }
        var verificationCommands = [
            "command -v git", "command -v curl", "command -v jq",
            "dpkg-query -W ubuntu-desktop-minimal", "dpkg-query -W qemu-guest-agent",
            "dpkg-query -W spice-vdagent", "dpkg-query -W gdm3", "test -x /usr/sbin/gdm3"
        ]
        if tools.python { verificationCommands += ["command -v python3", "command -v pip3"] }
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
        let nodeInstallCommands = tools.nodeJS ? """
        status "Discovering and installing the latest official Node.js LTS for Linux ARM64."
        nodeMetadata="$(curl --fail --silent --show-error --location https://nodejs.org/dist/index.json)"
        nodeVersion="$(printf '%s' "$nodeMetadata" | jq -er 'map(select(.lts != false))[0].version')"
        case "$nodeVersion" in
          v[0-9]*.[0-9]*.[0-9]*) ;;
          *) status "ERROR: Node.js returned an invalid LTS version."; false ;;
        esac
        nodeArchive="node-${nodeVersion}-linux-arm64.tar.xz"
        nodeBase="https://nodejs.org/dist/${nodeVersion}"
        nodeTemp="$(mktemp -d)"
        curl --fail --silent --show-error --location --output "$nodeTemp/SHASUMS256.txt" "$nodeBase/SHASUMS256.txt"
        curl --fail --silent --show-error --location --output "$nodeTemp/$nodeArchive" "$nodeBase/$nodeArchive"
        (cd "$nodeTemp" && grep "  ${nodeArchive}$" SHASUMS256.txt | sha256sum --check -)
        nodeInstall="/usr/local/lib/nodejs/${nodeVersion}"
        rm -rf "$nodeInstall"
        install -d "$nodeInstall" /usr/local/bin
        tar -xJf "$nodeTemp/$nodeArchive" --strip-components=1 -C "$nodeInstall"
        ln -sfn "$nodeInstall/bin/node" /usr/local/bin/node
        ln -sfn "$nodeInstall/bin/npm" /usr/local/bin/npm
        ln -sfn "$nodeInstall/bin/npx" /usr/local/bin/npx
        rm -rf "$nodeTemp"
        hash -r
        status "Installed and checksum-verified Node.js $(node --version), npm $(npm --version)."
        """ : ""
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
        \(customCommand.isEmpty ? "" : "status \"Running the custom baseline setup script.\"")
        \(customCommand)
        status "Preparing a fast, clean baseline: compacting journals and package caches."
        apt-get clean
        journalctl --rotate
        journalctl --vacuum-size=16M
        systemctl mask systemd-journal-flush.service
        systemctl restart systemd-journald.service
        sync
        touch /var/lib/sandfort/setup-complete
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
              password: '\(yamlSingleQuoted(credentials.password))'
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
              This is a disposable malware-analysis sandbox.
              Do not enter personal credentials or secrets here.
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
          condition: [test, -f, /var/lib/sandfort/setup-complete]
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

    private static func yamlSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
