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
