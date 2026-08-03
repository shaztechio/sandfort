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

struct LinuxGuestProfile: Identifiable, Sendable, Hashable {
    struct Image: Sendable, Hashable {
        let url: URL
        let sha256: String
        let fileName: String
        let downloadSizeDescription: String
    }

    struct Hardware: Sendable, Hashable {
        let architecture: String
        let utmArchitecture: String
        let utmTarget: String
        let memoryMiB: Int
        let cpuCount: Int
        let diskSizeGiB: UInt64
    }

    enum Provisioner: String, Sendable, Hashable {
        case ubuntu2404
        case fedora44
        case debian13
        case opensuseLeap16

        func credentials() -> SandboxCredentials {
            switch self {
            case .ubuntu2404:
                return UbuntuCloudInit.credentials()
            case .fedora44:
                return FedoraCloudInit.credentials()
            case .debian13:
                return DebianCloudInit.credentials()
            case .opensuseLeap16:
                return OpenSUSECloudInit.credentials()
            }
        }

        func credentials(password: String) throws -> SandboxCredentials {
            switch self {
            case .ubuntu2404:
                return try UbuntuCloudInit.credentials(password: password)
            case .fedora44:
                return try FedoraCloudInit.credentials(password: password)
            case .debian13:
                return try DebianCloudInit.credentials(password: password)
            case .opensuseLeap16:
                return try OpenSUSECloudInit.credentials(password: password)
            }
        }

        func seedISO(
            credentials: SandboxCredentials,
            tools: SandboxToolSelection
        ) throws -> Data {
            switch self {
            case .ubuntu2404:
                return try UbuntuCloudInit.seedISO(credentials: credentials, tools: tools)
            case .fedora44:
                return try FedoraCloudInit.seedISO(credentials: credentials, tools: tools)
            case .debian13:
                return try DebianCloudInit.seedISO(credentials: credentials, tools: tools)
            case .opensuseLeap16:
                return try OpenSUSECloudInit.seedISO(credentials: credentials, tools: tools)
            }
        }
    }

    let id: String
    let revision: Int
    let displayName: String
    let distributionName: String
    let setupDurationDescription: String
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
        revision: 3,
        displayName: "Ubuntu 24.04 LTS",
        distributionName: "Ubuntu",
        setupDurationDescription: "10-30 minutes",
        image: LinuxGuestProfile.Image(
            url: URL(string: "https://cloud-images.ubuntu.com/releases/noble/release-20260725/ubuntu-24.04-server-cloudimg-arm64.img")!,
            sha256: "2eaec7286c49fdea713dddabcf5012cafa7097a658e916acb48f4bc5fdc8e419",
            fileName: "ubuntu-24.04-server-cloudimg-arm64-20260725.img",
            downloadSizeDescription: "about 590 MB"
        ),
        hardware: LinuxGuestProfile.Hardware(
            architecture: "arm64",
            utmArchitecture: "aarch64",
            utmTarget: "virt",
            memoryMiB: 4096,
            cpuCount: 4,
            diskSizeGiB: 64
        ),
        provisioner: .ubuntu2404
    )

    static let fedora44ARM64 = LinuxGuestProfile(
        id: "fedora-44-arm64",
        revision: 3,
        displayName: "Fedora Cloud 44",
        distributionName: "Fedora",
        setupDurationDescription: "20-45 minutes",
        image: LinuxGuestProfile.Image(
            url: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2")!,
            sha256: "55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b",
            fileName: "Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2",
            downloadSizeDescription: "about 504 MiB"
        ),
        hardware: LinuxGuestProfile.Hardware(
            architecture: "arm64",
            utmArchitecture: "aarch64",
            utmTarget: "virt",
            memoryMiB: 4096,
            cpuCount: 4,
            diskSizeGiB: 64
        ),
        provisioner: .fedora44
    )

    static let debian13ARM64 = LinuxGuestProfile(
        id: "debian-13-arm64",
        revision: 5,
        displayName: "Debian 13 (Trixie)",
        distributionName: "Debian",
        setupDurationDescription: "20-45 minutes",
        image: LinuxGuestProfile.Image(
            url: URL(string: "https://cloud.debian.org/images/cloud/trixie/20260712-2537/debian-13-generic-arm64-20260712-2537.qcow2")!,
            sha256: "7e556159a995fa4634e2ea52228ec7a4226193e2d1a87e2c7158e4c6d53ed5fe",
            fileName: "debian-13-generic-arm64-20260712-2537.qcow2",
            downloadSizeDescription: "about 412 MiB"
        ),
        hardware: LinuxGuestProfile.Hardware(
            architecture: "arm64",
            utmArchitecture: "aarch64",
            utmTarget: "virt",
            memoryMiB: 4096,
            cpuCount: 4,
            diskSizeGiB: 64
        ),
        provisioner: .debian13
    )

    static let opensuseLeap16ARM64 = LinuxGuestProfile(
        id: "opensuse-leap-16.0-arm64",
        revision: 4,
        displayName: "openSUSE Leap 16.0",
        distributionName: "openSUSE",
        setupDurationDescription: "20-45 minutes",
        image: LinuxGuestProfile.Image(
            url: URL(string: "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2")!,
            sha256: "2e9eeb56e7523775f1f01261f4900f289e20c38910226b0c1e5aa7228a84194a",
            fileName: "Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2",
            downloadSizeDescription: "about 304 MiB"
        ),
        hardware: LinuxGuestProfile.Hardware(
            architecture: "arm64",
            utmArchitecture: "aarch64",
            utmTarget: "virt",
            memoryMiB: 4096,
            cpuCount: 4,
            diskSizeGiB: 64
        ),
        provisioner: .opensuseLeap16
    )

    /// Profiles are bundled with the app so image sources and checksums are
    /// reviewed and versioned with the code. Never populate this from an
    /// unsigned remote catalog or arbitrary user input.
    static let profiles = [ubuntu2404ARM64, fedora44ARM64, debian13ARM64, opensuseLeap16ARM64]

    /// Profiles with reviewed download metadata that are not yet safe to
    /// create, repair, or expose in the production app.
    static let qualificationProfiles: [LinuxGuestProfile] = []

    /// Every profile revision that can still safely operate an existing
    /// baseline. When a current profile is revised, retain its older value here
    /// until support for baselines created with that revision is deliberately
    /// removed.
    static let supportedProfiles = [
        ubuntu2404ARM64, fedora44ARM64, debian13ARM64, opensuseLeap16ARM64
    ]
    static let defaultProfile = ubuntu2404ARM64

    static func profile(id: String) -> LinuxGuestProfile? {
        profiles.first { $0.id == id }
    }

    /// The separate qualification build may exercise a production profile for
    /// regression testing as well as a profile that has not yet been promoted.
    static func qualificationProfile(id: String) -> LinuxGuestProfile? {
        qualificationProfiles.first { $0.id == id } ?? profile(id: id)
    }

    static func supportedProfile(
        id: String,
        revision: Int?,
        imageSHA256: String?
    ) -> LinuxGuestProfile? {
        let candidates = supportedProfiles.filter { $0.id == id }
        if let revision {
            return candidates.first {
                $0.revision == revision
                    && (imageSHA256 == nil || $0.image.sha256 == imageSHA256)
            }
        }
        if let imageSHA256 {
            return candidates.first { $0.image.sha256 == imageSHA256 }
        }
        return legacyProfile(id: id)
    }

    /// State written before profile revisions were persisted was built by
    /// Ubuntu revision 1, which is no longer supported: it left a console login
    /// prompt on VT1 before the greeter. No current revision describes such a
    /// baseline, so this now resolves to nil and the caller reports
    /// incompatibility, requiring Rebuild.
    ///
    /// Do not change this to return the newest revision. Doing so would
    /// silently apply new provisioning or hardware assumptions to an old
    /// baseline, which is the exact failure the revision contract prevents.
    static func legacyProfile(id: String) -> LinuxGuestProfile? {
        switch id {
        case ubuntu2404ARM64.id:
            return supportedProfiles.first {
                $0.id == ubuntu2404ARM64.id && $0.revision == 1
            }
        default:
            return nil
        }
    }
}
