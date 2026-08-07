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

/// Baseline creation crashed on every run with `EXC_BREAKPOINT` inside
/// `dispatch_assert_queue`, and the whole existing suite stayed green while it
/// did. Two things hid it:
///
/// - `UTMBundleBuilder.createSetupBundle` runs on the `SandfortWorkflow` actor,
///   never the main actor, and reached a main-actor-isolated UTM resolver
///   through `MainActor.assumeIsolated`. That call asserts the current executor
///   rather than hopping to it, so it traps everywhere except the main actor.
/// - Every existing bundle test passes `firmwareURLOverride`, so none of them
///   ever entered the resolver at all.
///
/// These cases are deliberately **not** `@MainActor`. That is the entire point:
/// on the main actor the old code passed. A trap kills the test process rather
/// than failing an assertion, so reaching the end of each test is the result.
final class UTMLauncherIsolationTests: XCTestCase {
    /// The exact call the bundle builder makes, from off the main actor.
    func testInstallationIsReadableOffTheMainActor() async {
        let reached = await Task.detached { () -> Bool in
            _ = UTMLauncher.installation
            _ = UTMLauncher.isInstalled
            return true
        }.value
        XCTAssertTrue(reached, "resolving UTM off the main actor must not trap")
    }

    /// The resolver has to stay callable from a synchronous, nonisolated context,
    /// which is where `utmFirmwareURL()` sits.
    func testResolverIsCallableFromASynchronousNonisolatedContext() {
        let resolved = UTMLauncher.resolveInstallation(
            identifierLookup: { _ in URL(fileURLWithPath: "/Applications/UTM.app", isDirectory: true) },
            fallbackPaths: [],
            fileExists: { _ in true }
        )
        XCTAssertEqual(
            resolved?.firmwareURL(for: LinuxGuestCatalog.defaultProfile).lastPathComponent,
            "edk2-arm-vars.fd"
        )
    }

    /// A QCOW2 complete enough for `resizeQCOW2` to accept *and grow*: the
    /// signature, version 3, 64 KiB clusters, a 2 GiB virtual size below the
    /// profile's, and an L1 table with room to spare.
    ///
    /// The cluster and L1 fields are not decoration. Without them the resize
    /// throws before the firmware lookup, so an earlier version of this file
    /// stopped one statement short of the call it exists to reach and passed
    /// anyway, on an assertion about the copied disk rather than the resolver.
    ///
    /// The source image has to be real. An absent one makes `createSetupBundle`
    /// throw at `copyItem`, which is how the first version of this test passed
    /// against the very bug it was written to catch.
    private func writeMinimalQCOW2(at url: URL) throws {
        var image = Data(count: 128 * 1024)
        image.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])        // "QFI\xfb"
        image.replaceSubrange(4..<8, with: [0, 0, 0, 3])                    // version 3
        image.replaceSubrange(20..<24, with: [0, 0, 0, 16])                 // 64 KiB clusters
        image.replaceSubrange(24..<32, with: [0, 0, 0, 0, 0x80, 0, 0, 0])   // 2 GiB virtual size
        image.replaceSubrange(36..<40, with: [0, 0, 0, 7])                  // L1 entries
        image.replaceSubrange(40..<48, with: [0, 0, 0, 0, 0, 1, 0, 0])      // L1 at 64 KiB
        try image.write(to: url)
    }

    /// The shipped Ubuntu profile with its checksum pinned to whatever this test
    /// wrote. `createSetupBundle` verifies the disk it copied into the bundle,
    /// so a stub image under a real profile's pinned hash is refused before the
    /// firmware lookup this test is trying to reach.
    private func profile(pinning sha256: String) -> LinuxGuestProfile {
        let ubuntu = LinuxGuestCatalog.defaultProfile
        return LinuxGuestProfile(
            id: ubuntu.id,
            revision: ubuntu.revision,
            displayName: ubuntu.displayName,
            distributionName: ubuntu.distributionName,
            setupDurationDescription: ubuntu.setupDurationDescription,
            image: LinuxGuestProfile.Image(
                url: ubuntu.image.url,
                sha256: sha256,
                fileName: ubuntu.image.fileName,
                downloadSizeDescription: ubuntu.image.downloadSizeDescription
            ),
            hardware: ubuntu.hardware,
            provisioner: ubuntu.provisioner
        )
    }

    /// Creating a baseline reaches the real resolver, with no override in the
    /// way, from an actor — exactly as the app does.
    ///
    /// The outcome proves the arrival. Every step before the lookup has its own
    /// distinct error, so `utmResourcesMissing` can only come from the resolver
    /// itself returning nil, and success can only come from getting past it.
    /// This used to be asserted on the copied disk still being there, which no
    /// longer holds: a failed `createSetupBundle` now removes what it created,
    /// so a rejected image cannot be left behind looking like a baseline.
    func testCreatingABundleOffTheMainActorReachesTheFirmwareLookup() async throws {
        actor Creator {
            func attempt(into root: URL, from image: URL, profile: LinuxGuestProfile) -> Error? {
                let builder = UTMBundleBuilder()   // no firmwareURLOverride
                do {
                    try builder.createSetupBundle(
                        at: root.appendingPathComponent("Setup.utm", isDirectory: true),
                        name: "Sandfort Isolation Test",
                        from: image,
                        profile: profile,
                        credentials: SandboxCredentials(username: "sandfort", password: "test-test-test-test"),
                        tools: SandboxToolSelection(python: false, nodeJS: false)
                    )
                    return nil
                } catch {
                    return error
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let image = root.appendingPathComponent("source.qcow2")
        try writeMinimalQCOW2(at: image)
        let profile = profile(pinning: try DiskUtilities.sha256(of: image))

        // Reaching the next line at all is the result: the trap killed the
        // process here rather than returning an error.
        let thrown = await Creator().attempt(into: root, from: image, profile: profile)

        guard let thrown else { return }   // UTM is installed; the lookup succeeded.
        guard case SandboxError.utmResourcesMissing = thrown else {
            return XCTFail("stopped before the resolver, or past it, with: \(thrown)")
        }
    }
}
