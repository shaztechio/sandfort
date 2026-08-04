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

/// Reset, Delete Instance, Rebuild, and Delete Environment all refuse while a VM
/// holds its disk, and each now offers to shut the blockers down first. The
/// scope of that offer is the part worth pinning: Reset and Delete Instance must
/// only ever name the one instance, while Rebuild and Delete Environment reach
/// the baseline and every instance.
///
/// Getting this wrong is invisible in the UI and expensive: an over-broad scope
/// powers down a guest the user never mentioned.
final class RunningVirtualMachineScopeTests: XCTestCase {
    /// Reports whichever bundles the test declares busy, so "running" can be
    /// simulated without a hypervisor.
    private struct BusyProvider: VirtualMachineProvider {
        var busyPathFragments: [String]
        var identifier: String { "test.provider" }

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
        func repairBundle(at bundleURL: URL, profile: LinuxGuestProfile) throws {}
        func ensureBundleNotRunning(at bundleURL: URL) throws {
            if busyPathFragments.contains(where: { bundleURL.path.contains($0) }) {
                throw SandboxError.virtualMachineRunning
            }
        }
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Builds saved state describing a baseline and two instances on disk.
    private func makeWorkflow(busy: [String], root: URL) throws -> SandfortWorkflow {
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
            setupVMName: "Sandfort — Baseline",
            sandboxVMName: nil,
            guestProfileID: profile.id,
            guestProfileRevision: profile.revision,
            guestImageSHA256: profile.image.sha256
        )
        state.replaceInstances([
            SandboxInstance(number: 1, bundlePath: try bundle("Instance1"),
                            vmName: "Sandfort — Instance 1", label: nil),
            SandboxInstance(number: 2, bundlePath: try bundle("Instance2"),
                            vmName: "Sandfort — Instance 2", label: nil)
        ])
        let data = try PropertyListEncoder().encode(state)
        try data.write(to: root.appendingPathComponent("state.plist"))

        return SandfortWorkflow(
            environment: .productionWorkspace(
                profile: profile,
                rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            ),
            provider: BusyProvider(busyPathFragments: busy),
            deleteUTMRegistration: { _ in }
        )
    }

    /// Reset and Delete Instance must not report a different instance.
    func testInstanceScopeIgnoresOtherInstancesAndTheBaseline() async throws {
        let root = try workspace()
        let workflow = try makeWorkflow(busy: ["Baseline", "Instance2"], root: root)
        let running = await workflow.runningVirtualMachines(instanceNumber: 1)
        XCTAssertTrue(running.isEmpty, "instance 1 is idle; nothing else is in scope")
    }

    func testInstanceScopeReportsItsOwnInstance() async throws {
        let root = try workspace()
        let workflow = try makeWorkflow(busy: ["Instance1"], root: root)
        let running = await workflow.runningVirtualMachines(instanceNumber: 1)
        XCTAssertEqual(running.count, 1)
    }

    /// Rebuild and Delete Environment touch everything, including the baseline.
    func testEnvironmentScopeCoversTheBaselineAndEveryInstance() async throws {
        let root = try workspace()
        let workflow = try makeWorkflow(busy: ["Baseline", "Instance1", "Instance2"], root: root)
        let running = await workflow.runningVirtualMachines(instanceNumber: nil)
        XCTAssertEqual(running.count, 3)
        XCTAssertTrue(running.contains("Protected Baseline"))
    }

    func testEnvironmentScopeNamesOnlyWhatIsActuallyRunning() async throws {
        let root = try workspace()
        let workflow = try makeWorkflow(busy: ["Instance2"], root: root)
        let running = await workflow.runningVirtualMachines(instanceNumber: nil)
        XCTAssertEqual(running.count, 1, "an idle baseline must not be listed")
        XCTAssertFalse(running.contains("Protected Baseline"))
    }

    /// Nothing running means no prompt at all: the operation proceeds directly.
    func testNothingRunningReportsNothing() async throws {
        let root = try workspace()
        let workflow = try makeWorkflow(busy: [], root: root)
        let scoped = await workflow.runningVirtualMachines(instanceNumber: 1)
        let all = await workflow.runningVirtualMachines(instanceNumber: nil)
        XCTAssertTrue(scoped.isEmpty)
        XCTAssertTrue(all.isEmpty)
    }
}
