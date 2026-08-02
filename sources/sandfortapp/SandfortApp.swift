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

struct ContentView: View {
    @StateObject private var model = SandfortViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(model.runtime.displayName).font(.largeTitle.bold())
                    Text(model.runtime.subtitle)
                        .foregroundStyle(.secondary)
                    Text("Version \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    NSApplication.shared.showHelp(nil)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focusable(false)
                .help("Open Sandfort Help")
                .accessibilityLabel("Open Sandfort Help")
            }

            if let notice = model.runtime.qualificationNotice {
                GroupBox("\(model.guestProfile.distributionName) qualification") {
                    Text(notice)
                        .foregroundStyle(.orange)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Linux environments") {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.environments) { environment in
                        Button {
                            model.selectEnvironment(environment.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(environment.profile.displayName).font(.headline)
                                Text(environment.statusDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 155, alignment: .leading)
                            .padding(6)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.selectedEnvironmentID == environment.id ? .accentColor : .secondary)
                        .disabled(model.isRunning)
                    }
                    if model.stage == nil,
                       !model.environments.contains(where: { $0.id == model.selectedBaselineProfile.id }) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.selectedBaselineProfile.displayName).font(.headline)
                            Text("Not created").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 155, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Menu("Add Linux Environment…") {
                        ForEach(model.availableProfiles) { profile in
                            Button(profile.displayName) { model.beginAddEnvironment(profile) }
                        }
                    }
                    .disabled(model.availableProfiles.isEmpty || model.isRunning)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                if model.stage == nil {
                    Button(model.runtime.isQualification ? "Create \(model.guestProfile.distributionName) Qualification VM" : "Create \(model.selectedBaselineProfile.distributionName) Environment") {
                        model.create()
                    }
                        .buttonStyle(.borderedProminent)
                } else if model.stage == .provisioning {
                    Button("Finish Setup…") { model.showFinishConfirmation = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.baselineCompatibilityIssue != nil)
                    Button("Open Setup VM") { model.openSetup() }
                        .disabled(model.baselineCompatibilityIssue != nil)
                } else {
                    if model.instances.isEmpty {
                        Button("New Clean Sandbox…") { model.beginNewCleanSandbox() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.baselineCompatibilityIssue != nil)
                    } else {
                        Menu("Run Instance \(model.selectedInstanceNumber)") {
                            Button("Resume Instance") { model.resumeSelectedInstance() }
                            Button("Rename Instance…") { model.beginRenameSelectedInstance() }
                            Divider()
                            Button("Reset & Run Clean…") { model.requestResetAndRunClean() }
                                .disabled(model.baselineCompatibilityIssue != nil)
                            Divider()
                            Button("Delete Instance…", role: .destructive) {
                                model.showDeleteConfirmation = true
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button("New Clean Sandbox…") { model.beginNewCleanSandbox() }
                            .disabled(model.baselineCompatibilityIssue != nil)
                    }
                }
                Button("Check My Mac") { model.doctor() }
                if model.stage != nil {
                    Button("Rebuild \(model.guestProfile.distributionName)…") {
                        model.showRebuildConfirmation = true
                    }
                    Button("Delete Environment…", role: .destructive) {
                        model.showDeleteEnvironmentConfirmation = true
                    }
                }
                Spacer()
            }
            .disabled(model.isRunning)

            if let issue = model.baselineCompatibilityIssue {
                GroupBox("Baseline compatibility") {
                    Text(issue)
                        .foregroundStyle(.orange)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.stage == .ready {
                GroupBox("Sandbox instances") {
                    if model.instances.isEmpty {
                        Text("No clean instances exist. Create one from the protected baseline when you are ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 14) {
                            Picker("Selected instance", selection: $model.selectedInstanceNumber) {
                                ForEach(model.instances) { instance in
                                    Text(instance.displayTitle).tag(instance.number)
                                }
                            }
                            .frame(maxWidth: 310)
                            Text("Resume preserves its work. Reset & Run Clean restores only that instance from the protected baseline.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            GroupBox {
                DisclosureGroup(
                    "Development tools for the next baseline",
                    isExpanded: $model.baselineToolsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 20) {
                            Toggle("Python 3 + pip + venv", isOn: $model.tools.python)
                            Toggle("Latest Node.js LTS + npm", isOn: $model.tools.nodeJS)
                        }
                        Text("Git, curl, and jq are always included. Changing these options requires Rebuild.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle(isOn: Binding(
                            get: { model.tools.verboseSetupLogging ?? false },
                            set: { model.tools.verboseSetupLogging = $0 }
                        )) {
                            Text("Show detailed setup output")
                        }
                        Text("Displays detailed package-manager output in UTM. Leave off for concise progress messages.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("Advanced: run a custom setup script", isOn: $model.advancedMode)
                        Text("Applies only when creating the baseline. After changing this script, choose Rebuild to run it and create a new baseline; it does not modify the current baseline or existing instances.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.advancedMode {
                            TextEditor(text: Binding(
                                get: { model.tools.customSetupScript ?? Self.defaultSetupScript },
                                set: { model.tools.customSetupScript = $0 }
                            ))
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 150)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                            Text("Runs as root inside \(model.selectedBaselineProfile.displayName) while creating the trusted baseline. Review every command; never paste an untrusted challenge script here.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(model.isRunning || model.stage == .provisioning)

            if let credentials = model.credentials {
                GroupBox("\(model.guestProfile.distributionName) sign-in") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        GridRow { Text("Username").foregroundStyle(.secondary); Text(credentials.username).textSelection(.enabled) }
                        GridRow { Text("Password").foregroundStyle(.secondary); Text(credentials.password).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.statusLine).font(.headline)
                    Spacer()
                    if let fraction = model.progressFraction {
                        Text("\(Int((fraction * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button {
                        model.copyLogToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focusable(false)
                    .help("Copy activity log")
                    .accessibilityLabel("Copy activity log to clipboard")
                }
                if let fraction = model.progressFraction {
                    ProgressView(value: fraction, total: 1)
                } else if model.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            ScrollView {
                Text(model.output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Resume preserves a potentially contaminated session. Reset & Run Clean discards that instance's changes. Never start the Protected Baseline in UTM, and do not put personal accounts or secrets in a guest.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(
            minWidth: 760,
            minHeight: model.baselineToolsExpanded ? (model.advancedMode ? 860 : 680) : 600
        )
        .confirmationDialog("Has \(model.guestProfile.displayName) finished setup and been shut down?", isPresented: $model.showFinishConfirmation, titleVisibility: .visible) {
            Button("Protect Baseline and Create Instance 1") { model.finishSetup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do not shut \(model.guestProfile.distributionName) down manually. Wait until setup verifies every selected tool and the VM powers itself off automatically. Copying a running or incomplete VM creates a broken baseline.")
        }
        .confirmationDialog("Rebuild the \(model.guestProfile.displayName) environment?", isPresented: $model.showRebuildConfirmation, titleVisibility: .visible) {
            Button("Continue…", role: .destructive) { model.beginRebuildPasswordPrompt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes this environment's Protected Baseline, every numbered instance, and everything stored in them. Other Linux environments are not changed.\n\nOn the next screen, you will configure the password for the replacement \(model.guestProfile.displayName) baseline. Verified image downloads are retained for reuse.")
        }
        .sheet(isPresented: $model.showSafetyAcknowledgement) {
            SafetyAcknowledgementView(
                mode: .firstRun,
                onAccept: { model.acknowledgeSafety() },
                onQuit: { model.declineSafetyAcknowledgement() }
            )
        }
        .sheet(isPresented: $model.showRebuildPasswordPrompt) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Configure the new protected baseline")
                    .font(.title2.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The current password is prefilled. It will be set during baseline setup and shared by every instance created from it.")
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                HStack(spacing: 8) {
                    TextField("\(model.selectedBaselineProfile.distributionName) password", text: $model.rebuildPassword)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.regenerateRebuildPassword()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Generate a new memorable four-word password")
                    .accessibilityLabel("Generate new password")
                }

                Text("Use 8–128 visible characters without spaces or line breaks. The baseline and every instance must be stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Cancel") { model.showRebuildPasswordPrompt = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete and Rebuild", role: .destructive) {
                        let password = model.rebuildPassword
                        model.showRebuildPasswordPrompt = false
                        model.create(rebuild: true, password: password)
                    }
                }
            }
            .padding(24)
            .frame(minWidth: 520, idealWidth: 600, maxWidth: 720)
            .fixedSize(horizontal: false, vertical: true)
        }
        .alert(model.networkPromptTitle, isPresented: $model.showNetworkConfirmation) {
            Button("Continue Without Internet") { model.launchPendingSandbox(networkMode: .offline) }
                .keyboardShortcut(.defaultAction)
            Button("Continue With Internet") { model.launchPendingSandbox(networkMode: .internet) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No Internet is safest and is the default. Internet access lets untrusted software contact external systems and requires relaxing UTM's guest-to-host network isolation. Shared folders, clipboard, USB sharing, and incoming port forwarding remain disabled.")
        }
        .alert("Name the new sandbox instance", isPresented: $model.showNewInstanceNamePrompt) {
            TextField("Optional name", text: $model.newInstanceName)
            Button("Continue") { model.requestNewCleanSandbox(named: model.newInstanceName) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use a short name such as Interview Challenge or Suspicious npm Project. The permanent instance number will also remain visible.")
        }
        .alert("Rename Sandbox Instance \(model.selectedInstanceNumber)", isPresented: $model.showRenamePrompt) {
            TextField("Optional name", text: $model.renameInstanceName)
            Button("Save") { model.renameSelectedInstance() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renaming changes only the name shown in this app and UTM. It does not change the instance's disk or identity.")
        }
        .confirmationDialog("Delete \(model.selectedInstanceTitle)?", isPresented: $model.showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Instance", role: .destructive) { model.deleteSelectedInstance() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected instance must be stopped. It will be removed from UTM and Sandfort, and its independent disk and saved work will be moved to macOS Trash. The Protected Baseline and other instances will not be changed.")
        }
        .confirmationDialog("Delete the \(model.guestProfile.displayName) environment?", isPresented: $model.showDeleteEnvironmentConfirmation, titleVisibility: .visible) {
            Button("Delete Environment", role: .destructive) { model.deleteSelectedEnvironment() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes this environment's Protected Baseline and every numbered instance from UTM and Sandfort. Other Linux environments and verified image downloads are not changed.")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private static let defaultSetupScript = """
    #!/usr/bin/env bash
    set -euo pipefail

    # Install additional trusted tools with this guest's package manager.
    """
}

struct SandfortSettingsView: View {
    let runtime: SandfortRuntimeConfiguration

    var body: some View {
        TabView {
            SandfortStorageSettingsView(runtime: runtime)
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }

            SandfortDownloadSettingsView(runtime: runtime)
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

            SandfortSafetySettingsView(runtime: runtime)
                .tabItem {
                    Label("Safety", systemImage: "exclamationmark.shield")
                }
        }
        .frame(width: 760, height: 390)
    }
}

/// Lets someone re-read the safety notice without deleting a file, and shows
/// what they accepted. Presenting it here rather than reaching into the main
/// window's view model keeps the Settings scene self-contained.
private struct SandfortSafetySettingsView: View {
    let runtime: SandfortRuntimeConfiguration
    @State private var showNotice = false

    private var record: SafetyAcknowledgement.Record? {
        runtime.safetyAcknowledgementStore.load()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safety notice").font(.headline)
            Text(SafetyAcknowledgement.summary)
                .fixedSize(horizontal: false, vertical: true)

            if let record {
                Text("Acknowledged on \(record.acknowledgedAt.formatted(date: .long, time: .shortened))"
                     + (record.appVersion.map { " in version \($0)" } ?? "") + ".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not acknowledged yet. Sandfort asks before creating a sandbox.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Show Safety Notice Again") { showNotice = true }

            Text("Sandfort is provided with no warranty under the Apache License 2.0. "
                 + "The full terms are in the LICENSE file, and the reasoning behind "
                 + "these limits is in docs/security-model.md.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showNotice) {
            SafetyAcknowledgementView(
                mode: .review,
                acknowledgedAt: record?.acknowledgedAt,
                onClose: { showNotice = false }
            )
        }
    }
}

private struct SandfortStorageSettingsView: View {
    let runtime: SandfortRuntimeConfiguration
    @State private var statusMessage = ""

    var body: some View {
        Form {
            Section("Linux image cache") {
                LabeledContent("Location") {
                    Text(runtime.cacheURL.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Button("Reveal in Finder") { revealCache() }
                    Button("Copy Path") { copyCachePath() }
                    Spacer()
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Verified official Linux image downloads are shared by production environments. Rebuild and Delete Environment retain this cache so another environment can reuse an image without downloading it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .formStyle(.grouped)
        .padding(16)
    }

    private func revealCache() {
        do {
            try FileManager.default.createDirectory(
                at: runtime.cacheURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([runtime.cacheURL])
            statusMessage = "Opened in Finder"
        } catch {
            statusMessage = "Could not open the cache"
        }
    }

    private func copyCachePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(runtime.cacheURL.path, forType: .string)
        statusMessage = "Path copied"
    }
}

private struct SandfortDownloadSettingsView: View {
    let runtime: SandfortRuntimeConfiguration

    var body: some View {
        Form {
            Section("Environment downloads") {
                ForEach(runtime.selectableProfiles) { profile in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.displayName).font(.headline)
                        Text("Official image source")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(profile.image.url.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                Text("These Internet locations are read-only. Sandfort downloads only from its curated HTTPS profile URLs and verifies every image against the profile's pinned SHA-256 checksum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}


/// The safety disclosure, in one of two modes.
///
/// `firstRun` gates baseline creation: it cannot be dismissed except by
/// accepting or quitting, so the limits are not skipped past accidentally.
/// `review` is for re-reading it later from Settings, where demanding consent
/// again would be theater; it just closes.
struct SafetyAcknowledgementView: View {
    enum Mode { case firstRun, review }

    let mode: Mode
    var acknowledgedAt: Date? = nil
    var onAccept: () -> Void = {}
    var onQuit: () -> Void = {}
    var onClose: () -> Void = {}

    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(SafetyAcknowledgement.title).font(.title2.bold())
            Text(SafetyAcknowledgement.summary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(SafetyAcknowledgement.points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Text(SafetyAcknowledgement.licenseNotice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch mode {
            case .firstRun:
                Toggle(SafetyAcknowledgement.confirmationLabel, isOn: $confirmed)
                HStack {
                    Button("Quit") { onQuit() }
                    Spacer()
                    Button("Continue") { onAccept() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!confirmed)
                }
            case .review:
                HStack {
                    if let acknowledgedAt {
                        Text("You acknowledged this on \(acknowledgedAt.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { onClose() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(mode == .firstRun)
    }
}

@main
struct SandfortApp: App {
    /// Supplies the single-window quit behavior and the in-progress guard.
    @NSApplicationDelegateAdaptor(SandfortAppDelegate.self) private var appDelegate

    var body: some Scene {
        // `Window` rather than `WindowGroup`: Sandfort is a single-window
        // utility, and a second window would be a second view model racing the
        // first over the same baselines, instances, and UTM bundles. This also
        // removes the File > New Window command that WindowGroup adds.
        Window(SandfortRuntimeConfiguration.current.displayName, id: "sandfort-main") {
            ContentView()
        }
            .windowResizability(.contentSize)
            .commands {
                CommandGroup(replacing: .help) {
                    Button("Sandfort Help") {
                        NSApplication.shared.showHelp(nil)
                    }
                    .keyboardShortcut("?", modifiers: .command)
                }
            }
        Settings {
            SandfortSettingsView(runtime: .current)
        }
    }
}
