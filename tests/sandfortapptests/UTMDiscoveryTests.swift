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

/// UTM discovery used to be two hardcoded paths, so a UTM installed anywhere
/// else was invisible even though macOS knew where it was. These cases are
/// injectable because the interesting one — UTM absent — cannot be observed on a
/// development machine that has UTM installed.
@MainActor
final class UTMDiscoveryTests: XCTestCase {
    private let elsewhere = URL(fileURLWithPath: "/Volumes/Tools/UTM.app", isDirectory: true)

    func testLaunchServicesResultWinsOverTheConventionalPaths() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [self.elsewhere] },
            fallbackPaths: ["/Applications/UTM.app"],
            fileExists: { _ in true }
        )
        XCTAssertEqual(resolved?.applicationURL, elsewhere)
    }

    /// A UTM outside /Applications must be found, which is the whole point.
    func testFirmwareComesFromWhereverUTMWasFound() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [self.elsewhere] },
            fallbackPaths: [],
            fileExists: { _ in true }
        )
        XCTAssertEqual(
            resolved?.firmwareURL(for: LinuxGuestCatalog.defaultProfile).path,
            "/Volumes/Tools/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd"
        )
    }

    func testFallsBackToTheConventionalPathWhenLaunchServicesDoesNotKnowIt() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [] },
            fallbackPaths: ["/nope/UTM.app", "/Applications/UTM.app"],
            fileExists: { $0 == "/Applications/UTM.app" }
        )
        XCTAssertEqual(resolved?.applicationURL.path, "/Applications/UTM.app")
    }

    func testMissingUTMResolvesToNothing() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [] },
            fallbackPaths: ["/Applications/UTM.app"],
            fileExists: { _ in false }
        )
        XCTAssertNil(resolved)
    }

    /// Launch Services can return a stale path for an application that has been
    /// deleted, which would otherwise be reported as installed.
    func testStaleLaunchServicesPathIsNotTreatedAsInstalled() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [self.elsewhere] },
            fallbackPaths: [],
            fileExists: { _ in false }
        )
        XCTAssertNil(resolved, "a path that no longer exists must not count as installed")
    }

    func testDownloadPageIsUTMsOwnSite() {
        XCTAssertEqual(UTMLauncher.downloadPage.absoluteString, "https://mac.getutm.app/")
        XCTAssertEqual(UTMLauncher.bundleIdentifier, "com.utmapp.UTM")
    }

    /// The old wording sent people to look in Applications, which is exactly the
    /// assumption that made discovery wrong.
    func testMissingUTMErrorDoesNotClaimItMustLiveInApplications() throws {
        let message = try XCTUnwrap(SandboxError.utmNotInstalled.errorDescription)
        XCTAssertFalse(message.contains("in Applications"))
        XCTAssertTrue(message.contains("Get UTM"), "the message should point at the button that helps")
    }

    /// Check My Mac answers "what is wrong with my Mac", so a missing UTM should
    /// be reported with somewhere to go rather than thrown as a bare error.
    func testDoctorReportsMissingUTMWithSomewhereToGo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workflow = SandfortWorkflow(
            environment: .productionWorkspace(
                profile: LinuxGuestCatalog.defaultProfile,
                rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            )
        )
        let report = try await workflow.doctor()
        if UTMLauncher.isInstalled {
            XCTAssertTrue(report.contains("UTM"))
            XCTAssertTrue(report.contains("installed at"), "report where UTM was found")
        } else {
            XCTAssertTrue(report.contains("mac.getutm.app"))
        }
        XCTAssertTrue(report.contains("This Mac is"))
    }

    // MARK: - Choosing between several registered copies

    /// The reported case: UTM 5 in /Applications with the 4.7.5 installer disk
    /// image still mounted. Both are registered under the same identifier, and
    /// leaving a DMG mounted after upgrading is the most ordinary thing a user
    /// can do — no deliberate second install required.
    ///
    /// A read-only volume can be ejected mid-baseline, and firmware is read from
    /// whatever was resolved, so the installed copy has to win.
    func testAnInstalledCopyBeatsOneOnAMountedVolume() {
        for order in [[mountedDMG, installed], [installed, mountedDMG]] {
            let resolved = UTMLauncher.resolveInstallation(
                identifierLookup: { _ in order },
                fallbackPaths: [],
                fileExists: { _ in true }
            )
            XCTAssertEqual(
                resolved?.applicationURL, installed,
                "the installed copy must win regardless of Launch Services order"
            )
        }
    }

    /// Trashed copies stay in the Launch Services database. Driving one is
    /// never right: the user has already said they do not want it, and emptying
    /// the Trash would pull it out from under a running baseline.
    func testATrashedCopyIsNeverChosen() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [self.trashed, self.installed] },
            fallbackPaths: [],
            fileExists: { _ in true }
        )
        XCTAssertEqual(resolved?.applicationURL, installed)
    }

    /// And not even when it is the only thing registered — falling through to
    /// the conventional path, or to nothing, beats driving a deleted app.
    func testATrashedCopyAloneResolvesToNothing() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [self.trashed] },
            fallbackPaths: [],
            fileExists: { _ in true }
        )
        XCTAssertNil(resolved)
    }

    /// Preference, not prohibition. Running UTM from an external disk is a
    /// legitimate setup, and `testFirmwareComesFromWhereverUTMWasFound` already
    /// pins that intent — so a volume copy still wins when it is the only one.
    func testAVolumeCopyIsStillUsedWhenItIsTheOnlyOne() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [self.elsewhere] },
            fallbackPaths: [],
            fileExists: { _ in true }
        )
        XCTAssertEqual(resolved?.applicationURL, elsewhere)
    }

    /// So the ambiguity can be reported rather than silently resolved.
    func testTheOtherCandidatesAreReported() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in [self.installed, self.mountedDMG] },
            fallbackPaths: [],
            fileExists: { _ in true }
        )
        XCTAssertEqual(resolved?.alternatives, [mountedDMG])
    }

    private var installed: URL { URL(fileURLWithPath: "/Applications/UTM.app", isDirectory: true) }
    private var mountedDMG: URL { URL(fileURLWithPath: "/Volumes/UTM/UTM.app", isDirectory: true) }
    private var trashed: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.Trash/UTM.app", isDirectory: true)
    }
}
