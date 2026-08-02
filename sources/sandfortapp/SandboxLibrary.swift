import Foundation

/// Locates one independently managed baseline per curated Linux profile while
/// preserving the pre-Phase-7 singleton at its original path. Verified image
/// downloads remain shared by every environment.
struct SandboxLibrary: Sendable {
    struct Location: Sendable, Equatable {
        let profile: LinuxGuestProfile
        let rootURL: URL
        let usesLegacyRoot: Bool

        var stateURL: URL { rootURL.appendingPathComponent("state.plist") }
    }

    let rootURL: URL

    init(applicationSupportURL: URL? = nil, supportDirectoryName: String = "Sandfort") {
        let support = applicationSupportURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = support.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    var cacheURL: URL { rootURL.appendingPathComponent("Cache", isDirectory: true) }

    func location(for profile: LinuxGuestProfile) -> Location {
        let legacyID = legacyProfileID()
        if legacyID == profile.id {
            return Location(profile: profile, rootURL: rootURL, usesLegacyRoot: true)
        }
        return Location(
            profile: profile,
            rootURL: rootURL
                .appendingPathComponent("Environments", isDirectory: true)
                .appendingPathComponent(profile.id, isDirectory: true),
            usesLegacyRoot: false
        )
    }

    func existingLocations(in profiles: [LinuxGuestProfile]) -> [Location] {
        profiles.map(location(for:)).filter {
            FileManager.default.fileExists(atPath: $0.stateURL.path)
        }
    }

    private func legacyProfileID() -> String? {
        let stateURL = rootURL.appendingPathComponent("state.plist")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? PropertyListDecoder().decode(SandboxState.self, from: data) else {
            return nil
        }
        return state.guestProfileID ?? LinuxGuestCatalog.ubuntu2404ARM64.id
    }
}
