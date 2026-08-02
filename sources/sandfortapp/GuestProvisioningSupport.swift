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

    static func credentials(username: String = "sandfort") -> SandboxCredentials {
        let words = memorablePasswordWords.shuffled().prefix(4)
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
}
