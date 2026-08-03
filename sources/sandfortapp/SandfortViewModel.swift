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
    @Published var output = "Ready. Create a sandbox once, then use a clean session for every untrusted project."
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
    @Published private(set) var hasAcknowledgedSafety = true

    private var pendingSandboxAction: PendingSandboxAction?

    let runtime: SandfortRuntimeConfiguration
    private let workflows: [String: SandfortWorkflow]

    init(runtime: SandfortRuntimeConfiguration = .current) {
        self.runtime = runtime
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
            output = "Could not save your acknowledgement: \(error.localizedDescription)"
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

    func beginRebuildPasswordPrompt() {
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
        pendingSandboxAction = .reset(instanceNumber: selectedInstanceNumber)
        showNetworkConfirmation = true
    }

    func resumeSelectedInstance() {
        let number = selectedInstanceNumber
        guard let selection = selectedSelection else { return }
        perform {
            try await selection.workflow.resumeInstance(instanceNumber: number)
            await self.update(
                status: "Resuming Sandbox Instance \(number)",
                message: "UTM is reopening Instance \(number) without restoring the baseline. Its previous files, processes, and network configuration remain in place."
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
            let networkDescription = networkMode == .offline
                ? "Network mode: offline. The guest cannot reach the Internet or your Mac."
                : "Network mode: Internet enabled for this run. Host sharing and incoming port forwarding remain disabled."
            switch action {
            case let .reset(number):
                try await selection.workflow.runClean(
                    instanceNumber: number,
                    networkMode: networkMode,
                    event: self.eventHandler
                )
                await self.update(
                    status: "Sandbox Instance \(number) started",
                    message: "UTM is opening Instance \(number), freshly restored from the protected baseline.\n\(networkDescription)"
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
                        message: "UTM is opening the new independent instance.\n\(networkDescription)"
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
        progressFraction = nil
        // Let the app delegate warn instead of discarding this silently if the
        // user closes the window or presses Command-Q mid-download.
        SandfortActivityMonitor.shared.begin()
        Task {
            do {
                try await operation()
            } catch {
                statusLine = "Stopped safely"
                output += "\n\(error.localizedDescription)\n"
                progressFraction = nil
            }
            SandfortActivityMonitor.shared.end()
            isRunning = false
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
        } else if state == nil {
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

    private func selectInstance(_ number: Int) {
        selectedInstanceNumber = number
    }

    private func append(_ message: String) {
        if !output.hasSuffix("\n") { output += "\n" }
        output += message + "\n"
    }
}
