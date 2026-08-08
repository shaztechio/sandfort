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

/// Selecting an environment must show that environment, whatever state it is in.
///
/// `apply` assigned the profile only when the saved state resolved to a known
/// one, or when there was no state at all. A baseline whose revision this build
/// no longer supports falls between those, so nothing was assigned and the header
/// kept the *previously selected* environment's name — openSUSE selected, Fedora
/// on screen. The one case where a user most needs to know which environment they
/// are looking at is the one that lied.
@MainActor
final class EnvironmentSelectionTitleTests: XCTestCase {
    private func state(for profile: LinuxGuestProfile, revision: Int) -> SandboxState {
        SandboxState(
            stage: .ready,
            credentials: profile.credentials(),
            tools: .recommended,
            setupBundlePath: "/tmp/Baseline.utm",
            sandboxBundlePath: nil,
            setupVMName: "Sandfort — Protected Baseline",
            sandboxVMName: nil,
            guestProfileID: profile.id,
            guestProfileRevision: revision,
            guestImageSHA256: profile.image.sha256
        )
    }

    /// The reported case: a baseline one revision behind the binary.
    func testAnIncompatibleBaselineStillShowsTheEnvironmentYouSelected() {
        let model = SandfortViewModel()
        let first = LinuxGuestCatalog.defaultProfile
        let other = try? XCTUnwrap(
            LinuxGuestCatalog.supportedProfiles.first { $0.id != first.id }
        )
        let second = try! XCTUnwrap(other)

        // Arrive at one environment, then select another whose saved baseline
        // this build cannot resolve.
        model.applyForTesting(state(for: first, revision: first.revision), profile: first)
        XCTAssertEqual(model.guestProfile.id, first.id)

        model.applyForTesting(state(for: second, revision: second.revision - 1), profile: second)

        XCTAssertEqual(
            model.guestProfile.id, second.id,
            "the header must name the environment that was selected, not the one before it"
        )
        XCTAssertEqual(model.selectedBaselineProfile.id, second.id)
    }

    /// State written before revisions were persisted resolves no better, and must
    /// not leave the previous environment on screen either.
    func testAnUnrecordedRevisionAlsoShowsTheSelectedEnvironment() {
        let model = SandfortViewModel()
        let first = LinuxGuestCatalog.defaultProfile
        let second = try! XCTUnwrap(
            LinuxGuestCatalog.supportedProfiles.first { $0.id != first.id }
        )

        model.applyForTesting(state(for: first, revision: first.revision), profile: first)
        var legacy = state(for: second, revision: second.revision)
        legacy.guestProfileRevision = nil
        model.applyForTesting(legacy, profile: second)

        XCTAssertEqual(model.guestProfile.id, second.id)
    }

    /// And the cases that already worked keep working.
    func testAResolvableBaselineAndAnEmptyOneBothShowTheSelection() {
        let model = SandfortViewModel()
        let profile = LinuxGuestCatalog.defaultProfile

        model.applyForTesting(state(for: profile, revision: profile.revision), profile: profile)
        XCTAssertEqual(model.guestProfile.id, profile.id)

        let other = try! XCTUnwrap(
            LinuxGuestCatalog.supportedProfiles.first { $0.id != profile.id }
        )
        model.applyForTesting(nil, profile: other)
        XCTAssertEqual(model.guestProfile.id, other.id, "nothing built yet still names the selection")
    }
}
