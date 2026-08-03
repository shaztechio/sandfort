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
            resolved?.firmwareURL.lastPathComponent,
            "edk2-arm-vars.fd"
        )
    }

    /// A QCOW2 header just complete enough for `resizeQCOW2` to accept: the
    /// signature, version 3, and a virtual size below the profile's.
    ///
    /// The source image has to be real. An absent one makes `createSetupBundle`
    /// throw at `copyItem`, two statements before the firmware lookup — which is
    /// how the first version of this test passed against the very bug it was
    /// written to catch.
    private func writeMinimalQCOW2(at url: URL) throws {
        var header = Data(count: 512)
        header.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])   // "QFI\xfb"
        header.replaceSubrange(4..<8, with: [0, 0, 0, 3])               // version 3
        let virtualSize = UInt64(2 * 1024 * 1024 * 1024)                // 2 GiB
        header.replaceSubrange(24..<32, with: (0..<8).map {
            UInt8(truncatingIfNeeded: virtualSize >> (8 * (7 - $0)))
        })
        try header.write(to: url)
    }

    /// Creating a baseline reaches the real resolver, with no override in the
    /// way, from an actor — exactly as the app does.
    ///
    /// The disk is copied and resized immediately before the firmware lookup, so
    /// a resized disk on disk proves execution actually arrived at the call that
    /// used to trap. What happens after it is not this test's business.
    func testCreatingABundleOffTheMainActorReachesTheFirmwareLookup() async throws {
        actor Creator {
            func attempt(into root: URL, from image: URL) -> Error? {
                let builder = UTMBundleBuilder()   // no firmwareURLOverride
                do {
                    try builder.createSetupBundle(
                        at: root.appendingPathComponent("Setup.utm", isDirectory: true),
                        name: "Sandfort Isolation Test",
                        from: image,
                        profile: LinuxGuestCatalog.defaultProfile,
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

        // Reaching the next line at all is the result: the trap killed the
        // process here rather than returning an error.
        let thrown = await Creator().attempt(into: root, from: image)

        let disk = root.appendingPathComponent("Setup.utm/Data/sandfort.qcow2")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: disk.path),
            "the disk is written immediately before the firmware lookup, so it must exist"
        )
        if let thrown {
            // Only a missing UTM is a legitimate failure this far in.
            XCTAssertTrue(
                thrown is SandboxError,
                "unexpected failure past the resolver: \(thrown)"
            )
        }
    }
}
