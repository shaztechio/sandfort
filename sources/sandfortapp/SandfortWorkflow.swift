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
        legacyProfiles: [LinuxGuestCatalog.ubuntu2404ARM64],
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
            legacyProfiles: profile.id == LinuxGuestCatalog.ubuntu2404ARM64.id
                ? [LinuxGuestCatalog.ubuntu2404ARM64]
                : [],
            rootURLOverride: rootURL,
            cacheURLOverride: cacheURL,
            preserveExistingDisplayNames: preserveExistingDisplayNames
        )
    }
}

actor SandfortWorkflow {
    typealias DeleteUTMRegistration = @Sendable (String) async throws -> Void

    private let downloader = NativeDownloader()
    private let fileManager = FileManager.default
    private let provider: any VirtualMachineProvider
    private let environment: SandfortWorkflowEnvironment
    private let deleteUTMRegistration: DeleteUTMRegistration

    init(
        environment: SandfortWorkflowEnvironment = .production,
        provider: (any VirtualMachineProvider)? = nil,
        deleteUTMRegistration: @escaping DeleteUTMRegistration = {
            try await UTMRegistryController.deleteVirtualMachine(named: $0)
        }
    ) {
        self.environment = environment
        self.provider = provider ?? UTMBundleBuilder()
        self.deleteUTMRegistration = deleteUTMRegistration
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
            try? provider.repairBundle(at: URL(fileURLWithPath: state.setupBundlePath), profile: profile)
            for instance in state.resolvedInstances {
                try? provider.repairBundle(at: URL(fileURLWithPath: instance.bundlePath), profile: profile)
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
        guard await UTMLauncher.isInstalled else { throw SandboxError.utmNotInstalled }
        let state = currentState()
        let architecture = SystemArchitecture.current
        let stateDescription = state.map {
            "Sandbox state: \($0.stage.rawValue), \($0.resolvedInstances.count) clean instance(s)."
        } ?? "No sandbox has been created yet."
        return "UTM is installed. This Mac is \(architecture). \(stateDescription)"
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
        // Validate user input before deleting an existing baseline during Rebuild.
        let requestedCredentials = try password.map { try profile.credentials(password: $0) }
        guard await UTMLauncher.isInstalled else { throw SandboxError.utmNotInstalled }
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
        await UTMLauncher.openAndStart(bundle: setupURL, name: setupName)
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
        try provider.repairBundle(at: setupURL, profile: profile)
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
        await UTMLauncher.openAndStart(bundle: cleanURL, name: cleanName)
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
        await UTMLauncher.openAndStart(bundle: destination, name: name)
        return state
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
        event(.phase("Opening Sandbox Instance \(instanceNumber) in UTM…"))
        await UTMLauncher.openAndStart(
            bundle: bundle,
            name: instance.vmName
        )
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
        await UTMLauncher.openAndStart(bundle: bundle, name: instance.vmName)
    }

    func openSetup() async throws {
        guard let state = currentState() else { throw SandboxError.sandboxNotCreated }
        guard state.stage == .provisioning else { throw SandboxError.setupNotComplete }
        let bundleURL = URL(fileURLWithPath: state.setupBundlePath)
        let profile = try guestProfile(for: state, requireExactMetadata: true)
        try provider.repairBundle(at: bundleURL, profile: profile)
        try profile.seedISO(credentials: state.credentials, tools: state.tools ?? .recommended).write(
            to: bundleURL.appendingPathComponent("Data/seed.iso"),
            options: .atomic
        )
        await UTMLauncher.openAndStart(bundle: bundleURL, name: state.setupVMName ?? "Sandfort — Baseline Setup")
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
    static var isInstalled: Bool {
        let locations = ["/Applications/UTM.app", NSHomeDirectory() + "/Applications/UTM.app"]
        return locations.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func openAndStart(bundle: URL, name: String) async {
        NSWorkspace.shared.open(bundle)
        try? await Task.sleep(for: .seconds(2))
        var components = URLComponents()
        components.scheme = "utm"
        components.host = "start"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

private enum SystemArchitecture {
    static var current: String {
        #if arch(arm64)
        return "Apple silicon (ARM64)"
        #else
        return "an unsupported architecture; this release requires Apple silicon"
        #endif
    }
}
