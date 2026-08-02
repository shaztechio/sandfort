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

import XCTest
@testable import SandfortApp

final class SafetyAcknowledgementTests: XCTestCase {
    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFirstRunRequiresAcknowledgement() throws {
        let store = SafetyAcknowledgement.Store(supportRootURL: temporaryRoot())
        XCTAssertTrue(store.needsAcknowledgement)
        XCTAssertNil(store.load())
    }

    func testAcceptingIsRememberedAcrossLaunches() throws {
        let root = temporaryRoot()
        let store = SafetyAcknowledgement.Store(supportRootURL: root)
        try store.record(appVersion: "0.13.0")

        // A separate store instance stands in for the next launch.
        let reopened = SafetyAcknowledgement.Store(supportRootURL: root)
        XCTAssertFalse(reopened.needsAcknowledgement)
        let record = try XCTUnwrap(reopened.load())
        XCTAssertEqual(record.version, SafetyAcknowledgement.currentVersion)
        XCTAssertEqual(record.appVersion, "0.13.0")
    }

    /// Raising the disclosure version must ask again. Someone who accepted the
    /// old wording has not seen the new wording.
    func testAnOlderAcknowledgementIsAskedAgain() throws {
        let root = temporaryRoot()
        let stale = SafetyAcknowledgement.Record(
            version: SafetyAcknowledgement.currentVersion - 1,
            acknowledgedAt: Date(timeIntervalSince1970: 0),
            appVersion: "0.1.0"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(stale)
            .write(to: root.appendingPathComponent("acknowledgement.plist"))

        let store = SafetyAcknowledgement.Store(supportRootURL: root)
        XCTAssertTrue(store.needsAcknowledgement)
        XCTAssertFalse(try XCTUnwrap(store.load()).isCurrent)
    }

    func testCorruptedRecordFailsClosedAndAsksAgain() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: root.appendingPathComponent("acknowledgement.plist"))
        let store = SafetyAcknowledgement.Store(supportRootURL: root)
        XCTAssertTrue(store.needsAcknowledgement, "an unreadable record must re-prompt, not pass")
    }

    /// A qualification build must not inherit the production answer, the same
    /// isolation every other piece of app-owned state has.
    func testQualificationBuildKeepsItsOwnAcknowledgement() {
        let production = SandfortRuntimeConfiguration.production
        let qualification = SandfortRuntimeConfiguration.configuration(
            qualificationProfileID: LinuxGuestCatalog.fedora44ARM64.id
        )
        XCTAssertNotEqual(
            production.safetyAcknowledgementStore.fileURL,
            qualification.safetyAcknowledgementStore.fileURL
        )
        XCTAssertTrue(qualification.supportRootURL.path.hasSuffix("Sandfort Fedora Qualification"))
        XCTAssertTrue(
            production.safetyAcknowledgementStore.fileURL.path.hasSuffix(
                "/Sandfort/acknowledgement.plist"
            )
        )
    }

    /// Quit must actually quit. `NSApplication.terminate` is ignored while a
    /// sheet is still attached, so the sheet has to be dismissed first; this
    /// asserts both halves happen and that nothing is recorded as accepted.
    @MainActor
    func testQuittingDismissesTheSheetBeforeTerminatingAndAcceptsNothing() {
        let model = SandfortViewModel()
        // Deliberately not asserting an absolute value here: this machine may or
        // may not have a real acknowledgement on disk, and a test that depends
        // on the developer's own state is worse than no test.
        let acknowledgedBefore = model.hasAcknowledgedSafety
        model.showSafetyAcknowledgement = true

        let terminated = expectation(description: "termination requested")
        model.declineSafetyAcknowledgement { terminated.fulfill() }

        XCTAssertFalse(
            model.showSafetyAcknowledgement,
            "the sheet must be dismissed first or terminate is silently ignored"
        )
        wait(for: [terminated], timeout: 2)
        XCTAssertEqual(
            model.hasAcknowledgedSafety,
            acknowledgedBefore,
            "quitting must not change whether the notice was accepted"
        )
    }

    /// The other half of the same guarantee, isolated from real app state:
    /// declining writes nothing, so the notice returns on the next launch.
    func testDecliningLeavesNoRecordBehind() {
        let store = SafetyAcknowledgement.Store(supportRootURL: temporaryRoot())
        XCTAssertTrue(store.needsAcknowledgement)
        XCTAssertNil(store.load())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL.path),
            "no file may be created unless the user accepts"
        )
    }

    /// Updating the app must not re-prompt. Only the disclosure version does
    /// that. `appVersion` is recorded for diagnostics and never consulted, so a
    /// routine release does not nag users who have already read the notice.
    func testANewAppVersionAloneDoesNotAskAgain() throws {
        let root = temporaryRoot()
        let store = SafetyAcknowledgement.Store(supportRootURL: root)
        try store.record(appVersion: "0.14.0")
        XCTAssertFalse(store.needsAcknowledgement)

        // Simulate a later release accepting under a different app version.
        try store.record(appVersion: "9.9.9")
        XCTAssertFalse(
            SafetyAcknowledgement.Store(supportRootURL: root).needsAcknowledgement,
            "the app version must not affect whether the notice is shown"
        )

        let record = try XCTUnwrap(store.load())
        XCTAssertEqual(record.version, SafetyAcknowledgement.currentVersion)
        XCTAssertTrue(record.isCurrent)
    }

    /// The disclosure is the point of the feature; empty or reassuring text
    /// would defeat it.
    func testDisclosureStatesTheLimitsItIsMeantToState() {
        let text = ([SafetyAcknowledgement.summary, SafetyAcknowledgement.licenseNotice]
            + SafetyAcknowledgement.points).joined(separator: " ").lowercased()
        XCTAssertGreaterThanOrEqual(SafetyAcknowledgement.points.count, 5)
        XCTAssertTrue(text.contains("not a perfect boundary"))
        XCTAssertTrue(text.contains("not encrypted"))
        XCTAssertTrue(text.contains("never put personal accounts"))
        XCTAssertTrue(text.contains("reach the internet"))
        XCTAssertTrue(text.contains("as is"))
        XCTAssertTrue(text.contains("apache license 2.0"))
        XCTAssertFalse(text.contains("guarantee of safety."), "must not promise safety")
    }
}
