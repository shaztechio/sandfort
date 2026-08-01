import Foundation

struct LinuxGuestProfile: Identifiable, Sendable, Equatable {
    struct Image: Sendable, Equatable {
        let url: URL
        let sha256: String
        let fileName: String
        let downloadSizeDescription: String
    }

    struct Hardware: Sendable, Equatable {
        let architecture: String
        let memoryMiB: Int
        let cpuCount: Int
        let diskSizeGiB: UInt64
    }

    enum Provisioner: String, Sendable {
        case ubuntu2404

        func credentials() -> SandboxCredentials {
            switch self {
            case .ubuntu2404:
                return UbuntuCloudInit.credentials()
            }
        }

        func credentials(password: String) throws -> SandboxCredentials {
            switch self {
            case .ubuntu2404:
                return try UbuntuCloudInit.credentials(password: password)
            }
        }

        func seedISO(
            credentials: SandboxCredentials,
            tools: SandboxToolSelection
        ) throws -> Data {
            switch self {
            case .ubuntu2404:
                return try UbuntuCloudInit.seedISO(credentials: credentials, tools: tools)
            }
        }
    }

    let id: String
    let displayName: String
    let distributionName: String
    let image: Image
    let hardware: Hardware
    let provisioner: Provisioner

    func credentials() -> SandboxCredentials {
        provisioner.credentials()
    }

    func credentials(password: String) throws -> SandboxCredentials {
        try provisioner.credentials(password: password)
    }

    func seedISO(
        credentials: SandboxCredentials,
        tools: SandboxToolSelection = .recommended
    ) throws -> Data {
        try provisioner.seedISO(credentials: credentials, tools: tools)
    }
}

enum LinuxGuestCatalog {
    static let ubuntu2404ARM64 = LinuxGuestProfile(
        id: "ubuntu-24.04-arm64",
        displayName: "Ubuntu 24.04 LTS",
        distributionName: "Ubuntu",
        image: LinuxGuestProfile.Image(
            url: URL(string: "https://cloud-images.ubuntu.com/releases/noble/release-20260725/ubuntu-24.04-server-cloudimg-arm64.img")!,
            sha256: "2eaec7286c49fdea713dddabcf5012cafa7097a658e916acb48f4bc5fdc8e419",
            fileName: "ubuntu-24.04-server-cloudimg-arm64-20260725.img",
            downloadSizeDescription: "about 590 MB"
        ),
        hardware: LinuxGuestProfile.Hardware(
            architecture: "arm64",
            memoryMiB: 4096,
            cpuCount: 4,
            diskSizeGiB: 64
        ),
        provisioner: .ubuntu2404
    )

    /// Profiles are bundled with the app so image sources and checksums are
    /// reviewed and versioned with the code. Never populate this from an
    /// unsigned remote catalog or arbitrary user input.
    static let profiles = [ubuntu2404ARM64]
    static let defaultProfile = ubuntu2404ARM64

    static func profile(id: String) -> LinuxGuestProfile? {
        profiles.first { $0.id == id }
    }
}
