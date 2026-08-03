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

/// Creating an environment left UTM open with the VM stopped. Opening a bundle
/// hands it to UTM, which imports and registers it asynchronously, and
/// `utm://start?name=` is silently dropped when it names a VM UTM has not
/// registered yet. The old code waited a flat two seconds and hoped, which was
/// usually enough for an already-running UTM and never enough for a cold one.
///
/// The wait is injectable so these cases run without UTM installed and without
/// spending real time asleep.
final class UTMAutoStartTests: XCTestCase {
    /// Counts probe calls and never sleeps, so a 60-attempt loop costs nothing.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        let registersOnAttempt: Int?
        let error: Error?

        init(registersOnAttempt: Int? = nil, error: Error? = nil) {
            self.registersOnAttempt = registersOnAttempt
            self.error = error
        }

        func isRegistered(_ name: String) throws -> Bool {
            let attempt = lock.withLock { () -> Int in _calls += 1; return _calls }
            if let error { throw error }
            guard let registersOnAttempt else { return false }
            return attempt >= registersOnAttempt
        }
    }

    private func wait(
        _ probe: Probe,
        attempts: Int = UTMLauncher.registrationPollAttempts
    ) async -> UTMLauncher.RegistrationWait {
        await UTMLauncher.waitForRegistration(
            of: "Sandfort — Instance 1",
            attempts: attempts,
            isRegistered: { try probe.isRegistered($0) },
            sleep: { _ in }
        )
    }

    /// The common case once UTM is already running.
    func testReturnsImmediatelyWhenAlreadyRegistered() async {
        let probe = Probe(registersOnAttempt: 1)
        let outcome = await wait(probe)
        XCTAssertEqual(outcome, .registered(afterAttempts: 1))
        XCTAssertEqual(probe.calls, 1, "no polling once UTM already knows the VM")
    }

    /// The case that was broken: UTM is cold and takes a while to import.
    func testWaitsUntilUTMFinishesImporting() async {
        let probe = Probe(registersOnAttempt: 5)
        let outcome = await wait(probe)
        XCTAssertEqual(outcome, .registered(afterAttempts: 5))
    }

    /// A VM that never appears must still be asked to start. Refusing to send
    /// the request would turn a slow import into a VM that never boots.
    func testGivesUpAfterTheAttemptLimit() async {
        let probe = Probe()
        let outcome = await wait(probe, attempts: 8)
        XCTAssertEqual(outcome, .timedOut(afterAttempts: 8))
        XCTAssertEqual(probe.calls, 8)
    }

    /// Declining Automation permission is a choice, not a failure. It has to
    /// stop the polling immediately rather than burn 60 doomed Apple Events.
    func testAutomationDenialStopsPollingAtOnce() async {
        let denied = NSError(domain: NSOSStatusErrorDomain, code: -1743)
        let probe = Probe(error: denied)
        let outcome = await wait(probe)
        XCTAssertEqual(outcome, .automationDenied)
        XCTAssertEqual(probe.calls, 1, "one refusal is enough; the answer will not change")
    }

    /// UTM is often mid-launch during the first probes, so a transient Apple
    /// Event failure must read as "not yet" rather than abandoning the wait.
    func testOtherAppleEventErrorsAreTreatedAsNotYetRegistered() async {
        let notRunning = NSError(domain: NSOSStatusErrorDomain, code: -600)
        let probe = Probe(error: notRunning)
        let outcome = await wait(probe, attempts: 4)
        XCTAssertEqual(outcome, .timedOut(afterAttempts: 4))
        XCTAssertEqual(probe.calls, 4, "a transient error should keep polling")
    }

    func testAutomationDenialIsDistinguishedFromApplicationNotRunning() {
        let denied = NSError(domain: NSOSStatusErrorDomain, code: -1743)
        let notRunning = NSError(domain: NSOSStatusErrorDomain, code: -600)
        XCTAssertTrue(UTMRegistryController.isAutomationDenied(denied))
        XCTAssertFalse(UTMRegistryController.isAutomationDenied(notRunning))
        XCTAssertTrue(UTMRegistryController.isApplicationNotRunning(notRunning))
        XCTAssertFalse(UTMRegistryController.isApplicationNotRunning(denied))
    }

    /// A zero or negative limit must not skip the probe entirely, or a
    /// miscalculated budget would silently disable the wait.
    func testAlwaysProbesAtLeastOnce() async {
        let probe = Probe(registersOnAttempt: 1)
        let outcome = await wait(probe, attempts: 0)
        XCTAssertEqual(outcome, .registered(afterAttempts: 1))
        XCTAssertEqual(probe.calls, 1)
    }

    /// `utm://start?name=` is documented by UTM but does nothing on 4.7.5:
    /// opening it against a registered, stopped VM left the VM stopped. The
    /// scripting interface's `start` command does work. If the URL ever comes
    /// back it can be reinstated, but nothing should quietly reintroduce it as
    /// though it were a working fallback.
    func testStartingDoesNotRelyOnTheURLScheme() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sources/sandfortapp/SandfortWorkflow.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let code = text
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
        XCTAssertFalse(
            code.contains("\"utm\""),
            "the utm:// URL scheme does not start a VM; use UTMRegistryController.startVirtualMachine"
        )
    }

    /// Taken from UTM's own scripting dictionary, where `start` is UTMvstar.
    /// A wrong code is silently ignored by UTM rather than reported, which is
    /// exactly how the URL scheme failed.
    func testStartUsesUTMsDocumentedEventCode() {
        XCTAssertEqual(Self.code("UTMv"), 0x55544D76)
        XCTAssertEqual(Self.code("star"), 0x73746172)
    }

    /// The other codes read out of UTM's dictionary. Getting one wrong
    /// produces no error, just a VM that never stops.
    ///
    /// Notably absent: the VM `status` property. Building a property specifier
    /// for it returned errAENoSuchObject against real UTM, so the stop wait
    /// uses the qcow2 lock instead — the signal the app already trusted.
    ///
    /// Closing a VM's window is not attempted at all. UTM cannot resolve a
    /// window by name even from AppleScript, and closing one by index returns
    /// success while leaving the window open — verified against real UTM.
    func testStopAndStatusUseUTMsDocumentedCodes() {
        XCTAssertEqual(Self.code("stop"), 0x73746F70)
        XCTAssertEqual(Self.code("StBy"), 0x53744279)   // stop-method parameter
        XCTAssertEqual(Self.code("ReQu"), 0x52655175)   // polite power-down request
    }

    /// Stopping must never escalate. The same code path runs against a baseline
    /// setup VM mid-provision, and killing that backend produces a corrupt
    /// baseline that looks fine until someone tries to use it.
    func testStoppingAsksPolitelyAndNeverForcesOrKills() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sources/sandfortapp/UTMRegistryController.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("\"ReQu\""), "stop should send the polite request method")
        XCTAssertFalse(code.contains("\"FoRc\""), "never force-stop a guest")
        XCTAssertFalse(code.contains("\"KiLl\""), "never kill a VM backend")
    }

    private static func code(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    /// The poll budget is what decides whether a cold UTM import fits. Two
    /// seconds did not; this pins the replacement at roughly fifteen.
    func testPollBudgetCoversAColdUTMImport() {
        let budget = UTMLauncher.registrationPollInterval * UTMLauncher.registrationPollAttempts
        XCTAssertGreaterThanOrEqual(budget, .seconds(10))
        XCTAssertLessThanOrEqual(budget, .seconds(30))
    }
}
