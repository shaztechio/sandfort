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

import XCTest
@testable import SandfortApp

/// Every Sandfort virtual machine used to show UTM's default icon, so a library
/// with four environments was a wall of identical entries told apart only by
/// name.
///
/// UTM resolves `Information.Icon` against the icons it already ships, so this
/// costs one string per profile and Sandfort never ships a distribution logo of
/// its own — which is also why it takes on no trademark question.
///
/// These tests cannot prove UTM renders the icon; that needs one look at the UTM
/// library, and it is recorded in `docs/utm-version-audit.md` as such. What they
/// do prove is that the key is written, that it is written for every role, and
/// that it reaches bundles created before icons existed.
final class DistributionIconTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func information(at bundleURL: URL) throws -> [String: Any] {
        let data = try Data(
            contentsOf: bundleURL.appendingPathComponent("config.plist")
        )
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        return try XCTUnwrap(plist["Information"] as? [String: Any])
    }

    /// A bundle whose `Information` is shaped like one written before this
    /// existed: named, but with no icon.
    private func bundleWithoutAnIcon(named name: String) throws -> URL {
        let bundleURL = try workspace().appendingPathComponent("VM.utm", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Data", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Backend": "QEMU",
            "ConfigurationVersion": 4,
            "Information": ["IconCustom": false, "Name": name, "UUID": UUID().uuidString],
            "Drive": [], "Network": [], "Display": [], "Serial": [], "Sound": []
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("config.plist"))
        return bundleURL
    }

    // MARK: - The catalog

    func testEverySupportedProfileNamesAnIcon() {
        for profile in LinuxGuestCatalog.supportedProfiles {
            XCTAssertFalse(
                profile.utmIconNames.isEmpty,
                "\(profile.id) names no icon, so its VMs would be generic"
            )
            for name in profile.utmIconNames {
                XCTAssertFalse(name.isEmpty, "\(profile.id) has an empty candidate")
                XCTAssertFalse(
                    name.hasSuffix(".png"),
                    "\(profile.id): UTM resolves a bare resource name, so "
                        + "'\(name)' would not match anything"
                )
            }
        }
    }

    /// Distinct icons are the entire point — four profiles sharing one would
    /// leave the library exactly as indistinguishable as before.
    func testTheProfilesDoNotAllShareOneIcon() {
        let names = LinuxGuestCatalog.supportedProfiles.compactMap(\.utmIconNames.first)
        XCTAssertEqual(
            Set(names).count, names.count,
            "two profiles name the same icon: \(names)"
        )
    }

    /// The names are the ones UTM actually ships. Asserted as data rather than
    /// looked up in `/Applications/UTM.app`, so this passes on a build machine
    /// with no UTM installed — the lookup itself is in the audit document.
    func testTheIconNamesAreTheOnesUTMShips() {
        XCTAssertEqual(LinuxGuestCatalog.ubuntu2404ARM64.utmIconNames, ["ubuntu"])
        XCTAssertEqual(LinuxGuestCatalog.fedora44ARM64.utmIconNames, ["fedora"])
        XCTAssertEqual(LinuxGuestCatalog.debian13ARM64.utmIconNames, ["debian"])
        // 4.7.5 ships suse.png and no opensuse.png; 5.0.4 ships both SUSE.png
        // and opensuse.png. Naming only the 5.0.4 spelling left every 4.7.5
        // install with a generic icon.
        XCTAssertEqual(
            LinuxGuestCatalog.opensuseLeap16ARM64.utmIconNames,
            ["opensuse", "SUSE", "suse"]
        )
    }

    // MARK: - Choosing the name UTM actually ships

    /// UTM renames these between versions. openSUSE is `suse.png` in 4.7.5 and
    /// both `SUSE.png` and `opensuse.png` in 5.0.4, so the single literal
    /// `opensuse` left every 4.7.5 install with a generic icon — found by
    /// running against a pinned 4.7.5, not by reading.
    func testTheNameIsChosenFromWhatTheInstalledUTMShips() {
        let opensuse = LinuxGuestCatalog.opensuseLeap16ARM64.utmIconNames
        let icons = URL(fileURLWithPath: "/UTM.app/Contents/Resources/Icons", isDirectory: true)

        XCTAssertEqual(
            UTMLauncher.resolvedIconName(
                preferring: opensuse, iconsDirectory: icons,
                listing: { _ in ["debian.png", "suse.png", "ubuntu.png"] }
            ),
            "suse",
            "UTM 4.7.5 ships suse.png and no opensuse.png"
        )

        XCTAssertEqual(
            UTMLauncher.resolvedIconName(
                preferring: opensuse, iconsDirectory: icons,
                listing: { _ in ["SUSE.png", "debian.png", "opensuse.png", "ubuntu.png"] }
            ),
            "opensuse",
            "UTM 5.0.4 ships opensuse.png, which is preferred"
        )
    }

    /// The default APFS volume is case-insensitive, so `fileExists` answers yes
    /// for `suse.png` when the file is `SUSE.png`. A check that relied on that
    /// would pass on most Macs and fail on a case-sensitive one — the least
    /// reproducible kind of bug — so the comparison is on exact filenames.
    func testTheComparisonIsExactRatherThanCaseInsensitive() {
        let icons = URL(fileURLWithPath: "/UTM.app/Contents/Resources/Icons", isDirectory: true)

        XCTAssertEqual(
            UTMLauncher.resolvedIconName(
                preferring: ["opensuse", "SUSE", "suse"], iconsDirectory: icons,
                listing: { _ in ["SUSE.png"] }
            ),
            "SUSE",
            "the candidate matching the real filename must win, not a case variant"
        )
    }

    /// Nothing to inspect is not a failure: an unknown name degrades to UTM's
    /// default icon, which is the state this replaced.
    func testAnUninspectableUTMFallsBackToTheFirstCandidate() {
        XCTAssertEqual(
            UTMLauncher.resolvedIconName(
                preferring: ["opensuse", "SUSE", "suse"], iconsDirectory: nil, listing: { _ in nil }
            ),
            "opensuse"
        )
        XCTAssertEqual(
            UTMLauncher.resolvedIconName(
                preferring: ["opensuse", "suse"],
                iconsDirectory: URL(fileURLWithPath: "/nope", isDirectory: true),
                listing: { _ in nil }
            ),
            "opensuse"
        )
    }

    /// A UTM shipping none of the candidates still gets a name written rather
    /// than an empty string, which UTM would treat differently from a miss.
    func testAUTMWithNoneOfTheCandidatesStillWritesAName() {
        XCTAssertEqual(
            UTMLauncher.resolvedIconName(
                preferring: ["opensuse", "suse"],
                iconsDirectory: URL(fileURLWithPath: "/x", isDirectory: true),
                listing: { _ in ["ubuntu.png"] }
            ),
            "opensuse"
        )
    }

    // MARK: - What reaches the bundle

    /// Repair runs on every state read, which is what retrofits a baseline built
    /// before icons existed. Without it that VM keeps UTM's default forever,
    /// because `writeConfiguration` only runs at creation.
    func testRepairGivesAnExistingBundleItsDistributionIcon() throws {
        for role in [
            VirtualMachineRole.setup, .protectedBaseline, .cleanInstance
        ] {
            for profile in LinuxGuestCatalog.supportedProfiles {
                let bundleURL = try bundleWithoutAnIcon(named: "Sandfort — VM")
                XCTAssertNil(
                    try information(at: bundleURL)["Icon"],
                    "the fixture must start without an icon or this proves nothing"
                )

                try UTMBundleBuilder().repairBundle(
                    at: bundleURL, profile: profile, role: role
                )

                let information = try self.information(at: bundleURL)
                XCTAssertEqual(
                    information["Icon"] as? String, profile.utmIconNames.first,
                    "\(profile.id) as \(role) kept the default icon"
                )
                XCTAssertEqual(
                    information["IconCustom"] as? Bool, false,
                    "a built-in icon must not be flagged as custom"
                )
            }
        }
    }

    /// Repair rewrites a great deal of a bundle, and the display name carries
    /// the user's instance label. Taking the icon must not take that with it.
    func testRetrofittingAnIconLeavesTheInstanceLabelAlone() throws {
        let bundleURL = try bundleWithoutAnIcon(named: "Sandfort — Instance 1 — my coding challenge")

        try UTMBundleBuilder().repairBundle(
            at: bundleURL,
            profile: LinuxGuestCatalog.defaultProfile,
            role: .cleanInstance
        )

        XCTAssertEqual(
            try information(at: bundleURL)["Name"] as? String,
            "Sandfort — Instance 1 — my coding challenge"
        )
    }
}
