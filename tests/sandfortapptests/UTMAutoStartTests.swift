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

    /// The poll budget is what decides whether a cold UTM import fits. Two
    /// seconds did not; this pins the replacement at roughly fifteen.
    func testPollBudgetCoversAColdUTMImport() {
        let budget = UTMLauncher.registrationPollInterval * UTMLauncher.registrationPollAttempts
        XCTAssertGreaterThanOrEqual(budget, .seconds(10))
        XCTAssertLessThanOrEqual(budget, .seconds(30))
    }
}
