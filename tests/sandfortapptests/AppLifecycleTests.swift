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

import AppKit
import XCTest
@testable import SandfortApp

/// The activity monitor decides whether quitting warns or proceeds silently.
/// Getting it wrong either nags for no reason or throws away a several-hundred
/// megabyte download without asking.
final class AppLifecycleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SandfortActivityMonitor.shared.reset()
    }

    override func tearDown() {
        SandfortActivityMonitor.shared.reset()
        super.tearDown()
    }

    /// The toolbar's Check My Mac button is icon-only. A symbol name that does
    /// not resolve renders as an empty button with no visible label, which is
    /// invisible in a build log and obvious only to whoever opens the app.
    func testToolbarSymbolsResolveOnThisSystem() {
        for name in ["stethoscope", "questionmark.circle", "ellipsis.circle", "eye", "eye.slash"] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "\(name) does not resolve, so its button would render blank"
            )
        }
    }

    /// The version is shown in the sidebar because SECURITY.md and the bug
    /// report template both ask for it. It must degrade to something readable
    /// rather than crash or print "nil" when there is no bundle, as under tests.
    func testAppVersionDescriptionIsAlwaysReadable() {
        let description = SandfortRuntimeConfiguration.production.appVersionDescription
        XCTAssertFalse(description.isEmpty)
        XCTAssertFalse(description.lowercased().contains("nil"))
        XCTAssertFalse(description.contains("Optional"))
        if let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            XCTAssertTrue(description.contains(short))
        } else {
            XCTAssertEqual(description, "development build")
        }
    }

    func testIdleByDefaultSoQuittingDoesNotNag() {
        XCTAssertFalse(SandfortActivityMonitor.shared.isBusy)
    }

    func testBusyWhileWorkIsInFlight() {
        let monitor = SandfortActivityMonitor.shared
        monitor.begin()
        XCTAssertTrue(monitor.isBusy)
        monitor.end()
        XCTAssertFalse(monitor.isBusy)
    }

    /// Counted rather than a flag: an inner operation finishing must not report
    /// the app as idle while an outer one is still running.
    func testNestedWorkStaysBusyUntilAllOfItFinishes() {
        let monitor = SandfortActivityMonitor.shared
        monitor.begin()
        monitor.begin()
        monitor.end()
        XCTAssertTrue(monitor.isBusy, "still busy while the outer operation runs")
        monitor.end()
        XCTAssertFalse(monitor.isBusy)
    }

    /// An unbalanced end must not drive the count negative, which would make a
    /// later begin fail to register as busy.
    func testUnbalancedEndCannotMaskLaterWork() {
        let monitor = SandfortActivityMonitor.shared
        monitor.end()
        monitor.end()
        XCTAssertFalse(monitor.isBusy)
        monitor.begin()
        XCTAssertTrue(monitor.isBusy, "a stray end must not hide real work")
    }

    func testConcurrentReportingSettlesBackToIdle() {
        let monitor = SandfortActivityMonitor.shared
        let group = DispatchGroup()
        for _ in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                monitor.begin()
                monitor.end()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(monitor.isBusy)
    }
}
