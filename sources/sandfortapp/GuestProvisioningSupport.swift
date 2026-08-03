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

enum GuestProvisioningSupport {
    static let completionMarkerPath = "/var/lib/sandfort/setup-complete"
    static let motd = """
    This is a disposable malware-analysis sandbox.
    Do not enter personal credentials or secrets here.
    """

    struct CustomSetupScript: Sendable, Equatable {
        let writeFileEntry: String
        let command: String
    }

    /// Generates the default guest password as four distinct words joined by
    /// hyphens, for example `moon-reef-juniper-birch`.
    ///
    /// `shuffled()` uses Swift's `SystemRandomNumberGenerator`, which is
    /// cryptographically secure on Apple platforms. Do not replace it with a
    /// seeded or hand-rolled generator: a predictable source would make the
    /// phrase guessable regardless of how large the word list is.
    ///
    /// Drawing 4 distinct words from 2,048 gives 44.00 bits. See
    /// `docs/password-strength.md` for what that protects against.
    static func credentials(username: String = "sandfort") -> SandboxCredentials {
        let words = MemorablePasswordWords.all.shuffled().prefix(4)
        return SandboxCredentials(username: username, password: words.joined(separator: "-"))
    }

    static func credentials(
        username: String = "sandfort",
        password: String
    ) throws -> SandboxCredentials {
        guard (8...128).contains(password.count),
              password.unicodeScalars.allSatisfy({ (0x21...0x7e).contains(Int($0.value)) }) else {
            throw SandboxError.invalidGuestPassword
        }
        return SandboxCredentials(username: username, password: password)
    }

    static func customSetupScript(from script: String?) throws -> CustomSetupScript? {
        let normalized = script?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        guard normalized.utf8.count <= 65_536 else {
            throw SandboxError.setupScriptTooLarge
        }
        let encoded = Data(normalized.utf8).base64EncodedString()
        return CustomSetupScript(
            writeFileEntry: """
              - path: /var/lib/sandfort/custom-setup.sh
                permissions: '0700'
                encoding: b64
                content: \(encoded)
            """,
            command: "/var/lib/sandfort/custom-setup.sh"
        )
    }

    static func yamlSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    static func indented(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    /// A desktop missing a terminal or a browser looks complete and is not.
    /// openSUSE revision 2 shipped without a browser and revision 4 without a
    /// terminal for exactly this reason.
    ///
    /// These check the binary rather than the package. On Ubuntu both `firefox`
    /// and `chromium-browser` are transitional packages for snaps, so a package
    /// query can succeed while nothing usable is installed. The alternatives are
    /// listed because distributions disagree: Fedora ships Ptyxis, GNOME ships
    /// Console, and the others ship Terminal.
    static let terminalVerificationCommand =
        "command -v gnome-terminal || command -v ptyxis || command -v kgx || command -v gnome-console"

    static let browserVerificationCommand =
        "command -v firefox || command -v firefox-esr || command -v chromium || command -v chromium-browser"

    /// Installs Microsoft's Visual Studio Code from its verified arm64 tarball.
    ///
    /// The tarball rather than Microsoft's `.deb` or `.rpm` deliberately: those
    /// add Microsoft's package repository and signing key to the guest in their
    /// post-install scripts, giving every sandbox a standing auto-update channel
    /// to a third party. That is a larger change to the guest's trust posture
    /// than installing an editor, and it is not what the user asked for.
    ///
    /// Microsoft publishes a version and a SHA-256 alongside the download, so
    /// this follows the same discover-download-verify shape as
    /// `nodeLTSInstallCommands`. A checksum mismatch fails the build.
    ///
    /// Settings are left stock, so VS Code telemetry is on by default. That is
    /// documented rather than silently changed.
    static func vsCodeInstallCommands(
        enabled: Bool,
        linuxArchiveArchitecture: String
    ) -> String {
        guard enabled else { return "" }
        return """
        status "Discovering and installing Visual Studio Code for Linux \(linuxArchiveArchitecture)."
        codeMetadata="$(curl --fail --silent --show-error --location https://update.code.visualstudio.com/api/update/linux-\(linuxArchiveArchitecture)/stable/latest)"
        codeVersion="$(printf '%s' "$codeMetadata" | jq -er '.productVersion')"
        codeURL="$(printf '%s' "$codeMetadata" | jq -er '.url')"
        codeSHA="$(printf '%s' "$codeMetadata" | jq -er '.sha256hash')"
        case "$codeVersion" in
          [0-9]*.[0-9]*.[0-9]*) ;;
          *) status "ERROR: Visual Studio Code reported an invalid version."; false ;;
        esac
        if [ "${#codeSHA}" -ne 64 ]; then
          status "ERROR: Visual Studio Code reported an invalid checksum."
          false
        fi
        codeTemp="$(mktemp -d)"
        curl --fail --silent --show-error --location --output "$codeTemp/vscode.tar.gz" "$codeURL"
        printf '%s  %s\n' "$codeSHA" "$codeTemp/vscode.tar.gz" | sha256sum --check -
        codeInstall="/usr/local/lib/vscode/${codeVersion}"
        rm -rf /usr/local/lib/vscode
        install -d "$codeInstall" /usr/local/bin /usr/local/share/applications
        tar -xzf "$codeTemp/vscode.tar.gz" --strip-components=1 -C "$codeInstall"
        rm -rf "$codeTemp"
        ln -sfn "$codeInstall/bin/code" /usr/local/bin/code
        cat > /usr/local/share/applications/code.desktop <<DESKTOP
        [Desktop Entry]
        Name=Visual Studio Code
        Comment=Code editing. Redefined.
        Exec=/usr/local/bin/code %F
        Icon=${codeInstall}/resources/app/resources/linux/code.png
        Type=Application
        Categories=Development;IDE;
        StartupWMClass=Code
        StartupNotify=true
        DESKTOP
        chmod 0644 /usr/local/share/applications/code.desktop
        # Verified by file rather than by running it: VS Code refuses to start
        # normally as root, and this finalizer runs as root.
        test -x /usr/local/bin/code
        test -f "$codeInstall/resources/app/package.json"
        hash -r
        status "Installed and checksum-verified Visual Studio Code ${codeVersion}."
        """
    }

    static func nodeLTSInstallCommands(
        enabled: Bool,
        linuxArchiveArchitecture: String
    ) -> String {
        guard enabled else { return "" }
        return """
        status "Discovering and installing the latest official Node.js LTS for Linux \(linuxArchiveArchitecture)."
        nodeMetadata="$(curl --fail --silent --show-error --location https://nodejs.org/dist/index.json)"
        nodeVersion="$(printf '%s' "$nodeMetadata" | jq -er 'map(select(.lts != false))[0].version')"
        case "$nodeVersion" in
          v[0-9]*.[0-9]*.[0-9]*) ;;
          *) status "ERROR: Node.js returned an invalid LTS version."; false ;;
        esac
        nodeArchive="node-${nodeVersion}-linux-\(linuxArchiveArchitecture).tar.xz"
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
        """
    }

}
