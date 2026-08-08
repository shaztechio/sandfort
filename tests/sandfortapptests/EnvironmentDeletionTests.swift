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

/// UTM imports the setup VM before Sandfort relabels it as the Protected
/// Baseline. UTM 5 may keep the imported name cached, so deleting only the
/// relabeled name leaves an orphan in UTM after Sandfort deletes its state.
final class EnvironmentDeletionTests: XCTestCase {
    private actor RegistrationRecorder {
        private var names: [String] = []

        func append(_ name: String) {
            names.append(name)
        }

        func snapshot() -> [String] {
            names
        }
    }

    private struct IdleProvider: VirtualMachineProvider {
        var identifier: String { "test.environment-deletion" }

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
        func repairBundle(
            at bundleURL: URL, profile: LinuxGuestProfile, role: VirtualMachineRole
        ) throws {}
        /// Materials are a clean-instance concern; nothing here exercises them.
        func attachMaterials(_ image: MaterialsImage, to bundleURL: URL) throws {}
        func ensureBundleNotRunning(at bundleURL: URL) throws {}
    }

    func testDeleteEnvironmentRemovesTheBaselineByItsImportedAndProtectedNames() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let profile = LinuxGuestCatalog.defaultProfile
        let prefix = "Sandfort — \(profile.displayName)"
        let vms = root.appendingPathComponent("Virtual Machines", isDirectory: true)
        let baseline = vms.appendingPathComponent("Baseline.utm", isDirectory: true)
        let instance = vms.appendingPathComponent("Instance 1.utm", isDirectory: true)
        try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)

        // This is state written before `setupVMImportedName` existed: only the
        // post-setup display name survives, while UTM still knows the original.
        var state = SandboxState(
            stage: .ready,
            credentials: profile.credentials(),
            tools: .recommended,
            setupBundlePath: baseline.path,
            sandboxBundlePath: nil,
            setupVMName: "\(prefix) — Protected Baseline ABC123",
            sandboxVMName: nil,
            guestProfileID: profile.id,
            guestProfileRevision: profile.revision,
            guestImageSHA256: profile.image.sha256
        )
        state.replaceInstances([
            SandboxInstance(
                number: 1,
                bundlePath: instance.path,
                vmName: "\(prefix) — Instance 1 — ABC123"
            )
        ])
        try PropertyListEncoder().encode(state)
            .write(to: root.appendingPathComponent("state.plist"), options: .atomic)

        let recorder = RegistrationRecorder()
        let workflow = SandfortWorkflow(
            environment: .productionWorkspace(
                profile: profile,
                rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            ),
            provider: IdleProvider(),
            deleteUTMRegistration: { name in await recorder.append(name) }
        )

        try await workflow.deleteEnvironment(event: { _ in })

        let deletedNames = await recorder.snapshot()
        XCTAssertEqual(deletedNames, [
            "\(prefix) — Protected Baseline ABC123",
            "\(prefix) — Baseline Setup ABC123",
            "\(prefix) — Instance 1 — ABC123"
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
