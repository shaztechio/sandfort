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

/// `InstanceLaunchSummaryTests` proves the formatter can produce these lines.
/// This proves the workflow actually emits them — which is the reported gap:
/// `resumeInstance` took no `event` closure at all and logged nothing, so the
/// launch a user repeats most often was the one that said least.
///
/// A test that only exercised the formatter would pass with the workflow never
/// calling it.
final class LaunchLoggingTests: XCTestCase {
    private struct SilentProvider: VirtualMachineProvider {
        var identifier: String { "test.silent" }

        func createSetupBundle(
            at bundleURL: URL, name: String, from imageURL: URL,
            profile: LinuxGuestProfile, credentials: SandboxCredentials, tools: SandboxToolSelection
        ) throws {}
        func createCleanBundle(
            from setupBundleURL: URL, at bundleURL: URL, name: String,
            profile: LinuxGuestProfile, networkMode: SandboxNetworkMode
        ) throws {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        }
        func resetCleanBundle(
            from setupBundleURL: URL, at bundleURL: URL,
            profile: LinuxGuestProfile, networkMode: SandboxNetworkMode
        ) throws {}
        func setDisplayName(_ name: String, at bundleURL: URL) throws {}
        func repairBundle(at bundleURL: URL, profile: LinuxGuestProfile, role: VirtualMachineRole) throws {}
        func attachMaterials(_ image: MaterialsImage, to bundleURL: URL, profile: LinuxGuestProfile) throws {}
        func detachMaterials(from bundleURL: URL) throws {}
        func ensureBundleNotRunning(at bundleURL: URL) throws {}
    }

    /// Collects what a launch said, without ever reaching UTM.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        var handler: @Sendable (WorkflowEvent) -> Void {
            { [self] event in
                lock.lock()
                defer { lock.unlock() }
                switch event {
                case .log(let text), .phase(let text):
                    lines.append(text)
                default:
                    break
                }
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }
    }

    private func workflow(
        materials: String?,
        tools: SandboxToolSelection = .recommended
    ) throws -> SandfortWorkflow {
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
            tools: tools,
            setupBundlePath: try bundle("Baseline"),
            sandboxBundlePath: nil,
            setupVMName: "Sandfort — Protected Baseline",
            sandboxVMName: nil,
            guestProfileID: profile.id,
            guestProfileRevision: profile.revision,
            guestImageSHA256: profile.image.sha256
        )
        var instance = SandboxInstance(
            number: 1, bundlePath: try bundle("Instance1"),
            vmName: "Sandfort — Instance 1", label: nil
        )
        instance.materialsDisplayName = materials
        instance.materialsByteCount = materials == nil ? nil : 6144
        instance.materialsPackedAt = materials == nil ? nil : Date()
        state.replaceInstances([instance])
        try PropertyListEncoder().encode(state)
            .write(to: root.appendingPathComponent("state.plist"))

        return SandfortWorkflow(
            environment: .productionWorkspace(
                profile: profile, rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            ),
            provider: SilentProvider(),
            deleteUTMRegistration: { _ in },
            launchVirtualMachine: { _, _, _ in }
        )
    }

    /// The reported gap.
    func testResumeSaysWhatTheInstanceCarries() async throws {
        let workflow = try workflow(materials: "materials-probe.txt")
        let recorder = Recorder()

        try await workflow.resumeInstance(instanceNumber: 1, event: recorder.handler)

        let text = recorder.text
        XCTAssertTrue(text.contains("Instance 1"), text)
        XCTAssertTrue(text.contains("Materials: materials-probe.txt"), text)
        XCTAssertTrue(text.contains("Baseline tools:"), text)
    }

    /// Resume preserves the instance's last mode and does not read it back, so
    /// it must not print one.
    func testResumeDoesNotAnnounceANetworkModeItDoesNotKnow() async throws {
        let workflow = try workflow(materials: nil)
        let recorder = Recorder()

        try await workflow.resumeInstance(instanceNumber: 1, event: recorder.handler)

        let text = recorder.text
        XCTAssertFalse(text.contains("Internet-enabled"), text)
        XCTAssertTrue(text.contains("last ran with"), text)
    }

    func testResumeSaysWhenNothingIsAttached() async throws {
        let workflow = try workflow(materials: nil)
        let recorder = Recorder()

        try await workflow.resumeInstance(instanceNumber: 1, event: recorder.handler)

        XCTAssertTrue(recorder.text.contains("Materials: none attached."), recorder.text)
    }

    /// Reset rebuilds the bundle and re-attaches, and states the mode it chose.
    func testResetStatesTheModeItChoseAndWhatIsAttached() async throws {
        let workflow = try workflow(materials: nil)
        let recorder = Recorder()

        try await workflow.runClean(
            instanceNumber: 1, networkMode: .internet, event: recorder.handler
        )

        let text = recorder.text
        XCTAssertTrue(text.contains("Internet-enabled"), text)
        XCTAssertTrue(text.contains("Materials: none attached."), text)
    }

    func testCreatingAnInstanceDescribesItToo() async throws {
        let workflow = try workflow(materials: nil)
        let recorder = Recorder()

        _ = try await workflow.createCleanInstance(
            networkMode: .offline, label: nil, event: recorder.handler
        )

        let text = recorder.text
        XCTAssertTrue(text.contains("offline"), text)
        XCTAssertTrue(text.contains("Materials: none attached."), text)
    }

    /// The guest password is in the same state object the summary reads from.
    ///
    /// The absence assertions here pass for free if nothing is logged at all —
    /// which is exactly the state this whole change fixes — so the test first
    /// establishes that the summary *was* produced. Without that, removing every
    /// log line would make this test greener, not redder.
    func testNoLaunchPathEverLogsTheGuestPassword() async throws {
        var tools = SandboxToolSelection.recommended
        tools.customSetupScript = "echo hunter2-should-never-appear"
        let workflow = try workflow(materials: "secret-looking.zip", tools: tools)
        let saved = await workflow.currentState()
        let password = try XCTUnwrap(saved).credentials.password

        let recorder = Recorder()
        try await workflow.resumeInstance(instanceNumber: 1, event: recorder.handler)
        try await workflow.runClean(instanceNumber: 1, networkMode: .offline, event: recorder.handler)

        let text = recorder.text
        XCTAssertTrue(
            text.contains("Materials: secret-looking.zip"),
            "nothing was logged, so the absence assertions below prove nothing: \(text)"
        )
        XCTAssertTrue(
            text.contains("custom setup script"),
            "the script must be mentioned — it is its contents that must not be"
        )
        XCTAssertFalse(text.contains(password), "the guest password was logged")
        XCTAssertFalse(text.contains("hunter2-should-never-appear"), "the script body was logged")
    }
}
