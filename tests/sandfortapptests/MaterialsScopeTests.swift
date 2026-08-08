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

/// The materials store exists so a Reset can put back **what the user approved**
/// rather than re-reading where it came from. That distinction is the point:
/// pick `~/Downloads` in March, reset in June, and re-reading would send in
/// whatever is there now — a bank statement, say — to a sandbox about to run
/// hostile code.
///
/// These cover the store's lifecycle. Whether an image may be attached at all is
/// `MaterialsAttachmentTests`.
final class MaterialsScopeTests: XCTestCase {
    /// Records what it was asked to attach, so the workflow's decisions are
    /// observable without a hypervisor.
    private final class RecordingProvider: VirtualMachineProvider, @unchecked Sendable {
        var identifier: String { "test.recording" }
        var attached: [(name: String, bundle: String)] = []
        var attachShouldFail = false

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
        func attachMaterials(_ image: MaterialsImage, to bundleURL: URL,
                             profile: LinuxGuestProfile) throws {
            if attachShouldFail { throw CocoaError(.fileWriteNoPermission) }
            attached.append((image.displayName, bundleURL.lastPathComponent))
        }
        var detached: [String] = []
        func detachMaterials(from bundleURL: URL) throws {
            detached.append(bundleURL.lastPathComponent)
        }
        func ensureBundleNotRunning(at bundleURL: URL) throws {}
    }

    private var provider = RecordingProvider()
    private final class Unregistrations: @unchecked Sendable {
        var names: [String] = []
    }
    private var unregistered = Unregistrations()

    private func makeWorkflow(
        deleteRegistration: (@Sendable (String) async throws -> Void)? = nil
    ) throws -> (SandfortWorkflow, URL) {
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

        provider = RecordingProvider()
        unregistered = Unregistrations()
        let workflow = SandfortWorkflow(
            environment: .productionWorkspace(
                profile: profile, rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            ),
            provider: provider,
            deleteUTMRegistration: deleteRegistration
                ?? { [unregistered] name in unregistered.names.append(name) },
            // Never reach the real launcher. It hands the bundle to UTM, and a
            // synthetic bundle makes UTM show "Cannot import this VM" — a dialog
            // on the developer's machine, from a unit test. It also polled for
            // 16 seconds per test waiting for a registration that never came.
            launchVirtualMachine: { _, _, _ in }
        )
        return (workflow, root)
    }

    /// Attaching must **never** ask UTM to forget the instance.
    ///
    /// This once did, to bust UTM's configuration cache — and UTM's `delete`
    /// command is documented as "Delete a virtual machine. All data will be
    /// deleted, there is no confirmation!". When UTM happened to have the
    /// instance registered, attaching a file to it destroyed the bundle: the
    /// record survived, the disk did not, and Resume then reported an instance
    /// that did not exist. It cost a real openSUSE instance minutes after that
    /// baseline finished a 45-minute rebuild.
    ///
    /// `runClean` can call it safely only because it recreates the bundle
    /// immediately afterwards. Nothing else may, and a stale drive list is a far
    /// smaller problem than a deleted sandbox.
    func testAttachingNeverAsksUTMToDeleteTheInstance() async throws {
        let (workflow, root) = try makeWorkflow()

        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("probe.zip", in: root), event: { _ in }
        )

        XCTAssertTrue(
            unregistered.names.isEmpty,
            "UTM's delete command destroys the VM's data; attaching a file must not invoke it"
        )
    }

    func testRemovingNeverAsksUTMToDeleteTheInstance() async throws {
        let (workflow, root) = try makeWorkflow()
        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("bye.zip", in: root), event: { _ in }
        )
        unregistered.names.removeAll()

        _ = try await workflow.removeMaterials(fromInstance: 1)

        XCTAssertTrue(unregistered.names.isEmpty, "same hazard, same rule")
    }

    /// And the bundle it was attached to still exists afterwards, which is the
    /// property the user actually cares about.
    func testTheInstanceBundleSurvivesAnAttach() async throws {
        let (workflow, root) = try makeWorkflow()
        let bundle = root.appendingPathComponent("Virtual Machines/Instance1.utm")

        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("keep.zip", in: root), event: { _ in }
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundle.path),
            "attaching a file must not remove the sandbox it was attached to"
        )
    }

    private func source(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x33, count: 1024).write(to: url)
        return url
    }

    private func storedImage(in root: URL, instance: Int = 1) -> URL {
        root.appendingPathComponent("Materials/instance-\(instance).iso")
    }

    // MARK: - Attaching records both the image and the metadata

    func testAttachingStoresTheImageAndRecordsIt() async throws {
        let (workflow, root) = try makeWorkflow()

        let state = try await workflow.attachMaterials(
            toInstance: 1, from: try source("take-home.zip", in: root), event: { _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: storedImage(in: root).path),
                      "the packed image is kept outside the bundle so a Reset can restore it")
        let instance = try XCTUnwrap(state.resolvedInstances.first)
        XCTAssertEqual(instance.materialsDisplayName, "take-home.zip")
        XCTAssertEqual(instance.materialsByteCount, 1024)
        XCTAssertNotNil(instance.materialsPackedAt)
        XCTAssertTrue(instance.hasMaterials)
        XCTAssertEqual(provider.attached.map(\.name), ["take-home.zip"])
    }

    /// A store entry with no drive would be re-attached by the next Reset,
    /// quietly reintroducing materials the user was told did not go on.
    func testAFailedAttachLeavesNothingInTheStore() async throws {
        let (workflow, root) = try makeWorkflow()
        provider.attachShouldFail = true

        do {
            _ = try await workflow.attachMaterials(
                toInstance: 1, from: try source("nope.zip", in: root), event: { _ in }
            )
            XCTFail("a failed attach must not report success")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: storedImage(in: root).path))
        let state = await workflow.currentState()
        XCTAssertFalse(try XCTUnwrap(state?.resolvedInstances.first).hasMaterials)
    }

    // MARK: - Reset restores what was approved, not what is there now

    func testResetReattachesTheApprovedImageRatherThanRereadingTheSource() async throws {
        let (workflow, root) = try makeWorkflow()
        let picked = try source("challenge.zip", in: root)
        _ = try await workflow.attachMaterials(toInstance: 1, from: picked, event: { _ in })

        // The source changes after the user approved it. This is the whole
        // hazard: a folder that held a challenge in March may hold anything in
        // June, and Reset must not go looking.
        try Data(repeating: 0xFF, count: 4096).write(to: picked)
        let approved = try Data(contentsOf: storedImage(in: root))

        provider.attached.removeAll()
        try await workflow.runClean(instanceNumber: 1, networkMode: .offline, event: { _ in })

        XCTAssertEqual(provider.attached.map(\.name), ["challenge.zip"],
                       "Reset re-attaches, and re-attaches the approved image")
        XCTAssertEqual(try Data(contentsOf: storedImage(in: root)), approved,
                       "the stored bytes are untouched by the source changing")
    }

    /// Materials are a convenience. A missing store entry must not strand an
    /// instance the user is trying to run.
    func testResetSurvivesAMissingStoredImage() async throws {
        let (workflow, root) = try makeWorkflow()
        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("gone.zip", in: root), event: { _ in }
        )
        try FileManager.default.removeItem(at: storedImage(in: root))

        provider.attached.removeAll()
        try await workflow.runClean(instanceNumber: 1, networkMode: .offline, event: { _ in })

        XCTAssertTrue(provider.attached.isEmpty, "nothing to attach")
        let state = await workflow.currentState()
        XCTAssertFalse(
            try XCTUnwrap(state?.resolvedInstances.first).hasMaterials,
            "and the record is cleared, so it does not claim materials it does not have"
        )
    }

    // MARK: - Removal and cleanup

    func testRemovingMaterialsClearsTheStoreAndTheRecord() async throws {
        let (workflow, root) = try makeWorkflow()
        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("bye.zip", in: root), event: { _ in }
        )

        let state = try await workflow.removeMaterials(fromInstance: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storedImage(in: root).path))
        XCTAssertFalse(try XCTUnwrap(state.resolvedInstances.first).hasMaterials)
    }

    func testDeletingAnInstanceTakesItsStoredImageWithIt() async throws {
        let (workflow, root) = try makeWorkflow()
        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("doomed.zip", in: root), event: { _ in }
        )

        _ = try await workflow.deleteInstance(number: 1, event: { _ in })

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storedImage(in: root).path),
            "instance numbers are never reused, so a lingering image is simply orphaned"
        )
    }

    /// Removing materials must take them out of the bundle, not just out of the
    /// record. Otherwise a user removes their file, resumes, and finds it still
    /// mounted — a copy of it left somewhere they believe is empty.
    func testRemovingMaterialsDetachesThemFromTheBundle() async throws {
        let (workflow, root) = try makeWorkflow()
        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("bye.zip", in: root), event: { _ in }
        )

        _ = try await workflow.removeMaterials(fromInstance: 1)

        XCTAssertEqual(
            provider.detached, ["Instance1.utm"],
            "the drive and the image are removed from the instance itself"
        )
    }

    /// A failed save restores the bundle from the Trash, so the stored image must
    /// still be there — otherwise the instance comes back claiming materials it
    /// no longer has.
    ///
    /// Making `save` fail without also breaking the *read* is the fiddly part.
    /// Replacing `state.plist` with a directory fails `currentState()` first, so
    /// `deleteInstance` throws at its very first line and never reaches the
    /// store — the assertion then passes for entirely the wrong reason. The
    /// environment root is made read-only instead: `state.plist` still reads,
    /// `Virtual Machines/` is a separate directory so trashing the bundle still
    /// works, and only the atomic rewrite of `state.plist` — which needs a
    /// temporary file beside it — fails.
    func testAFailedDeleteKeepsTheStoredImage() async throws {
        let (workflow, root) = try makeWorkflow()
        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("keep.zip", in: root), event: { _ in }
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: root.path
            )
        }

        do {
            _ = try await workflow.deleteInstance(number: 1, event: { _ in })
            XCTFail("the delete could not have been recorded")
        } catch {}

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: self.storedImage(in: root).path),
            "the approved image survives a delete that could not be recorded"
        )
    }

    func testDeletingTheEnvironmentClearsTheWholeStore() async throws {
        let (workflow, root) = try makeWorkflow()
        _ = try await workflow.attachMaterials(
            toInstance: 1, from: try source("all-gone.zip", in: root), event: { _ in }
        )

        _ = try await workflow.deleteEnvironment(event: { _ in })

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Materials").path
            ),
            "every stored image is a copy of something the user chose"
        )
    }
}
