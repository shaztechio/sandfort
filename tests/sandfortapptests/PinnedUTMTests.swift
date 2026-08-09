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

/// Settings → Advanced can pin the UTM that Sandfort drives, for testing against
/// a specific version. Sandfort supports 4.7.5 and 5.0.4, and they differ at run
/// time — 5.0.4 added the `reload configuration` command that lets a materials
/// disc reach a resumed instance without quitting UTM.
///
/// The point of a pin is that nothing overrides it. Launch Services resolves the
/// identifier `com.utmapp.UTM` to every copy installed and picks on its own, and
/// the audit records a machine where that was two bundles at once.
final class PinnedUTMTests: XCTestCase {
    private let five = URL(fileURLWithPath: "/Applications/UTM.app", isDirectory: true)
    private let four = URL(fileURLWithPath: "/Applications/UTM-4.7.5.app", isDirectory: true)
    private let notUTM = URL(fileURLWithPath: "/Applications/Numbers.app", isDirectory: true)

    private func resolve(
        pinned: String?,
        installed: [URL],
        exists: Set<String>? = nil,
        identifiers: [String: String] = [:]
    ) -> UTMLauncher.Installation? {
        let present = exists ?? Set(installed.map(\.path))
        return UTMLauncher.resolveInstallation(
            identifierLookup: { _ in installed },
            fallbackPaths: [],
            fileExists: { present.contains($0) },
            pinnedPath: pinned,
            bundleIdentifierAt: { identifiers[$0.path] ?? UTMLauncher.bundleIdentifier }
        )
    }

    // MARK: - The pin decides

    /// Launch Services prefers `/Applications/UTM.app`; the pin must win anyway,
    /// or a version test measures whichever copy macOS felt like.
    func testAPinnedCopyIsUsedEvenWhenAnotherWouldBePreferred() {
        let installation = resolve(pinned: four.path, installed: [five, four])

        XCTAssertEqual(installation?.applicationURL, four)
        XCTAssertEqual(installation?.pin, .active)
        XCTAssertEqual(
            installation?.alternatives, [five],
            "the copy that would otherwise have been chosen is still reported"
        )
    }

    func testNoPinLeavesResolutionExactlyAsItWas() {
        let installation = resolve(pinned: nil, installed: [five, four])

        XCTAssertEqual(installation?.applicationURL, five)
        XCTAssertEqual(installation?.pin, UTMLauncher.PinState.none)
    }

    func testAnEmptyPinIsTreatedAsUnset() {
        XCTAssertEqual(resolve(pinned: "", installed: [five])?.pin, UTMLauncher.PinState.none)
    }

    // MARK: - A pin that cannot be honoured

    /// A pin can go stale — the application is moved, renamed, or deleted. That
    /// must cost a warning, not the use of the app, and must never quietly
    /// become "some other UTM" with nothing said.
    func testAMissingPinnedCopyFallsBackAndSaysWhy() {
        let installation = resolve(
            pinned: four.path, installed: [five], exists: [five.path]
        )

        XCTAssertEqual(installation?.applicationURL, five, "the app still works")
        guard case .unusable(let reason) = installation?.pin else {
            return XCTFail("a missing pin must be reported, not silently dropped")
        }
        XCTAssertTrue(reason.contains(four.path), reason)
    }

    /// The pin is chosen through an open panel, but the panel does not stop
    /// someone picking the wrong application — and `firmwareURL` is derived from
    /// whatever is resolved, so a non-UTM pin would have Sandfort reading a UEFI
    /// variable store out of an unrelated app bundle.
    func testAPinnedApplicationThatIsNotUTMIsRefused() {
        let installation = resolve(
            pinned: notUTM.path,
            installed: [five],
            exists: [five.path, notUTM.path],
            identifiers: [notUTM.path: "com.apple.iWork.Numbers"]
        )

        XCTAssertEqual(installation?.applicationURL, five)
        guard case .unusable(let reason) = installation?.pin else {
            return XCTFail("an application that is not UTM must not be pinned")
        }
        XCTAssertTrue(reason.contains("not UTM"), reason)
    }

    // MARK: - Where the events go

    /// This is what makes a pin mean anything. Apple Events address an
    /// application, and addressing by bundle identifier reaches whichever copy
    /// is running — so with 5.0.4 open and 4.7.5 pinned, every command would go
    /// to 5.0.4 while the app reported 4.7.5. The result would be a version test
    /// whose outcome says nothing about the version.
    func testTheProcessLookupFindsThePinnedCopyAndNotAnotherUTM() {
        let pid = UTMLauncher.pinnedProcessIdentifier(
            pinned: four, running: [(five, 100), (four, 200)]
        )

        XCTAssertEqual(pid, 200, "the event must go to the pinned copy, not the other UTM")
    }

    /// Not running is not "use the other one". Falling back to the identifier
    /// here is precisely the failure a pin exists to prevent, and it would be
    /// invisible: the command would succeed against the wrong UTM.
    func testAPinnedCopyThatIsNotRunningYieldsNoProcess() {
        XCTAssertNil(UTMLauncher.pinnedProcessIdentifier(pinned: four, running: [(five, 100)]))
    }

    /// No usable pin means no process is singled out — including a pin that was
    /// set but did not resolve, which is what `activePinnedApplicationURL`
    /// returns nil for.
    func testWithoutAPinNoProcessIsSingledOut() {
        XCTAssertNil(
            UTMLauncher.pinnedProcessIdentifier(pinned: nil, running: [(five, 100), (four, 200)])
        )
    }

    /// Stored as a path and read back as one, so a trailing slash or a symlinked
    /// location does not break the match.
    func testTheStoredPinRoundTrips() {
        UTMLauncher.pinnedApplicationURL = four
        defer { UTMLauncher.pinnedApplicationURL = nil }

        XCTAssertEqual(UTMLauncher.pinnedApplicationURL?.path, four.path)
        XCTAssertTrue(UTMLauncher.isPinned)

        UTMLauncher.pinnedApplicationURL = nil
        XCTAssertFalse(UTMLauncher.isPinned)
        XCTAssertNil(UTMLauncher.pinnedApplicationURL)
    }
}
