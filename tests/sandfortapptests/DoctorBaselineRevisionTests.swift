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

/// A baseline built by an older app looked exactly like a current one, and the
/// only way to tell was to spend twenty to forty-five minutes rebuilding and see
/// whether anything changed.
///
/// That is not hypothetical. openSUSE revision 6 added a file manager; a rebuild
/// run with the previous binary regenerated revision 5 and nothing about the app
/// said so — not the version, not Check Setup, nothing. Reporting both numbers is
/// what makes "did my rebuild pick this up" answerable before spending the time.
final class DoctorBaselineRevisionTests: XCTestCase {
    private func workflow(revision: Int?, at root: URL) throws -> SandfortWorkflow {
        let profile = LinuxGuestCatalog.defaultProfile
        let vms = root.appendingPathComponent("Virtual Machines", isDirectory: true)
        let bundle = vms.appendingPathComponent("Baseline.utm", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let state = SandboxState(
            stage: .ready,
            credentials: profile.credentials(),
            tools: .recommended,
            setupBundlePath: bundle.path,
            sandboxBundlePath: nil,
            setupVMName: "Sandfort — Protected Baseline",
            sandboxVMName: nil,
            guestProfileID: profile.id,
            guestProfileRevision: revision,
            guestImageSHA256: profile.image.sha256
        )
        try PropertyListEncoder().encode(state)
            .write(to: root.appendingPathComponent("state.plist"))
        return SandfortWorkflow(
            environment: .productionWorkspace(
                profile: profile, rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            ),
            deleteUTMRegistration: { _ in },
            launchVirtualMachine: { _, _, _ in }
        )
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testACurrentBaselineIsReportedAsCurrent() async throws {
        let profile = LinuxGuestCatalog.defaultProfile
        let workflow = try workflow(revision: profile.revision, at: try workspace())

        let report = try await workflow.doctor()

        XCTAssertTrue(report.contains("revision \(profile.revision)"), report)
        XCTAssertTrue(report.contains("which is current"), report)
        XCTAssertFalse(report.contains("choose Rebuild"), "nothing to do, so do not ask for one")
    }

    /// The case that cost an afternoon: a baseline one revision behind the binary.
    func testAnOlderBaselineSaysWhichRevisionsAreInvolvedAndWhatToDo() async throws {
        let profile = LinuxGuestCatalog.defaultProfile
        let workflow = try workflow(revision: profile.revision - 1, at: try workspace())

        let report = try await workflow.doctor()

        XCTAssertTrue(
            report.contains("revision \(profile.revision - 1)"),
            "say what the baseline actually is: \(report)"
        )
        XCTAssertTrue(
            report.contains("revision \(profile.revision)"),
            "and what this binary would build: \(report)"
        )
        XCTAssertTrue(report.contains("choose Rebuild"), report)
    }

    /// State written before revisions were persisted has none at all, and must
    /// not be described as though it matched.
    func testAnUnrecordedRevisionIsNotClaimedToBeCurrent() async throws {
        let workflow = try workflow(revision: nil, at: try workspace())

        let report = try await workflow.doctor()

        XCTAssertTrue(report.contains("unrecorded revision"), report)
        XCTAssertTrue(report.contains("choose Rebuild"), report)
        XCTAssertFalse(report.contains("which is current"), report)
    }

    func testNoBaselineSaysNothingAboutRevisions() async throws {
        let root = try workspace()
        let workflow = SandfortWorkflow(
            environment: .productionWorkspace(
                profile: LinuxGuestCatalog.defaultProfile, rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            ),
            deleteUTMRegistration: { _ in },
            launchVirtualMachine: { _, _, _ in }
        )

        let report = try await workflow.doctor()

        XCTAssertFalse(report.contains("revision"), "nothing built yet: \(report)")
    }
}
