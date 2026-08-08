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

/// Resume is the one launch path that starts a bundle it did not just write.
///
/// `openSetup` reasserts isolation through a throwing `repairBundle`, and Reset
/// builds a fresh bundle from the baseline; both stop if that fails. Resume used
/// to rely on the `try?` calls inside `currentState()`, which discard the error
/// — so a bundle whose isolation could not be reasserted still launched, with
/// whatever clipboard, directory, USB, or port-forward setting had drifted.
///
/// `security-model.md` anticipates that drift: the user can change these in
/// UTM's own settings. Resume reasserting them is the whole reason they come
/// back.
final class ResumeIsolationTests: XCTestCase {
    /// Fails every repair, the way an unwritable bundle directory or a failing
    /// volume would.
    private struct RepairFailureProvider: VirtualMachineProvider {
        var identifier: String { "test.repair-failure" }

        func createSetupBundle(
            at bundleURL: URL, name: String, from imageURL: URL,
            profile: LinuxGuestProfile, credentials: SandboxCredentials, tools: SandboxToolSelection
        ) throws {}
        func createCleanBundle(
            from setupBundleURL: URL, at bundleURL: URL, name: String,
            profile: LinuxGuestProfile, networkMode: SandboxNetworkMode
        ) throws {}
        func resetCleanBundle(
            from setupBundleURL: URL, at bundleURL: URL,
            profile: LinuxGuestProfile, networkMode: SandboxNetworkMode
        ) throws {}
        func setDisplayName(_ name: String, at bundleURL: URL) throws {}
        func repairBundle(at bundleURL: URL, profile: LinuxGuestProfile,
                          role: VirtualMachineRole) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
        /// Materials are a clean-instance concern; nothing here exercises them.
        func attachMaterials(_ image: MaterialsImage, to bundleURL: URL) throws {}
        func ensureBundleNotRunning(at bundleURL: URL) throws {}
    }

    private func makeWorkflow() throws -> SandfortWorkflow {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let profile = LinuxGuestCatalog.defaultProfile
        let vms = root.appendingPathComponent("Virtual Machines", isDirectory: true)
        func bundle(_ name: String) throws -> String {
            let url = vms.appendingPathComponent("\(name).utm", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        var state = SandboxState(
            stage: .ready,
            credentials: profile.credentials(),
            tools: .recommended,
            setupBundlePath: try bundle("Baseline"),
            sandboxBundlePath: nil,
            setupVMName: "Sandfort — Protected Baseline",
            sandboxVMName: nil,
            guestProfileID: profile.id,
            guestProfileRevision: profile.revision,
            guestImageSHA256: profile.image.sha256
        )
        state.replaceInstances([
            SandboxInstance(number: 1, bundlePath: try bundle("Instance1"),
                            vmName: "Sandfort — Instance 1", label: nil)
        ])
        try PropertyListEncoder().encode(state)
            .write(to: root.appendingPathComponent("state.plist"))

        return SandfortWorkflow(
            environment: .productionWorkspace(
                profile: profile,
                rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            ),
            provider: RepairFailureProvider(),
            deleteUTMRegistration: { _ in }
        )
    }

    /// The finding: a bundle whose isolation could not be reasserted must not
    /// launch. Silently starting it hands the guest whatever drifted.
    func testResumeRefusesWhenIsolationCannotBeReasserted() async throws {
        let workflow = try makeWorkflow()
        do {
            try await workflow.resumeInstance(instanceNumber: 1)
            XCTFail("Resume must not launch a bundle whose isolation repair failed")
        } catch {
            // The injected error itself, so this cannot pass because some
            // unrelated guard happened to reject the bundle first.
            XCTAssertEqual(
                (error as? CocoaError)?.code, .fileWriteNoPermission,
                "the refusal must come from the failed repair, not another guard"
            )
        }
    }

    /// The control, and the reason the fix is not "return nil from
    /// `currentState()`".
    ///
    /// Seventeen call sites read `currentState()`. Nil-ing it on a repair
    /// failure would hide the environment from the sidebar and make Rebuild and
    /// Delete Environment throw `sandboxNotCreated`, leaving a user with a
    /// transient write error and no recovery inside the app. Worse,
    /// `runningVirtualMachines` returns `[]` when state is nil — so the disk-lock
    /// guard would report nothing running and Rebuild would stop refusing while
    /// a VM held its disk. That trades one fail-open for a broader one.
    ///
    /// The environment therefore has to stay visible and repairable. Only the
    /// launch refuses.
    func testAFailedRepairStillLeavesTheEnvironmentVisibleAndRecoverable() async throws {
        let workflow = try makeWorkflow()
        let state = await workflow.currentState()
        XCTAssertNotNil(state, "a failed repair must not make the environment disappear")
        XCTAssertEqual(state?.resolvedInstances.count, 1, "the instance stays listed, so it can be deleted or rebuilt")
    }
}
