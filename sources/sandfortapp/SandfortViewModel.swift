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
import SwiftUI

struct SandfortRuntimeConfiguration: Sendable {
    let displayName: String
    let subtitle: String
    let qualificationNotice: String?
    let workflowEnvironment: SandfortWorkflowEnvironment
    let selectableProfiles: [LinuxGuestProfile]

    var defaultProfile: LinuxGuestProfile { workflowEnvironment.defaultProfile }
    var isQualification: Bool { qualificationNotice != nil }

    /// Shown in the sidebar footer. SECURITY.md and the bug-report template both
    /// ask reporters for this, so it is worth being readable without opening the
    /// About panel. Falls back to a placeholder under tests, where there is no
    /// app bundle to read.
    var appVersionDescription: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else {
            return "development build"
        }
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return "Version \(short)"
        }
        return "Version \(short) (\(build))"
    }

    /// Root of this app identity's own state. Qualification builds resolve to
    /// their isolated directory, so they never read production answers.
    var supportRootURL: URL {
        if isQualification {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            return support
                .appendingPathComponent(workflowEnvironment.supportDirectoryName, isDirectory: true)
        }
        return SandboxLibrary().rootURL
    }

    var cacheURL: URL {
        if isQualification {
            return supportRootURL.appendingPathComponent("Cache", isDirectory: true)
        }
        return SandboxLibrary().cacheURL
    }

    var safetyAcknowledgementStore: SafetyAcknowledgement.Store {
        SafetyAcknowledgement.Store(supportRootURL: supportRootURL)
    }

    static let production = SandfortRuntimeConfiguration(
        displayName: "Sandfort",
        subtitle: "Create clean, disposable virtual machines for untrusted work.",
        qualificationNotice: nil,
        workflowEnvironment: .production,
        selectableProfiles: LinuxGuestCatalog.profiles
    )

    static func configuration(qualificationProfileID: String?) -> SandfortRuntimeConfiguration {
        guard let qualificationProfileID,
              let profile = LinuxGuestCatalog.qualificationProfile(id: qualificationProfileID) else {
            return .production
        }
        return SandfortRuntimeConfiguration(
            displayName: "Sandfort — \(profile.distributionName) Qualification",
            subtitle: "Test \(profile.displayName) without changing production Sandfort.",
            qualificationNotice: "Isolated profile verification build: this uses separate app data and clearly labeled UTM VMs.",
            workflowEnvironment: .qualification(profile: profile),
            selectableProfiles: [profile]
        )
    }

    static var current: SandfortRuntimeConfiguration {
        configuration(
            qualificationProfileID: Bundle.main.object(
                forInfoDictionaryKey: "SandfortQualificationProfileID"
            ) as? String
        )
    }
}

private enum PendingSandboxAction: Sendable {
    case reset(instanceNumber: Int)
    case create(label: String?)
}

struct SandboxEnvironmentSummary: Identifiable, Sendable, Equatable {
    var id: String { profile.id }
    let profile: LinuxGuestProfile
    let stage: SandboxState.Stage
    let instanceCount: Int

    var statusDescription: String {
        switch stage {
        case .provisioning: return "Baseline setup in progress"
        case .ready:
            return "Protected baseline • \(instanceCount) instance\(instanceCount == 1 ? "" : "s")"
        }
    }
}

@MainActor
final class SandfortViewModel: ObservableObject {
    /// Stamped in `init` like every other entry. Assigning it inline would leave
    /// the one line in the log without a time on it.
    @Published var output = ""

    static let readyMessage =
        "Ready. Create a sandbox once, then use a clean session for every untrusted project."
    @Published var isRunning = false
    @Published var showRebuildConfirmation = false
    @Published var showFinishConfirmation = false
    @Published var showNetworkConfirmation = false
    @Published var showNewInstanceNamePrompt = false
    @Published var showRenamePrompt = false
    @Published var showDeleteConfirmation = false
    @Published var showDeleteEnvironmentConfirmation = false
    @Published var showRebuildPasswordPrompt = false
    @Published var progressFraction: Double?
    @Published var statusLine = "Ready"
    @Published var stage: SandboxState.Stage?
    @Published var credentials: SandboxCredentials?
    @Published var tools = SandboxToolSelection.recommended
    @Published var advancedMode = false
    @Published var baselineToolsExpanded = false
    @Published var instances: [SandboxInstance] = []
    @Published var selectedInstanceNumber = 1
    @Published var newInstanceName = ""
    @Published var renameInstanceName = ""
    @Published var rebuildPassword = ""
    @Published var selectedBaselineProfile: LinuxGuestProfile
    @Published private(set) var environments: [SandboxEnvironmentSummary] = []
    @Published var selectedEnvironmentID: String?
    @Published private(set) var guestProfile: LinuxGuestProfile
    @Published private(set) var baselineCompatibilityIssue: String?
    @Published var showSafetyAcknowledgement = false
    /// The guest password stays hidden until asked for. It is on screen in an
    /// app people demo and screenshot, and revealing it should be a decision.
    @Published var revealGuestPassword = false
    @Published var showBaselineTools = false
    @Published var showMaterials = false
    /// Why the last materials action failed, shown in the sheet.
    ///
    /// `perform` reports errors to the activity log, which the sheet covers — so
    /// a failed attach looked exactly like nothing happening at all.
    @Published var materialsError: String?
    /// Refreshed on launch, on Check My Mac, and after any operation, so
    /// installing UTM while Sandfort is open is noticed without a relaunch.
    @Published private(set) var utmIsMissing = false
    /// Whether UTM is running, which decides whether a newly attached materials
    /// disc can reach a resumed instance at all. Refreshed when the materials
    /// sheet opens and after every operation, so quitting UTM while Sandfort is
    /// open is noticed without a relaunch.
    @Published private(set) var utmIsRunning = false
    @Published private(set) var hasAcknowledgedSafety = true

    private var pendingSandboxAction: PendingSandboxAction?
    /// Start of the operation in progress, for the elapsed column.
    private var operationStartedAt: Date?

    let runtime: SandfortRuntimeConfiguration
    private let workflows: [String: SandfortWorkflow]

    init(runtime: SandfortRuntimeConfiguration = .current) {
        self.runtime = runtime
        output = Self.timestamped(Self.readyMessage, at: Date(), since: nil)
        utmIsMissing = !UTMLauncher.isInstalled
        utmIsRunning = UTMLauncher.isRunning
        let needsAcknowledgement = runtime.safetyAcknowledgementStore.needsAcknowledgement
        hasAcknowledgedSafety = !needsAcknowledgement
        showSafetyAcknowledgement = needsAcknowledgement
        guestProfile = runtime.defaultProfile
        selectedBaselineProfile = runtime.defaultProfile
        selectedEnvironmentID = runtime.defaultProfile.id
        if runtime.isQualification {
            workflows = [
                runtime.defaultProfile.id: SandfortWorkflow(environment: runtime.workflowEnvironment)
            ]
        } else {
            let library = SandboxLibrary()
            workflows = Dictionary(uniqueKeysWithValues: runtime.selectableProfiles.map { profile in
                let location = library.location(for: profile)
                let environment = SandfortWorkflowEnvironment.productionWorkspace(
                    profile: profile,
                    rootURL: location.rootURL,
                    cacheURL: library.cacheURL,
                    preserveExistingDisplayNames: location.usesLegacyRoot
                )
                return (profile.id, SandfortWorkflow(environment: environment))
            })
        }
        Task {
            await loadEnvironments()
        }
    }

    var availableProfiles: [LinuxGuestProfile] {
        runtime.selectableProfiles.filter { profile in
            !environments.contains(where: { $0.id == profile.id })
                && !(stage == nil && selectedEnvironmentID == profile.id)
        }
    }

    var selectedEnvironmentTitle: String {
        selectedBaselineProfile.displayName
    }

    func selectEnvironment(_ profileID: String) {
        guard let profile = runtime.selectableProfiles.first(where: { $0.id == profileID }),
              let workflow = workflows[profileID] else { return }
        selectedEnvironmentID = profileID
        Task {
            let state = await workflow.currentState()
            apply(state, profile: profile)
        }
    }

    func beginAddEnvironment(_ profile: LinuxGuestProfile) {
        guard !environments.contains(where: { $0.id == profile.id }) else {
            selectEnvironment(profile.id)
            return
        }
        selectedEnvironmentID = profile.id
        selectedBaselineProfile = profile
        tools = .recommended
        advancedMode = false
        baselineToolsExpanded = false
        apply(nil, profile: profile)
        statusLine = "Ready to create \(profile.displayName)"
    }

    /// Records the acknowledgement before anything can be created. A failure to
    /// write is surfaced rather than swallowed: silently forgetting would make
    /// the user answer again on every launch.
    /// Quits from the first-run disclosure.
    ///
    /// `NSApplication.terminate` is ignored while a sheet is still attached to
    /// the window, so the sheet is dismissed first and termination requested
    /// once the dismissal has been committed. Calling terminate directly from
    /// the sheet silently does nothing.
    func declineSafetyAcknowledgement(
        terminate: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        showSafetyAcknowledgement = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: terminate)
    }

    func acknowledgeSafety() {
        do {
            try runtime.safetyAcknowledgementStore.record(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
            hasAcknowledgedSafety = true
            showSafetyAcknowledgement = false
        } catch {
            // Appended, not assigned: this used to replace the whole log, losing
            // the history behind whatever had just gone wrong.
            append("Could not save your acknowledgement: \(error.localizedDescription)")
        }
    }

    func create(rebuild: Bool = false, password: String? = nil) {
        guard hasAcknowledgedSafety else {
            showSafetyAcknowledgement = true
            return
        }
        var pendingTools = tools
        if !advancedMode { pendingTools.customSetupScript = nil }
        let selectedTools = pendingTools
        let selectedProfile = selectedBaselineProfile
        guard let workflow = workflows[selectedProfile.id] else { return }
        perform {
            let state = try await workflow.create(
                rebuild: rebuild,
                profile: selectedProfile,
                tools: selectedTools,
                password: password,
                event: self.eventHandler
            )
            await self.apply(state, profile: selectedProfile)
            await self.refreshEnvironmentSummaries()
        }
    }

    /// Checked before the password sheet rather than after it. Rebuild reaches
    /// the baseline and every instance, and asking for a password only to refuse
    /// on the next screen wastes the one decision the user has already made.
    func beginRebuildPasswordPrompt() {
        afterShuttingDownIfNeeded(instanceNumber: nil) { [weak self] in
            self?.presentRebuildPasswordPrompt()
        }
    }

    private func presentRebuildPasswordPrompt() {
        selectedBaselineProfile = guestProfile
        rebuildPassword = credentials?.password ?? guestProfile.credentials().password
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            showRebuildPasswordPrompt = true
        }
    }

    func regenerateRebuildPassword() {
        rebuildPassword = selectedBaselineProfile.credentials().password
    }

    func finishSetup() {
        guard let selection = selectedSelection else { return }
        perform {
            let state = try await selection.workflow.finishSetup(event: self.eventHandler)
            await self.apply(state, profile: selection.profile)
            await self.refreshEnvironmentSummaries()
        }
    }

    // MARK: - Per-instance actions
    //
    // Instance rows act on the instance they belong to. The underlying workflow
    // still operates on `selectedInstanceNumber`, so each of these sets the
    // selection first. Doing it here rather than in the view is what keeps a
    // stale selection from acting on the wrong sandbox.

    func resume(instance number: Int) {
        selectedInstanceNumber = number
        resumeSelectedInstance()
    }

    func resetAndRunClean(instance number: Int) {
        selectedInstanceNumber = number
        requestResetAndRunClean()
    }

    func beginRename(instance number: Int) {
        selectedInstanceNumber = number
        beginRenameSelectedInstance()
    }

    func requestDelete(instance number: Int) {
        selectedInstanceNumber = number
        showDeleteConfirmation = true
    }

    func requestResetAndRunClean() {
        let number = selectedInstanceNumber
        afterShuttingDownIfNeeded(instanceNumber: number) { [weak self] in
            guard let self else { return }
            self.pendingSandboxAction = .reset(instanceNumber: number)
            self.showNetworkConfirmation = true
        }
    }

    func resumeSelectedInstance() {
        let number = selectedInstanceNumber
        guard let selection = selectedSelection else { return }
        perform {
            try await selection.workflow.resumeInstance(
                instanceNumber: number,
                event: self.eventHandler
            )
            await self.update(
                status: "Resuming Sandbox Instance \(number)",
                message: "UTM is reopening Instance \(number) without restoring the baseline. Its previous files, processes, and network configuration remain in place."
            )
        }
    }

    // MARK: - Materials

    /// The selected instance, for the materials sheet to describe.
    var selectedInstance: SandboxInstance? {
        instances.first { $0.number == selectedInstanceNumber }
    }

    /// Materials are per instance and take effect on its next launch, so the
    /// sheet is only meaningful when there is an instance to attach them to.
    var canChooseMaterials: Bool {
        stage == .ready && selectedInstance != nil && !isRunning
    }

    /// Opens a picker and attaches whatever is chosen to the selected instance.
    ///
    /// The panel accepts a file or a folder: a challenge arrives as either, and
    /// Opens the materials sheet with a fresh reading of whether UTM is running.
    ///
    /// Taken here rather than relying on the value left by the last operation:
    /// the whole point of the warning is that it is true at the moment someone
    /// decides how to launch, and UTM may have been quit or started since.
    func openMaterials() {
        utmIsRunning = UTMLauncher.isRunning
        materialsError = nil
        showMaterials = true
    }

    /// making the user compress a folder first would be friction for no gain
    /// since the packer does it with a system API.
    func chooseMaterialsForSelectedInstance() {
        let number = selectedInstanceNumber
        // Not a silent return. Every other action in this file can afford one
        // because the user sees the main window; this one runs behind a sheet,
        // where doing nothing is indistinguishable from failing.
        guard let selection = selectedSelection else {
            materialsError = "No environment is selected, so there is nothing to attach materials to."
            return
        }
        guard instances.contains(where: { $0.number == number }) else {
            materialsError = "Instance \(number) is no longer listed. Close this sheet and select an instance."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = "Send In"
        panel.message = "Choose a file or folder to send into Sandbox Instance \(number). "
            + "It is copied into a read-only disc image; the guest cannot change it or reach the original."
        // This is the app's first file picker. Sandfort is not App Sandboxed, so
        // no security-scoped bookmark is needed; adopting App Sandbox later, per
        // docs/APP-STORE.md, would require
        // com.apple.security.files.user-selected.read-only.
        guard panel.runModal() == .OK, let source = panel.url else { return }  // cancelled
        materialsError = nil
        perform {
            let state: SandboxState
            do {
                state = try await selection.workflow.attachMaterials(
                    toInstance: number,
                    from: source,
                    event: self.eventHandler
                )
            } catch {
                // Surfaced where the user is looking, then rethrown so the
                // activity log and status line behave as they do everywhere else.
                await self.showMaterialsError(error)
                throw error
            }
            await self.apply(state, profile: selection.profile)
            await self.update(
                status: "Materials ready for Instance \(number)",
                message: "\(source.lastPathComponent) is attached to Instance \(number) as a read-only disc image. "
                    + "Launch or reset that instance to see it."
            )
        }
    }

    private func showMaterialsError(_ error: Error) {
        materialsError = error.localizedDescription
    }

    func removeMaterialsFromSelectedInstance() {
        let number = selectedInstanceNumber
        guard let selection = selectedSelection else {
            materialsError = "No environment is selected."
            return
        }
        materialsError = nil
        perform {
            let state: SandboxState
            do {
                state = try await selection.workflow.removeMaterials(fromInstance: number)
            } catch {
                await self.showMaterialsError(error)
                throw error
            }
            await self.apply(state, profile: selection.profile)
            await self.update(
                status: "Materials removed from Instance \(number)",
                message: "The disc image was detached and deleted. Instance \(number) no longer has access to it."
            )
        }
    }

    // MARK: - Running virtual machines block destructive work
    //
    // Reset, Delete Instance, Rebuild, and Delete Environment all refuse while a
    // VM holds its disk. Each one used to fail with "Shut down the virtual
    // machine in UTM", sending the user to another app to do something Sandfort
    // can do itself.
    //
    // The shutdown is offered, never automatic. Rebuild and Delete Environment
    // reach every instance in the environment, including ones the user is not
    // looking at, and powering those down as a side effect of a different action
    // is exactly the kind of surprise this app avoids elsewhere.

    /// Names of the running VMs the pending operation would touch.
    @Published private(set) var blockingVirtualMachines: [String] = []
    @Published var showShutDownPrompt = false
    private var pendingBlockedScope: Int??
    private var pendingBlockedAction: (@MainActor () -> Void)?

    var blockingVirtualMachineList: String {
        blockingVirtualMachines.joined(separator: "\n")
    }

    /// Runs `action`, first offering to shut down anything in scope that is
    /// still running. `instanceNumber` nil means the whole environment.
    private func afterShuttingDownIfNeeded(
        instanceNumber: Int?,
        action: @escaping @MainActor () -> Void
    ) {
        guard let selection = selectedSelection else { return }
        Task { @MainActor in
            let running = await selection.workflow.runningVirtualMachines(instanceNumber: instanceNumber)
            guard !running.isEmpty else {
                action()
                return
            }
            self.blockingVirtualMachines = running
            self.pendingBlockedScope = .some(instanceNumber)
            self.pendingBlockedAction = action
            self.showShutDownPrompt = true
        }
    }

    func shutDownBlockingVirtualMachinesAndContinue() {
        guard let scope = pendingBlockedScope, let action = pendingBlockedAction else { return }
        guard let selection = selectedSelection else { return }
        pendingBlockedScope = nil
        pendingBlockedAction = nil
        perform {
            try await selection.workflow.shutDownRunningVirtualMachines(
                instanceNumber: scope,
                event: self.eventHandler
            )
            await MainActor.run { action() }
        }
    }

    func cancelShutDownPrompt() {
        pendingBlockedScope = nil
        pendingBlockedAction = nil
        blockingVirtualMachines = []
    }

    func stop(instance number: Int) {
        selectedInstanceNumber = number
        stopSelectedInstance()
    }

    func stopSelectedInstance() {
        let number = selectedInstanceNumber
        guard let selection = selectedSelection else { return }
        perform {
            try await selection.workflow.stopInstance(
                instanceNumber: number,
                event: self.eventHandler
            )
            await self.update(
                status: "Sandbox Instance \(number) stopped",
                message: "Instance \(number) shut down and its UTM window closed. Its disk is unchanged; Resume reopens it as it was."
            )
        }
    }

    func beginNewCleanSandbox() {
        newInstanceName = ""
        showNewInstanceNamePrompt = true
    }

    func requestNewCleanSandbox(named label: String) {
        do {
            pendingSandboxAction = .create(label: try SandboxInstance.normalizedLabel(label))
        } catch {
            statusLine = "Name not accepted"
            append(error.localizedDescription)
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            showNetworkConfirmation = true
        }
    }

    func beginRenameSelectedInstance() {
        renameInstanceName = instances.first(where: { $0.number == selectedInstanceNumber })?.label ?? ""
        showRenamePrompt = true
    }

    func renameSelectedInstance() {
        let number = selectedInstanceNumber
        let label = renameInstanceName
        guard let selection = selectedSelection else { return }
        perform {
            let state = try await selection.workflow.renameInstance(number: number, label: label)
            await self.apply(state, profile: selection.profile)
            let title = state.resolvedInstances.first(where: { $0.number == number })?.displayTitle
                ?? "Sandbox Instance \(number)"
            await self.update(
                status: "Instance renamed",
                message: "UTM will display this VM as \(title). Its disk, UUID, and bundle path were not changed."
            )
        }
    }

    var selectedInstanceTitle: String {
        instances.first(where: { $0.number == selectedInstanceNumber })?.displayTitle
            ?? "Sandbox Instance \(selectedInstanceNumber)"
    }

    func deleteSelectedInstance() {
        afterShuttingDownIfNeeded(instanceNumber: selectedInstanceNumber) { [weak self] in
            self?.performDeleteSelectedInstance()
        }
    }

    private func performDeleteSelectedInstance() {
        let number = selectedInstanceNumber
        let title = selectedInstanceTitle
        guard let selection = selectedSelection else { return }
        perform {
            let state = try await selection.workflow.deleteInstance(number: number, event: self.eventHandler)
            await self.apply(state, profile: selection.profile)
            await self.refreshEnvironmentSummaries()
            await self.update(
                status: "\(title) deleted",
                message: "The instance was removed from UTM and Sandfort, and its bundle was moved to macOS Trash."
            )
        }
    }

    func deleteSelectedEnvironment() {
        afterShuttingDownIfNeeded(instanceNumber: nil) { [weak self] in
            self?.performDeleteSelectedEnvironment()
        }
    }

    private func performDeleteSelectedEnvironment() {
        guard let selection = selectedSelection else { return }
        let title = selection.profile.displayName
        perform {
            try await selection.workflow.deleteEnvironment(event: self.eventHandler)
            await self.refreshEnvironmentSummaries()
            await self.selectFallbackEnvironment()
            await self.update(
                status: "\(title) environment deleted",
                message: "Its baseline and instances were removed. Other Linux environments and verified image downloads were not changed."
            )
        }
    }

    var networkPromptTitle: String {
        switch pendingSandboxAction {
        case let .reset(number):
            return "Reset Sandbox Instance \(number) and choose its network?"
        case .create:
            return "Connect the new sandbox instance to the Internet?"
        case nil:
            return "Should this sandbox connect to the Internet?"
        }
    }

    func launchPendingSandbox(networkMode: SandboxNetworkMode) {
        guard let action = pendingSandboxAction else { return }
        guard let selection = selectedSelection else { return }
        pendingSandboxAction = nil
        perform {
            // Logged here rather than appended to the completion message: the
            // network mode is chosen before the run starts, so this is when it
            // happened, and it earns its own timestamp.
            await self.log(networkMode == .offline
                ? "Network mode: offline. The guest cannot reach the Internet or your Mac."
                : "Network mode: Internet enabled for this run. Host sharing and incoming port forwarding remain disabled.")
            switch action {
            case let .reset(number):
                try await selection.workflow.runClean(
                    instanceNumber: number,
                    networkMode: networkMode,
                    event: self.eventHandler
                )
                await self.update(
                    status: "Sandbox Instance \(number) started",
                    message: "UTM is opening Instance \(number), freshly restored from the protected baseline."
                )
            case let .create(label):
                let state = try await selection.workflow.createCleanInstance(
                    networkMode: networkMode,
                    label: label,
                    event: self.eventHandler
                )
                await self.apply(state, profile: selection.profile)
                await self.refreshEnvironmentSummaries()
                if let newest = state.resolvedInstances.last {
                    await self.selectInstance(newest.number)
                    await self.update(
                        status: "Sandbox Instance \(newest.number) created",
                        message: "UTM is opening the new independent instance."
                    )
                }
            }
        }
    }

    func openSetup() {
        guard let selection = selectedSelection else { return }
        let profile = selection.profile
        perform {
            try await selection.workflow.openSetup()
            await self.update(
                status: "Opening \(profile.distributionName) setup",
                message: "The repaired \(profile.displayName) setup VM is opening in UTM."
            )
        }
    }

    func doctor() {
        guard let selection = selectedSelection else { return }
        perform {
            let result = try await selection.workflow.doctor()
            await self.update(status: "Check complete", message: result)
        }
    }

    /// Opens UTM's download page. `NSWorkspace` is a native API, so this adds no
    /// runtime shell dependency.
    func openUTMDownloadPage() {
        NSWorkspace.shared.open(UTMLauncher.downloadPage)
    }

    func copyLogToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
        statusLine = "Log copied to clipboard"
    }

    private var eventHandler: @Sendable (WorkflowEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func perform(_ operation: @escaping @Sendable () async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true
        operationStartedAt = Date()
        progressFraction = nil
        // Let the app delegate warn instead of discarding this silently if the
        // user closes the window or presses Command-Q mid-download.
        SandfortActivityMonitor.shared.begin()
        Task {
            do {
                try await operation()
            } catch {
                statusLine = "Stopped safely"
                append(error.localizedDescription)
                progressFraction = nil
            }
            SandfortActivityMonitor.shared.end()
            utmIsMissing = !UTMLauncher.isInstalled
            utmIsRunning = UTMLauncher.isRunning
            isRunning = false
            operationStartedAt = nil
        }
    }

    private func handle(_ event: WorkflowEvent) {
        switch event {
        case let .phase(message):
            statusLine = message
            progressFraction = nil
            append(message)
        case let .progress(completed, total):
            guard total > 0 else { return }
            progressFraction = min(1, max(0, Double(completed) / Double(total)))
            statusLine = "Downloading \(selectedBaselineProfile.distributionName)…"
        case let .log(message):
            append(message)
        }
    }

    private var selectedSelection: (profile: LinuxGuestProfile, workflow: SandfortWorkflow)? {
        guard let selectedEnvironmentID,
              let profile = runtime.selectableProfiles.first(where: { $0.id == selectedEnvironmentID }),
              let workflow = workflows[selectedEnvironmentID] else { return nil }
        return (profile, workflow)
    }

    private func loadEnvironments() async {
        var loaded: [(LinuxGuestProfile, SandboxState)] = []
        for profile in runtime.selectableProfiles {
            guard let workflow = workflows[profile.id],
                  let state = await workflow.currentState() else { continue }
            loaded.append((profile, state))
        }
        environments = loaded.map {
            SandboxEnvironmentSummary(
                profile: $0.0,
                stage: $0.1.stage,
                instanceCount: $0.1.resolvedInstances.count
            )
        }
        let selection = loaded.first(where: { $0.0.id == selectedEnvironmentID })
            ?? loaded.first
        if let selection {
            selectedEnvironmentID = selection.0.id
            apply(selection.1, profile: selection.0)
        } else {
            let profile = runtime.defaultProfile
            selectedEnvironmentID = profile.id
            apply(nil, profile: profile)
        }
    }

    private func refreshEnvironmentSummaries() async {
        var summaries: [SandboxEnvironmentSummary] = []
        for profile in runtime.selectableProfiles {
            guard let workflow = workflows[profile.id],
                  let state = await workflow.currentState() else { continue }
            summaries.append(SandboxEnvironmentSummary(
                profile: profile,
                stage: state.stage,
                instanceCount: state.resolvedInstances.count
            ))
        }
        environments = summaries
    }

    private func selectFallbackEnvironment() {
        let nextProfile = environments.first?.profile
            ?? availableProfiles.first
            ?? runtime.defaultProfile
        beginAddEnvironment(nextProfile)
    }

    /// Test seam for `apply`, which is private and is where the header's
    /// identity is decided.
    func applyForTesting(_ state: SandboxState?, profile: LinuxGuestProfile) {
        apply(state, profile: profile)
    }

    private func apply(_ state: SandboxState?, profile fallbackProfile: LinuxGuestProfile) {
        if let state,
           let profile = try? SandfortWorkflow.resolveGuestProfile(
               for: state,
               environment: SandfortWorkflowEnvironment.productionWorkspace(
                   profile: fallbackProfile,
                   rootURL: URL(fileURLWithPath: "/"),
                   cacheURL: URL(fileURLWithPath: "/")
               )
           ) {
            guestProfile = profile
            selectedBaselineProfile = profile
        } else {
            // Also when a state exists that this build cannot resolve — a
            // baseline whose revision is no longer supported. That used to
            // assign nothing, so the header kept the *previously selected*
            // environment's name: openSUSE selected, Fedora on screen. The
            // moment a user most needs to know which environment they are
            // looking at is exactly when its baseline is out of date.
            //
            // The selection is always the right answer here, because the user
            // just made it.
            guestProfile = fallbackProfile
            selectedBaselineProfile = fallbackProfile
        }
        stage = state?.stage
        credentials = state?.credentials
        instances = state?.resolvedInstances ?? []
        if !instances.contains(where: { $0.number == selectedInstanceNumber }) {
            selectedInstanceNumber = instances.first?.number ?? 1
        }
        if let selectedTools = state?.tools {
            tools = selectedTools
            advancedMode = selectedTools.customSetupScript?.isEmpty == false
            if advancedMode { baselineToolsExpanded = true }
        }
        if let state {
            do {
                _ = try SandfortWorkflow.resolveGuestProfile(
                    for: state,
                    environment: SandfortWorkflowEnvironment.productionWorkspace(
                        profile: fallbackProfile,
                        rootURL: URL(fileURLWithPath: "/"),
                        cacheURL: URL(fileURLWithPath: "/")
                    ),
                    requireExactMetadata: state.stage == .provisioning
                )
                baselineCompatibilityIssue = nil
                statusLine = state.stage == .ready
                    ? "Sandbox is ready"
                    : "\(guestProfile.distributionName) setup is in progress"
            } catch {
                baselineCompatibilityIssue = error.localizedDescription
                statusLine = "Baseline needs Rebuild"
            }
        } else {
            baselineCompatibilityIssue = nil
        }
    }

    private func update(status: String, message: String) {
        statusLine = status
        append(message)
    }

    /// Logs a standalone event, so it gets its own clock reading.
    ///
    /// Continuation lines of a multi-line message are deliberately indented and
    /// left unstamped, because they arrived at the same moment as their first
    /// line. A genuinely separate fact must not be smuggled in as one of those:
    /// it reads as an event with no time on it.
    private func log(_ message: String) {
        append(message)
    }

    private func selectInstance(_ number: Int) {
        selectedInstanceNumber = number
    }

    private func append(_ message: String) {
        if !output.hasSuffix("\n") { output += "\n" }
        output += Self.timestamped(message, at: Date(), since: operationStartedAt) + "\n"
    }

    /// Fixed 24-hour clock regardless of locale. A 12-hour locale would append
    /// AM/PM and break the column alignment the log depends on.
    private static let logClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Prefixes a log message with the wall-clock time and, during an operation,
    /// the time elapsed since it started.
    ///
    /// The clock is what correlates this log with `/var/log/sandfort-setup.log`
    /// inside the guest; the elapsed column is what makes a slow step visible,
    /// which is how a two-minute boot wait hid in plain sight.
    ///
    /// Only the first line is stamped. Messages can be several lines, and
    /// stamping each would claim they arrived at different moments; the rest are
    /// indented to keep the time column honest.
    static func timestamped(_ message: String, at now: Date, since start: Date?) -> String {
        let clock = logClock.string(from: now)
        let elapsed = start.map { start -> String in
            let seconds = max(0, Int(now.timeIntervalSince(start).rounded()))
            return String(format: "+%d:%02d", seconds / 60, seconds % 60)
        } ?? ""
        let column = String(repeating: " ", count: max(0, 6 - elapsed.count)) + elapsed
        let prefix = "\(clock) \(column)  "
        let indent = String(repeating: " ", count: prefix.count)
        let lines = message.components(separatedBy: "\n")
        return lines.enumerated()
            .map { index, line in index == 0 ? prefix + line : indent + line }
            .joined(separator: "\n")
    }
}
