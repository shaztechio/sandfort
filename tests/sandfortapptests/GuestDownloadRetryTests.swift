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

/// One dropped connection used to discard an entire baseline.
///
/// Observed on Ubuntu: twelve minutes in, with packages, the desktop and Node.js
/// installed and verified, the Visual Studio Code tarball failed with
/// `curl: (56) Recv failure: Connection reset by peer` and setup stopped. There
/// is no resuming it — cloud-init's `runcmd` is once-per-instance — so the only
/// way forward was a 10–45 minute Rebuild.
///
/// The package install had retried three times all along. The vendor downloads
/// did not, which left the cheapest part of the build the least robust.
final class GuestDownloadRetryTests: XCTestCase {
    private func installCommands(for profile: LinuxGuestProfile) -> String {
        GuestProvisioningSupport.nodeLTSInstallCommands(
            enabled: true, linuxArchiveArchitecture: profile.hardware.linuxArchiveArchitecture
        )
        + "\n"
        + GuestProvisioningSupport.vsCodeInstallCommands(
            enabled: true, linuxArchiveArchitecture: profile.hardware.linuxArchiveArchitecture
        )
    }

    /// Every `curl` that reaches a vendor, on every profile. Counted rather than
    /// spot-checked: a sixth download added later without retries would be the
    /// same bug again, and this is what would catch it.
    func testEveryVendorDownloadRetries() {
        for profile in LinuxGuestCatalog.supportedProfiles {
            let script = installCommands(for: profile)
            let calls = script.split(separator: "\n").filter { $0.contains("curl ") }

            XCTAssertEqual(
                calls.count, 5,
                "\(profile.id): expected the five vendor downloads; a new one needs retries too"
            )
            for call in calls {
                XCTAssertTrue(
                    call.contains("--retry 3"),
                    "\(profile.id): a vendor download without retries: \(call)"
                )
                XCTAssertTrue(
                    call.contains("--retry-all-errors"),
                    "\(profile.id): plain --retry does not cover a mid-transfer reset, "
                        + "which is the failure this exists for: \(call)"
                )
            }
        }
    }

    /// Retrying is only safe because a truncated file cannot pass as a good one.
    /// If a download ever loses its checksum, restarting from zero stops being
    /// the conservative choice.
    func testEveryRetriedDownloadIsStillChecksumVerified() {
        let script = installCommands(for: LinuxGuestCatalog.defaultProfile)

        XCTAssertTrue(script.contains("sha256sum --check -"), script)
        XCTAssertEqual(
            script.components(separatedBy: "sha256sum --check -").count - 1, 2,
            "both the Node.js archive and the VS Code tarball must still be verified"
        )
    }

    /// `-C -` would resume a partial transfer, which needs the server to honour
    /// range requests and risks stitching two different files together. The
    /// checksum would catch it, but a slow re-download is the better failure.
    func testDownloadsDoNotAttemptToResumeAPartialTransfer() {
        let script = installCommands(for: LinuxGuestCatalog.defaultProfile)

        XCTAssertFalse(script.contains("-C -"), "resuming is deliberately not used: \(script)")
    }

    /// A baseline with no tools selected makes no vendor downloads at all, which
    /// is why its generated `user-data` is unchanged by this. Worth pinning: it
    /// is the evidence that the change is scoped to the tool installers.
    func testABaselineWithoutToolsDownloadsNothingToRetry() {
        let bare = GuestProvisioningSupport.nodeLTSInstallCommands(
            enabled: false, linuxArchiveArchitecture: "arm64"
        ) + GuestProvisioningSupport.vsCodeInstallCommands(
            enabled: false, linuxArchiveArchitecture: "arm64"
        )

        XCTAssertTrue(bare.isEmpty, "nothing selected must generate no commands: \(bare)")
    }
}
