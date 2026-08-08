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

import AppKit
import Foundation

struct SandfortWorkflowEnvironment: Sendable {
    let supportDirectoryName: String
    let legacySupportDirectoryName: String?
    let vmNamePrefix: String
    let defaultProfile: LinuxGuestProfile
    let supportedProfiles: [LinuxGuestProfile]
    let legacyProfiles: [LinuxGuestProfile]
    let rootURLOverride: URL?
    let cacheURLOverride: URL?
    let preserveExistingDisplayNames: Bool

    static let production = SandfortWorkflowEnvironment(
        supportDirectoryName: "Sandfort",
        legacySupportDirectoryName: "Sandbox" + "VM",
        vmNamePrefix: "Sandfort",
        defaultProfile: LinuxGuestCatalog.defaultProfile,
        supportedProfiles: LinuxGuestCatalog.supportedProfiles,
        // Empty since Ubuntu revision 2. State written before revisions were
        // persisted was built by a provisioner that still left a console login
        // prompt on VT1, so it cannot be mapped onto any current profile. Such a
        // baseline now reports incompatibility and requires Rebuild, which is
        // correct: mapping it to the newest revision would silently claim
        // provisioning guarantees that baseline does not have.
        legacyProfiles: [],
        rootURLOverride: nil,
        cacheURLOverride: nil,
        preserveExistingDisplayNames: false
    )

    static func qualification(profile: LinuxGuestProfile) -> SandfortWorkflowEnvironment {
        SandfortWorkflowEnvironment(
            supportDirectoryName: "Sandfort \(profile.distributionName) Qualification",
            legacySupportDirectoryName: nil,
            vmNamePrefix: "Sandfort \(profile.distributionName) Qualification",
            defaultProfile: profile,
            supportedProfiles: [profile],
            legacyProfiles: [],
            rootURLOverride: nil,
            cacheURLOverride: nil,
            preserveExistingDisplayNames: false
        )
    }

    static func productionWorkspace(
        profile: LinuxGuestProfile,
        rootURL: URL,
        cacheURL: URL,
        preserveExistingDisplayNames: Bool = false
    ) -> SandfortWorkflowEnvironment {
        SandfortWorkflowEnvironment(
            supportDirectoryName: "Sandfort",
            legacySupportDirectoryName: nil,
            vmNamePrefix: "Sandfort — \(profile.displayName)",
            defaultProfile: profile,
            supportedProfiles: [profile],
            // Empty for the same reason as `production` above: no current
            // profile revision describes a pre-revision baseline.
            legacyProfiles: [],
            rootURLOverride: rootURL,
            cacheURLOverride: cacheURL,
            preserveExistingDisplayNames: preserveExistingDisplayNames
        )
    }
}

actor SandfortWorkflow {
    typealias DeleteUTMRegistration = @Sendable (String) async throws -> Void
    /// Opening a bundle and starting it. Injectable for the same reason
    /// `deleteUTMRegistration` is, and for one more: a test that reaches the real
    /// implementation hands the user's actual UTM a synthetic bundle, which UTM
    /// then refuses with "Cannot import this VM" — a visible dialog on someone's
    /// machine, caused by a unit test.
    typealias LaunchVirtualMachine = @Sendable (URL, String, @escaping @Sendable (String) -> Void) async -> Void

    private let downloader = NativeDownloader()
    private let fileManager = FileManager.default
    private let provider: any VirtualMachineProvider
    private let environment: SandfortWorkflowEnvironment
    private let deleteUTMRegistration: DeleteUTMRegistration
    private let launchVirtualMachine: LaunchVirtualMachine

    init(
        environment: SandfortWorkflowEnvironment = .production,
        provider: (any VirtualMachineProvider)? = nil,
        deleteUTMRegistration: @escaping DeleteUTMRegistration = {
            try await UTMRegistryController.deleteVirtualMachine(named: $0)
        },
        launchVirtualMachine: @escaping LaunchVirtualMachine = { bundle, name, log in
            await UTMLauncher.openAndStart(bundle: bundle, name: name, log: log)
        }
    ) {
        self.environment = environment
        self.provider = provider ?? UTMBundleBuilder()
        self.deleteUTMRegistration = deleteUTMRegistration
        self.launchVirtualMachine = launchVirtualMachine
    }

    private var canonicalRootURL: URL {
        if let rootURLOverride = environment.rootURLOverride { return rootURLOverride }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(environment.supportDirectoryName, isDirectory: true)
    }

    private var legacyRootURL: URL? {
        guard let legacySupportDirectoryName = environment.legacySupportDirectoryName else { return nil }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(legacySupportDirectoryName, isDirectory: true)
    }

    private var rootURL: URL {
        guard let legacyRootURL else { return canonicalRootURL }
        if fileManager.fileExists(atPath: canonicalRootURL.path)
            || !fileManager.fileExists(atPath: legacyRootURL.path) {
            return canonicalRootURL
        }
        return legacyRootURL
    }

    private var cacheURL: URL {
        environment.cacheURLOverride ?? rootURL.appendingPathComponent("Cache", isDirectory: true)
    }
    private var vmURL: URL { rootURL.appendingPathComponent("Virtual Machines", isDirectory: true) }
    private var stateURL: URL { rootURL.appendingPathComponent("state.plist") }
    func currentState() -> SandboxState? {
        migrateLegacySupportDirectoryIfNeeded()
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        guard var state = try? PropertyListDecoder().decode(SandboxState.self, from: data) else { return nil }
        if migrateNamesAndInstances(in: &state) {
            try? save(state)
        }
        if let profile = try? guestProfile(for: state) {
            // Before Finish Setup that bundle is the provisioning VM; after it,
            // it is the protected baseline. The stage says which, so nothing has
            // to guess from a name.
            try? provider.repairBundle(
                at: URL(fileURLWithPath: state.setupBundlePath),
                profile: profile,
                role: state.stage == .provisioning ? .setup : .protectedBaseline
            )
            for instance in state.resolvedInstances {
                try? provider.repairBundle(
                    at: URL(fileURLWithPath: instance.bundlePath),
                    profile: profile,
                    role: .cleanInstance
                )
            }
        }
        return state
    }

    private func migrateLegacySupportDirectoryIfNeeded() {
        guard let legacyRootURL,
              !fileManager.fileExists(atPath: canonicalRootURL.path),
              fileManager.fileExists(atPath: legacyRootURL.path) else { return }
        do {
            let oldRoot = legacyRootURL
            let newRoot = canonicalRootURL
            try fileManager.moveItem(at: oldRoot, to: newRoot)

            let migratedStateURL = newRoot.appendingPathComponent("state.plist")
            guard fileManager.fileExists(atPath: migratedStateURL.path) else { return }
            let data = try Data(contentsOf: migratedStateURL)
            var state = try PropertyListDecoder().decode(SandboxState.self, from: data)
            func migratedPath(_ path: String) -> String {
                guard path == oldRoot.path || path.hasPrefix(oldRoot.path + "/") else { return path }
                return newRoot.path + String(path.dropFirst(oldRoot.path.count))
            }
            state.setupBundlePath = migratedPath(state.setupBundlePath)
            state.sandboxBundlePath = state.sandboxBundlePath.map(migratedPath)
            var instances = state.resolvedInstances
            for index in instances.indices {
                instances[index].bundlePath = migratedPath(instances[index].bundlePath)
            }
            state.replaceInstances(instances)
            let migratedData = try PropertyListEncoder().encode(state)
            try migratedData.write(to: migratedStateURL, options: .atomic)
        } catch {
            // Continue using the former directory if an in-place migration
            // cannot be completed; never make existing VMs disappear.
            if fileManager.fileExists(atPath: canonicalRootURL.path),
               !fileManager.fileExists(atPath: legacyRootURL.path) {
                try? fileManager.moveItem(at: canonicalRootURL, to: legacyRootURL)
            }
        }
    }

    func doctor() async throws -> String {
        let state = currentState()
        let architecture = HostArchitecture.description()
        let stateDescription = state.map {
            "Sandbox state: \($0.stage.rawValue), \($0.resolvedInstances.count) clean instance(s)."
        } ?? "No sandbox has been created yet."
        // Reported for the environment's own resolved profile rather than a
        // process-wide default: each workspace supports exactly one.
        let profile = environment.defaultProfile
        let accelerationDescription = HostArchitecture.current
            .canHardwareAccelerate(profile.hardware.utmArchitecture)
            ? ""
            : "\nThis Mac cannot hardware-accelerate a \(profile.hardware.utmArchitecture) guest, "
                + "so \(profile.displayName) cannot be created here."
        let resourcesDescription = "This Mac has \(hostMemoryDescription) of memory"
            + (hostFreeSpaceDescription.map { " and \($0) free for sandboxes" } ?? "")
            + ". A baseline needs about \(profile.hardware.diskSizeGiB) GiB of disk and "
            + "\(profile.hardware.memoryMiB / 1024) GiB of memory while it runs, "
            + "and each instance is a separate copy."
        guard let utm = UTMLauncher.installation else {
            // Reported rather than thrown: "what is wrong with my Mac" is the
            // question this answers, so the answer should be actionable.
            return "UTM is not installed. Sandfort needs it to run virtual machines. "
                + "Download it from \(UTMLauncher.downloadPage.absoluteString), then run this check again.\n"
                + "This Mac is \(architecture).\(accelerationDescription)\n"
                + "\(resourcesDescription) \(stateDescription)"
        }
        let version = utm.version.map { "UTM \($0)" } ?? "UTM"
        // Which UTM is driven was previously visible nowhere. More than one
        // registers for an ordinary reason — an installer disk image left
        // mounted after an upgrade — and a baseline built against one copy
        // should not be resumed against another without the user ever being
        // told there was a choice.
        let otherCopies = utm.alternatives.isEmpty ? "" :
            "\nOther copies of UTM are also registered on this Mac, and are not being used:\n"
                + utm.alternatives.map { "  \($0.path)" }.joined(separator: "\n")
                + "\nSandfort uses the one above. Eject or remove the others to be certain."
        return "\(version) is installed at \(utm.applicationURL.path).\(otherCopies)\n"
            + "This Mac is \(architecture).\(accelerationDescription)\n"
            + "\(resourcesDescription) \(stateDescription)"
    }

    private var hostMemoryDescription: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(bitPattern: ProcessInfo.processInfo.physicalMemory),
            countStyle: .memory
        )
    }

    /// Free space on the volume that holds the app-owned sandbox directory.
    ///
    /// Asked of the deepest ancestor that exists: on a first run neither the
    /// support directory nor its parent has been created yet, and a capacity
    /// query against a missing path returns nothing at all.
    private var hostFreeSpaceDescription: String? {
        var url = canonicalRootURL
        while !fileManager.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        guard let capacity = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else { return nil }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }

    func create(
        rebuild: Bool = false,
        profile: LinuxGuestProfile = LinuxGuestCatalog.defaultProfile,
        tools: SandboxToolSelection,
        password: String? = nil,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws -> SandboxState {
        guard environment.supportedProfiles.contains(profile) else {
            throw SandboxError.unsupportedGuestProfile(profile.id)
        }
        // A guest whose architecture differs from the host's cannot be
        // hardware-accelerated: UTM's `hasHypervisorSupport` is false, so it
        // ignores `"Hypervisor": true` and starts QEMU with `-accel tcg`
        // without saying so. Today this cannot fire — every profile is aarch64
        // and every supported host is Apple silicon — but it has to exist
        // before the first x86-64 profile does, because the failure it prevents
        // looks like a working build that takes all day.
        guard HostArchitecture.current.canHardwareAccelerate(profile.hardware.utmArchitecture) else {
            throw SandboxError.unacceleratedGuestArchitecture(
                profileName: profile.displayName,
                guestArchitecture: profile.hardware.utmArchitecture,
                host: HostArchitecture.current.name
            )
        }
        // Validate user input before deleting an existing baseline during Rebuild.
        let requestedCredentials = try password.map { try profile.credentials(password: $0) }
        guard UTMLauncher.isInstalled else { throw SandboxError.utmNotInstalled }
        if rebuild {
            if let existingState = currentState() {
                let baseline = URL(fileURLWithPath: existingState.setupBundlePath)
                if fileManager.fileExists(atPath: baseline.path) {
                    try provider.ensureBundleNotRunning(at: baseline)
                }
                for instance in existingState.resolvedInstances {
                    let bundle = URL(fileURLWithPath: instance.bundlePath)
                    if fileManager.fileExists(atPath: bundle.path) {
                        try provider.ensureBundleNotRunning(at: bundle)
                    }
                }
                event(.phase("Removing the old baseline and instances from UTM…"))
                event(.log("Opening UTM if needed, then waiting for it to confirm each old registration is removed."))
                for name in existingState.utmRegistrationNames {
                    event(.log("Removing \(name) from the UTM library."))
                    try await deleteUTMRegistration(name)
                    event(.log("UTM confirmed that \(name) was removed."))
                }
            }
            event(.phase("Removing the app-owned sandbox…"))
            if fileManager.fileExists(atPath: vmURL.path) { try fileManager.removeItem(at: vmURL) }
            // Removed deliberately rather than left to the root going away: the
            // root survives a Rebuild, and materials are the user's own files.
            try removeAllStoredMaterials()
            if fileManager.fileExists(atPath: stateURL.path) { try fileManager.removeItem(at: stateURL) }
        } else if currentState() != nil {
            throw SandboxError.alreadyExists
        }

        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: vmURL, withIntermediateDirectories: true)
        let imageURL = try await verifiedImage(for: profile, event: event)
        let credentials = requestedCredentials ?? profile.credentials()
        let instanceTag = String(UUID().uuidString.prefix(6)).uppercased()
        let setupName = baselineSetupName(tag: instanceTag)
        let setupURL = bundleURL(named: protectedBaselineName(tag: instanceTag))

        event(.phase("Creating the UTM virtual machine…"))
        try provider.createSetupBundle(
            at: setupURL,
            name: setupName,
            from: imageURL,
            profile: profile,
            credentials: credentials,
            tools: tools
        )
        let state = SandboxState(
            stage: .provisioning,
            credentials: credentials,
            tools: tools,
            setupBundlePath: setupURL.path,
            sandboxBundlePath: nil,
            setupVMName: setupName,
            setupVMImportedName: setupName,
            sandboxVMName: nil,
            guestProfileID: profile.id,
            guestProfileRevision: profile.revision,
            guestImageSHA256: profile.image.sha256
        )
        try save(state)
        event(.log("\(profile.distributionName) setup opens in a text terminal while it updates itself and installs: \(tools.description), the desktop, and sandbox protections."))
        event(.log("Watch for [Sandfort] status messages in UTM. Setup commonly takes \(profile.setupDurationDescription) and may pause while packages are configured."))
        event(.log("Leave setup running until it verifies every selected tool and powers itself off automatically. Then click Finish Setup."))
        event(.phase("Opening \(profile.distributionName) setup in UTM…"))
        await launchVirtualMachine(setupURL, setupName, { event(.log($0)) })
        return state
    }

    func deleteEnvironment(
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws {
        guard let existingState = currentState() else { throw SandboxError.sandboxNotCreated }
        let baseline = URL(fileURLWithPath: existingState.setupBundlePath)
        if fileManager.fileExists(atPath: baseline.path) {
            try provider.ensureBundleNotRunning(at: baseline)
        }
        for instance in existingState.resolvedInstances {
            let bundle = URL(fileURLWithPath: instance.bundlePath)
            if fileManager.fileExists(atPath: bundle.path) {
                try provider.ensureBundleNotRunning(at: bundle)
            }
        }
        event(.phase("Removing the environment from UTM…"))
        for name in existingState.utmRegistrationNames {
            event(.log("Removing \(name) from the UTM library."))
            try await deleteUTMRegistration(name)
            event(.log("UTM confirmed that \(name) was removed."))
        }
        event(.phase("Removing the app-owned environment…"))
        if fileManager.fileExists(atPath: vmURL.path) { try fileManager.removeItem(at: vmURL) }
        // Removed deliberately rather than left to the root going away: the
        // root survives a Rebuild, and materials are the user's own files.
        try removeAllStoredMaterials()
        if fileManager.fileExists(atPath: stateURL.path) { try fileManager.removeItem(at: stateURL) }
        if environment.rootURLOverride != nil,
           let contents = try? fileManager.contentsOfDirectory(atPath: rootURL.path),
           contents.isEmpty {
            try? fileManager.removeItem(at: rootURL)
        }
    }

    func finishSetup(event: @escaping @Sendable (WorkflowEvent) -> Void) async throws -> SandboxState {
        guard var state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .provisioning else { return state }
        let setupURL = URL(fileURLWithPath: state.setupBundlePath)
        let profile = try guestProfile(for: state, requireExactMetadata: true)
        let instanceTag = tag(for: state)
        let protectedName = protectedBaselineName(tag: instanceTag)
        try provider.setDisplayName(protectedName, at: setupURL)
        try provider.repairBundle(at: setupURL, profile: profile, role: .protectedBaseline)
        let cleanName = instanceName(number: 1, tag: instanceTag)
        let cleanURL = bundleURL(named: cleanName)
        if fileManager.fileExists(atPath: cleanURL.path) { try fileManager.removeItem(at: cleanURL) }
        event(.phase("Creating the clean-run sandbox…"))
        try provider.createCleanBundle(
            from: setupURL,
            at: cleanURL,
            name: cleanName,
            profile: profile,
            networkMode: .offline
        )
        state.stage = .ready
        state.setupVMName = protectedName
        state.replaceInstances([SandboxInstance(number: 1, bundlePath: cleanURL.path, vmName: cleanName)])
        state.nextInstanceNumber = 2
        try save(state)
        event(.log("The protected baseline is now clearly labeled in UTM. Do not start or modify it directly."))
        event(.log("Sandbox Instance 1 has its own disk and UEFI state restored from that baseline."))
        event(.phase("Opening Sandbox Instance 1 in UTM…"))
        await launchVirtualMachine(cleanURL, cleanName, { event(.log($0)) })
        return state
    }

    func createCleanInstance(
        networkMode: SandboxNetworkMode,
        label: String?,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws -> SandboxState {
        guard var state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .ready else { throw SandboxError.setupNotComplete }
        let profile = try guestProfile(for: state)
        let instances = state.resolvedInstances
        let number = state.allocateInstanceNumber()
        let normalizedLabel = try SandboxInstance.normalizedLabel(label)
        let stateTag = tag(for: state)
        let name = instanceName(number: number, label: normalizedLabel, tag: stateTag)
        let destination = bundleURL(named: instanceBundleName(number: number, tag: stateTag))
        event(.phase("Creating Sandbox Instance \(number) from the protected baseline…"))
        try provider.createCleanBundle(
            from: URL(fileURLWithPath: state.setupBundlePath),
            at: destination,
            name: name,
            profile: profile,
            networkMode: networkMode
        )
        let instance = SandboxInstance(
            number: number,
            bundlePath: destination.path,
            vmName: name,
            label: normalizedLabel
        )
        state.replaceInstances(instances + [instance])
        try save(state)
        event(.log("Sandbox Instance \(number) is independent from the other instances and can run at the same time."))
        event(.phase("Opening Sandbox Instance \(number) in UTM…"))
        await launchVirtualMachine(destination, name, { event(.log($0)) })
        return state
    }

    /// Re-attaches a stored image after a Reset rebuilt the bundle.
    ///
    /// A missing store entry is reported and the metadata cleared rather than
    /// failing the launch: materials are a convenience, and a convenience that
    /// has gone missing must not strand an instance the user is trying to run.
    private func reattachStoredMaterials(
        to instance: SandboxInstance,
        at bundle: URL,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) throws {
        let stored = materialsImageURL(forInstance: instance.number)
        guard fileManager.fileExists(atPath: stored.path) else {
            event(.log(
                "Instance \(instance.number) recorded materials, but the stored image is missing, "
                    + "so it starts without them."
            ))
            _ = try? removeMaterials(fromInstance: instance.number)
            return
        }
        let image = try MaterialsPackager.stored(
            at: stored,
            displayName: instance.materialsDisplayName ?? "materials",
            sourcePath: instance.materialsSourcePath ?? "",
            byteCount: instance.materialsByteCount ?? 0,
            payloadIsArchive: instance.materialsIsArchive ?? false
        )
        try provider.attachMaterials(image, to: bundle)
        event(.log(
            "Re-attached \(image.displayName) — the image approved earlier, not a fresh copy of its source."
        ))
    }

    // MARK: - Materials

    /// Packed images live beside the VMs rather than inside them, so a Reset —
    /// which deletes and recreates the whole bundle — can put back exactly what
    /// the user approved.
    private var materialsRootURL: URL {
        rootURL.appendingPathComponent("Materials", isDirectory: true)
    }

    /// Keyed on the permanent instance number, which is never reused, so a
    /// deleted instance's image cannot be inherited by a later one.
    private func materialsImageURL(forInstance number: Int) -> URL {
        materialsRootURL.appendingPathComponent("instance-\(number).iso")
    }

    /// Packs what the user chose, stores it, and attaches it to one stopped
    /// instance. Takes effect the next time that instance is launched.
    func attachMaterials(
        toInstance number: Int,
        from source: URL,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws -> SandboxState {
        guard var state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .ready else { throw SandboxError.setupNotComplete }
        var instances = state.resolvedInstances
        guard let index = instances.firstIndex(where: { $0.number == number }) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        let bundle = URL(fileURLWithPath: instances[index].bundlePath)
        guard fileManager.fileExists(atPath: bundle.path) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        // Rewriting a bundle UTM is running would be changing the configuration
        // under a live VM.
        try provider.ensureBundleNotRunning(at: bundle)

        event(.phase("Preparing materials for Instance \(number)…"))
        let image = try MaterialsPackager.pack(contentsOf: source)
        try fileManager.createDirectory(at: materialsRootURL, withIntermediateDirectories: true)
        let stored = materialsImageURL(forInstance: number)
        try image.data.write(to: stored, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stored.path)

        do {
            try provider.attachMaterials(image, to: bundle)
        } catch {
            // Nothing half-attached: a store entry with no drive would be
            // re-attached by the next Reset, quietly reintroducing materials the
            // user was told did not go on.
            try? fileManager.removeItem(at: stored)
            throw error
        }

        instances[index].materialsDisplayName = image.displayName
        instances[index].materialsSourcePath = image.sourcePath
        instances[index].materialsByteCount = image.byteCount
        instances[index].materialsPackedAt = Date()
        instances[index].materialsIsArchive = image.payloadIsArchive
        state.replaceInstances(instances)
        try save(state)
        event(.log(
            "\(image.displayName) is attached to Instance \(number) as a read-only disc image. "
                + "The guest reads a copy and cannot reach the original."
        ))
        return state
    }

    /// Forgets materials for one instance: the stored image, the metadata, and
    /// the drive, which `repairBundle` drops on the next state read once the
    /// bundle is rewritten by a Reset.
    func removeMaterials(fromInstance number: Int) throws -> SandboxState {
        guard var state = currentState() else { throw SandboxError.sandboxNotCreated }
        var instances = state.resolvedInstances
        guard let index = instances.firstIndex(where: { $0.number == number }) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        try removeStoredMaterials(forInstance: number)
        instances[index].materialsDisplayName = nil
        instances[index].materialsSourcePath = nil
        instances[index].materialsByteCount = nil
        instances[index].materialsPackedAt = nil
        instances[index].materialsIsArchive = nil
        state.replaceInstances(instances)
        try save(state)
        return state
    }

    /// Clears the whole store. Rebuild and Delete Environment both invalidate
    /// every instance, so every stored image is stale — and each is a copy of
    /// something the user chose, which is not a thing to leave lying around.
    private func removeAllStoredMaterials() throws {
        guard fileManager.fileExists(atPath: materialsRootURL.path) else { return }
        try fileManager.removeItem(at: materialsRootURL)
    }

    /// Throws if the image is there and will not go — the same reason
    /// `UTMBundleBuilder` distinguishes absence from failure. Leaving a stored
    /// image behind means the next Reset re-attaches materials the user removed.
    private func removeStoredMaterials(forInstance number: Int) throws {
        let stored = materialsImageURL(forInstance: number)
        guard fileManager.fileExists(atPath: stored.path) else { return }
        try fileManager.removeItem(at: stored)
    }

    func deleteInstance(
        number: Int,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws -> SandboxState {
        guard var state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .ready else { throw SandboxError.setupNotComplete }
        var instances = state.resolvedInstances
        guard let index = instances.firstIndex(where: { $0.number == number }) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        let instance = instances[index]
        let bundle = URL(fileURLWithPath: instance.bundlePath)
        var trashedURL: NSURL?
        if fileManager.fileExists(atPath: bundle.path) {
            try provider.ensureBundleNotRunning(at: bundle)
        }
        event(.phase("Removing Instance \(number) from the UTM library…"))
        event(.log("Waiting for UTM to confirm that \(instance.vmName) is unregistered."))
        try await deleteUTMRegistration(instance.vmName)
        event(.log("UTM confirmed that \(instance.vmName) was removed."))
        if fileManager.fileExists(atPath: bundle.path) {
            event(.phase("Moving Instance \(number) to macOS Trash…"))
            try fileManager.trashItem(at: bundle, resultingItemURL: &trashedURL)
        }
        // The stored image goes with the instance. Leaving it would mean the
        // number is never reused but the file lingers — an orphaned copy of the
        // user's materials outside any bundle.
        try removeStoredMaterials(forInstance: number)
        instances.remove(at: index)
        state.replaceInstances(instances)
        do {
            try save(state)
        } catch {
            if let trashedURL {
                try? fileManager.moveItem(at: trashedURL as URL, to: bundle)
            }
            throw error
        }
        return state
    }

    func renameInstance(number: Int, label: String?) throws -> SandboxState {
        guard var state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .ready else { throw SandboxError.setupNotComplete }
        var instances = state.resolvedInstances
        guard let index = instances.firstIndex(where: { $0.number == number }) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        let normalizedLabel = try SandboxInstance.normalizedLabel(label)
        let name = instanceName(number: number, label: normalizedLabel, tag: tag(for: state))
        try provider.setDisplayName(name, at: URL(fileURLWithPath: instances[index].bundlePath))
        instances[index].label = normalizedLabel
        instances[index].vmName = name
        state.replaceInstances(instances)
        try save(state)
        return state
    }

    func runClean(
        instanceNumber: Int,
        networkMode: SandboxNetworkMode,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws {
        guard let state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .ready else { throw SandboxError.setupNotComplete }
        let profile = try guestProfile(for: state)
        guard let instance = state.resolvedInstances.first(where: { $0.number == instanceNumber }) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        let bundle = URL(fileURLWithPath: instance.bundlePath)
        if fileManager.fileExists(atPath: bundle.path) {
            try provider.ensureBundleNotRunning(at: bundle)
        }
        event(.phase("Removing Instance \(instanceNumber)'s previous UTM registration…"))
        try await deleteUTMRegistration(instance.vmName)
        if fileManager.fileExists(atPath: bundle.path) {
            try fileManager.removeItem(at: bundle)
        }
        let networkDescription = networkMode == .offline ? "offline" : "Internet-enabled"
        event(.phase("Recreating Instance \(instanceNumber) from the protected baseline…"))
        event(.log("Writing a fresh \(networkDescription) UTM configuration so an open UTM cannot reuse the previous network mode."))
        try provider.createCleanBundle(
            from: URL(fileURLWithPath: state.setupBundlePath),
            at: bundle,
            name: instance.vmName,
            profile: profile,
            networkMode: networkMode
        )
        event(.log("Instance \(instanceNumber) was restored with a new VM identity, disk, UEFI state, and network configuration."))
        // The bundle was deleted and rebuilt, so its materials went with it. Put
        // back the image the user approved — not the current contents of wherever
        // it came from, which may be something else entirely by now.
        if instance.hasMaterials {
            try reattachStoredMaterials(to: instance, at: bundle, event: event)
        }
        event(.phase("Opening Sandbox Instance \(instanceNumber) in UTM…"))
        await launchVirtualMachine(bundle, instance.vmName, { event(.log($0)) })
    }

    func resumeInstance(instanceNumber: Int) async throws {
        guard let state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .ready else { throw SandboxError.setupNotComplete }
        guard let instance = state.resolvedInstances.first(where: { $0.number == instanceNumber }) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        let bundle = URL(fileURLWithPath: instance.bundlePath)
        guard fileManager.fileExists(atPath: bundle.path) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        // Resume is the only launch that starts a bundle it did not just write:
        // openSetup repairs through a throwing call, and Reset rebuilds from the
        // baseline. Relying on the `try?` in currentState() meant a repair that
        // failed was discarded and the instance launched anyway, with whatever
        // clipboard, directory, USB, or port-forward setting had drifted in UTM.
        // Reasserting here, and failing if it cannot, is the whole guarantee.
        let profile = try guestProfile(for: state)
        try provider.repairBundle(at: bundle, profile: profile, role: .cleanInstance)
        await launchVirtualMachine(bundle, instance.vmName, { _ in })
    }

    /// Which VMs in scope are running, by display name.
    ///
    /// `instanceNumber` scopes the answer to one instance; nil covers the whole
    /// environment — the baseline and every instance — which is what Rebuild and
    /// Delete Environment touch. Running is the qcow2 lock, the same signal
    /// `ensureBundleNotRunning` uses to refuse.
    func runningVirtualMachines(instanceNumber: Int?) -> [String] {
        guard let state = currentState() else { return [] }
        var running: [String] = []
        func check(_ path: String, _ label: String) {
            let bundle = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: bundle.path) else { return }
            if (try? provider.ensureBundleNotRunning(at: bundle)) == nil { running.append(label) }
        }
        if let instanceNumber {
            if let instance = state.resolvedInstances.first(where: { $0.number == instanceNumber }) {
                check(instance.bundlePath, instance.displayTitle)
            }
            return running
        }
        check(state.setupBundlePath, "Protected Baseline")
        for instance in state.resolvedInstances {
            check(instance.bundlePath, instance.displayTitle)
        }
        return running
    }

    /// Shuts down everything in scope and waits for each to stop, so the caller
    /// can proceed with an operation that needs a quiet disk.
    func shutDownRunningVirtualMachines(
        instanceNumber: Int?,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws {
        guard let state = currentState() else { throw SandboxError.sandboxNotCreated }
        var targets: [(name: String, path: String, label: String)] = []
        if let instanceNumber {
            if let instance = state.resolvedInstances.first(where: { $0.number == instanceNumber }) {
                targets.append((instance.vmName, instance.bundlePath, instance.displayTitle))
            }
        } else {
            if let setupVMName = state.setupVMName {
                targets.append((setupVMName, state.setupBundlePath, "Protected Baseline"))
            }
            for instance in state.resolvedInstances {
                targets.append((instance.vmName, instance.bundlePath, instance.displayTitle))
            }
        }
        for target in targets {
            let bundle = URL(fileURLWithPath: target.path)
            guard fileManager.fileExists(atPath: bundle.path),
                  (try? provider.ensureBundleNotRunning(at: bundle)) == nil else { continue }
            event(.phase("Shutting down \(target.label)…"))
            try UTMRegistryController.stopVirtualMachine(named: target.name)
            try await waitUntilStopped(bundle: bundle, vmName: target.name)
            event(.log("\(target.label) stopped."))
        }
    }

    /// Waits on the qcow2 lock rather than asking UTM. QEMU holds it for as long
    /// as the VM is live, so this needs no Apple Event and is true whether or
    /// not UTM is scriptable.
    private func waitUntilStopped(bundle: URL, vmName: String) async throws {
        for _ in 0..<120 {                       // 30 seconds
            if (try? provider.ensureBundleNotRunning(at: bundle)) != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw UTMRegistryError.stopIgnored(name: vmName)
    }

    /// Asks the guest to shut down, waits for UTM to confirm, then closes the
    /// window UTM leaves behind showing a stopped machine.
    ///
    /// The window is closed only after UTM reports the VM stopped. Closing it
    /// while the guest is still writing would be closing a window over a live
    /// disk, and the point of stopping first is that the disk is quiescent.
    func stopInstance(
        instanceNumber: Int,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws {
        guard let state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard let instance = state.resolvedInstances.first(where: { $0.number == instanceNumber }) else {
            throw SandboxError.sandboxInstanceNotFound
        }
        let bundle = URL(fileURLWithPath: instance.bundlePath)
        event(.phase("Shutting down Instance \(instanceNumber)…"))
        event(.log("Asking the guest to power down. A desktop guest may show a confirmation dialog."))
        try UTMRegistryController.stopVirtualMachine(named: instance.vmName)
        try await waitUntilStopped(bundle: bundle, vmName: instance.vmName)

        event(.log("Instance \(instanceNumber) stopped. Its UTM window stays open; UTM does not "
            + "close it, and no automation client can."))
    }

    func openSetup() async throws {
        guard let state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .provisioning else { throw SandboxError.setupNotComplete }
        let bundleURL = URL(fileURLWithPath: state.setupBundlePath)
        let profile = try guestProfile(for: state, requireExactMetadata: true)
        try provider.repairBundle(at: bundleURL, profile: profile, role: .setup)
        try profile.seedISO(credentials: state.credentials, tools: state.tools ?? .recommended).write(
            to: bundleURL.appendingPathComponent("Data/seed.iso"),
            options: .atomic
        )
        await launchVirtualMachine(bundleURL, state.setupVMName ?? "Sandfort — Baseline Setup", { _ in })
    }

    private func verifiedImage(
        for profile: LinuxGuestProfile,
        event: @escaping @Sendable (WorkflowEvent) -> Void
    ) async throws -> URL {
        let image = profile.image
        let imageURL = cacheURL.appendingPathComponent(image.fileName)
        if fileManager.fileExists(atPath: imageURL.path) {
            event(.phase("Verifying the cached \(profile.distributionName) image…"))
            let checksum = try DiskUtilities.sha256(of: imageURL)
            if checksum == image.sha256 {
                event(.log("Using the previously verified \(profile.distributionName) image."))
                return imageURL
            }
            try fileManager.removeItem(at: imageURL)
            event(.log("The cached image did not verify and was removed."))
        }

        event(.phase("Downloading \(profile.displayName) (\(image.downloadSizeDescription))…"))
        let downloaded = try await downloader.download(from: image.url, to: imageURL) { completed, total in
            event(.progress(completed: completed, total: total))
        }
        event(.phase("Verifying \(profile.distributionName)'s SHA-256 checksum…"))
        let checksum = try DiskUtilities.sha256(of: downloaded)
        guard checksum == image.sha256 else {
            try? fileManager.removeItem(at: downloaded)
            throw SandboxError.checksumMismatch(expected: image.sha256, actual: checksum)
        }
        event(.log("\(profile.distributionName) image verified with the official SHA-256 checksum."))
        return downloaded
    }

    private func guestProfile(
        for state: SandboxState,
        requireExactMetadata: Bool = false
    ) throws -> LinuxGuestProfile {
        try Self.resolveGuestProfile(
            for: state,
            environment: environment,
            requireExactMetadata: requireExactMetadata
        )
    }

    nonisolated static func resolveGuestProfile(
        for state: SandboxState,
        environment: SandfortWorkflowEnvironment = .production,
        requireExactMetadata: Bool = false
    ) throws -> LinuxGuestProfile {
        let profileID = state.guestProfileID ?? environment.defaultProfile.id
        let candidates = environment.supportedProfiles.filter { $0.id == profileID }
        guard !candidates.isEmpty else {
            throw SandboxError.unsupportedGuestProfile(profileID)
        }
        if requireExactMetadata,
           (state.guestProfileRevision == nil || state.guestImageSHA256 == nil) {
            throw SandboxError.incompleteSetupProfileMetadata
        }
        let profile: LinuxGuestProfile?
        if let revision = state.guestProfileRevision {
            profile = candidates.first {
                $0.revision == revision
                    && (state.guestImageSHA256 == nil || $0.image.sha256 == state.guestImageSHA256)
            }
        } else if let imageSHA256 = state.guestImageSHA256 {
            profile = candidates.first { $0.image.sha256 == imageSHA256 }
        } else {
            profile = environment.legacyProfiles.first { $0.id == profileID }
        }
        guard let profile else {
            throw SandboxError.incompatibleGuestProfile(profileID)
        }
        return profile
    }

    private func save(_ state: SandboxState) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try PropertyListEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func bundleURL(named name: String) -> URL {
        vmURL.appendingPathComponent(name + ".utm", isDirectory: true)
    }

    private func baselineSetupName(tag: String) -> String {
        "\(environment.vmNamePrefix) — Baseline Setup \(tag)"
    }

    private func protectedBaselineName(tag: String) -> String {
        "\(environment.vmNamePrefix) — Protected Baseline \(tag)"
    }

    private func instanceName(number: Int, label: String? = nil, tag: String) -> String {
        let labelComponent = label.map { " — \($0)" } ?? ""
        return "\(environment.vmNamePrefix) — Instance \(number)\(labelComponent) — \(tag)"
    }

    private func instanceBundleName(number: Int, tag: String) -> String {
        "\(environment.vmNamePrefix) — Instance \(number) — \(tag)"
    }

    private func tag(for state: SandboxState) -> String {
        state.setupVMName?.split(separator: " ").last.map(String.init)
            ?? String(UUID().uuidString.prefix(6)).uppercased()
    }

    private func migrateNamesAndInstances(in state: inout SandboxState) -> Bool {
        let tag = tag(for: state)
        let desiredBaselineName = state.stage == .provisioning
            ? baselineSetupName(tag: tag)
            : protectedBaselineName(tag: tag)
        var changed = false
        if state.setupVMImportedName == nil, let setupVMName = state.setupVMName {
            // Finish Setup changes the bundle's display name after UTM imported
            // it. UTM 5 can retain that original registration in its open
            // library, so cleanup must try both exact, environment-tagged names.
            // Existing ready state predates `setupVMImportedName`; when it
            // already carries the current protected name, reconstruct the setup
            // name that this naming scheme imported it under. Otherwise retain
            // the saved name before the migration below replaces it.
            state.setupVMImportedName = state.stage == .ready && setupVMName == desiredBaselineName
                ? baselineSetupName(tag: tag)
                : setupVMName
            changed = true
        }
        if !environment.preserveExistingDisplayNames,
           state.setupVMName != desiredBaselineName,
           (try? provider.setDisplayName(desiredBaselineName, at: URL(fileURLWithPath: state.setupBundlePath))) != nil {
            state.setupVMName = desiredBaselineName
            changed = true
        }

        var instances = state.resolvedInstances
        for index in instances.indices {
            let desiredName = instanceName(
                number: instances[index].number,
                label: instances[index].label,
                tag: tag
            )
            guard !environment.preserveExistingDisplayNames,
                  instances[index].vmName != desiredName else { continue }
            if (try? provider.setDisplayName(desiredName, at: URL(fileURLWithPath: instances[index].bundlePath))) != nil {
                instances[index].vmName = desiredName
                changed = true
            }
        }
        if state.instances == nil || state.resolvedInstances != instances {
            state.replaceInstances(instances)
            changed = true
        }
        if state.nextInstanceNumber == nil {
            state.nextInstanceNumber = (instances.map(\.number).max() ?? 0) + 1
            changed = true
        }
        return changed
    }

}

@MainActor
enum UTMLauncher {
    // Immutable and Sendable, so they are readable from the workflow actor as
    // well as the main actor.
    nonisolated static let bundleIdentifier = "com.utmapp.UTM"
    nonisolated static let downloadPage = URL(string: "https://mac.getutm.app/")!

    /// Where UTM actually is, and what version it is.
    struct Installation: Equatable, Sendable {
        let applicationURL: URL
        let version: String?

        /// Other copies registered under the same identifier that were not
        /// chosen. Reported by `doctor()` rather than acted on: when there is
        /// more than one UTM, which one Sandfort drives is worth stating out
        /// loud instead of leaving the user to infer it from a version number.
        let alternatives: [URL]

        /// Spelled out rather than synthesized so `alternatives` can be `let`
        /// and still be omitted. A `let` with an initial value is dropped from
        /// the memberwise initializer entirely, which would have made the
        /// default unusable at the one call site that supplies it.
        init(applicationURL: URL, version: String?, alternatives: [URL] = []) {
            self.applicationURL = applicationURL
            self.version = version
            self.alternatives = alternatives
        }

        /// Derived from wherever UTM was found rather than assumed, so a UTM
        /// outside /Applications no longer produces a "reinstall UTM" error
        /// about an installation that is perfectly fine.
        ///
        /// The variable-store filename comes from the resolved profile rather
        /// than a constant. UTM ships one per architecture, and a second guest
        /// architecture would otherwise be handed the ARM64 store — which boots
        /// nothing and reports nothing useful about why.
        func firmwareURL(for profile: LinuxGuestProfile) -> URL {
            applicationURL
                .appendingPathComponent("Contents/Resources/qemu")
                .appendingPathComponent(profile.hardware.utmFirmwareVarsName)
        }
    }

    /// Resolves UTM by asking Launch Services for its bundle identifier, and
    /// only then falling back to the conventional paths.
    ///
    /// Path-only detection reported UTM as missing whenever it lived anywhere
    /// other than /Applications or ~/Applications, even though macOS knew
    /// exactly where it was. The inputs are injectable so the absent case can be
    /// tested on a machine that has UTM installed.
    ///
    /// Deliberately `nonisolated`: this only queries Launch Services and the
    /// filesystem, and the bundle builder needs it from the workflow actor while
    /// creating a baseline. When it was main-actor isolated that caller reached
    /// it through `MainActor.assumeIsolated`, which asserts rather than hops and
    /// trapped every time a baseline was created.
    /// Launch Services can return several copies for one identifier, and it
    /// does so for an entirely ordinary reason: leaving the installer disk
    /// image mounted after upgrading registers the old UTM inside it. Trashed
    /// copies stay registered too.
    ///
    /// Asking for one URL took whichever macOS happened to prefer, with no
    /// version comparison and no path pin — so Sandfort could build bundles
    /// for, read firmware from, and drive a UTM the user did not think they
    /// were using, and the choice could differ between launches. Firmware is
    /// the sharp edge: a read-only volume can be ejected mid-baseline.
    ///
    /// Preference, not prohibition. Running UTM from an external disk is a
    /// legitimate setup, so a volume copy still wins when it is the only one.
    /// A trashed copy never does — the user has already said they do not want
    /// it, and emptying the Trash would pull it out from under a running VM.
    nonisolated static func resolveInstallation(
        identifierLookup: (String) -> [URL] = {
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0)
        },
        fallbackPaths: [String] = ["/Applications/UTM.app", NSHomeDirectory() + "/Applications/UTM.app"],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Installation? {
        let registered = identifierLookup(bundleIdentifier)
            .filter { fileExists($0.path) && !isDiscarded($0) }
        // Stable, so Launch Services' own preference still decides between two
        // copies that are equally reachable.
        let ranked = registered.enumerated().sorted {
            isOnMountedVolume($0.element) == isOnMountedVolume($1.element)
                ? $0.offset < $1.offset
                : !isOnMountedVolume($0.element)
        }.map(\.element)

        let located = ranked.first
            ?? fallbackPaths.first(where: fileExists).map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let located, fileExists(located.path) else { return nil }
        let info = NSDictionary(contentsOf: located.appendingPathComponent("Contents/Info.plist"))
        return Installation(
            applicationURL: located,
            version: info?["CFBundleShortVersionString"] as? String,
            alternatives: ranked.filter { $0 != located }
        )
    }

    /// A mounted volume can disappear while a baseline is being written.
    nonisolated private static func isOnMountedVolume(_ url: URL) -> Bool {
        url.path.hasPrefix("/Volumes/")
    }

    nonisolated private static func isDiscarded(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    nonisolated static var installation: Installation? { resolveInstallation() }

    nonisolated static var isInstalled: Bool { installation != nil }

    /// Why waiting for UTM to register a bundle stopped.
    enum RegistrationWait: Equatable {
        case registered(afterAttempts: Int)
        /// The user declined Automation permission, so UTM cannot be asked.
        case automationDenied
        case timedOut(afterAttempts: Int)
    }

    /// ~15 seconds, matching the poll `UTMRegistryController` already uses to
    /// wait for the opposite condition when removing a VM.
    nonisolated static let registrationPollAttempts = 60
    nonisolated static let registrationPollInterval = Duration.milliseconds(250)

    /// Waits until UTM's library contains `name`.
    ///
    /// Opening a bundle hands it to UTM, which then imports and registers it.
    /// `utm://start?name=` is silently dropped if it names a VM UTM has not
    /// registered yet, so starting has to wait for that to finish rather than
    /// guess at how long it takes.
    ///
    /// Injectable so the loop is testable without UTM installed, matching
    /// `resolveInstallation` above.
    nonisolated static func waitForRegistration(
        of name: String,
        attempts: Int = registrationPollAttempts,
        isRegistered: @Sendable (String) throws -> Bool,
        sleep: @Sendable (Duration) async -> Void
    ) async -> RegistrationWait {
        for attempt in 1...max(1, attempts) {
            do {
                if try isRegistered(name) { return .registered(afterAttempts: attempt) }
            } catch let error as NSError where UTMRegistryController.isAutomationDenied(error) {
                return .automationDenied
            } catch {
                // Any other Apple Event failure is treated as "not yet": UTM is
                // often mid-launch here, and a transient error must not stop the
                // VM from being started.
            }
            await sleep(registrationPollInterval)
        }
        return .timedOut(afterAttempts: max(1, attempts))
    }

    /// Opens a bundle in UTM, waits for UTM to register it, and starts it.
    ///
    /// Both steps are Apple Events, so both need Automation permission. That is
    /// not a design choice: the `utm://start?name=` URL does nothing — verified
    /// on UTM 4.7.5 by opening it against a registered, stopped VM, which stayed
    /// stopped, and UTM's URL handler has no `start` case in its source at 4.7.5
    /// or 5.0.4 — so its scripting interface is the only mechanism that
    /// actually starts a VM. Without the permission, Sandfort can add a VM to
    /// UTM but cannot start it, and says so rather than failing silently.
    ///
    /// See docs/utm-version-audit.md.
    static func openAndStart(
        bundle: URL,
        name: String,
        log: (@Sendable (String) -> Void)? = nil
    ) async {
        NSWorkspace.shared.open(bundle)
        let outcome = await waitForRegistration(
            of: name,
            isRegistered: { try UTMRegistryController.isVirtualMachineRegistered(named: $0) },
            sleep: { try? await Task.sleep(for: $0) }
        )
        switch outcome {
        case .registered:
            break
        case .automationDenied:
            log?("Sandfort does not have permission to control UTM, so it cannot start “\(name)”. "
                + "Press play in UTM to start it, or allow UTM under System Settings → Privacy & "
                + "Security → Automation.")
            return
        case .timedOut:
            log?("UTM did not report “\(name)” as ready in time. Trying to start it anyway.")
        }
        do {
            try UTMRegistryController.startVirtualMachine(named: name)
        } catch {
            log?("Sandfort could not start “\(name)” automatically: "
                + "\(error.localizedDescription) Press play in UTM to start it.")
        }
    }
}
