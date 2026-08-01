import AppKit
import SwiftUI

private enum PendingSandboxAction: Sendable {
    case reset(instanceNumber: Int)
    case create(label: String?)
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

    private var pendingSandboxAction: PendingSandboxAction?

    private let workflow = SandfortWorkflow()

    init() {
        Task {
            let state = await workflow.currentState()
            apply(state)
        }
    }

    func create(rebuild: Bool = false, password: String? = nil) {
        var pendingTools = tools
        if !advancedMode { pendingTools.customSetupScript = nil }
        let selectedTools = pendingTools
        perform {
            let state = try await self.workflow.create(
                rebuild: rebuild,
                tools: selectedTools,
                password: password,
                event: self.eventHandler
            )
            await self.apply(state)
        }
    }

    func beginRebuildPasswordPrompt() {
        rebuildPassword = credentials?.password ?? CloudInit.credentials().password
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            showRebuildPasswordPrompt = true
        }
    }

    func regenerateRebuildPassword() {
        rebuildPassword = CloudInit.credentials().password
    }

    func finishSetup() {
        perform {
            let state = try await self.workflow.finishSetup(event: self.eventHandler)
            await self.apply(state)
        }
    }

    func requestResetAndRunClean() {
        pendingSandboxAction = .reset(instanceNumber: selectedInstanceNumber)
        showNetworkConfirmation = true
    }

    func resumeSelectedInstance() {
        let number = selectedInstanceNumber
        perform {
            try await self.workflow.resumeInstance(instanceNumber: number)
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
        perform {
            let state = try await self.workflow.renameInstance(number: number, label: label)
            await self.apply(state)
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
        perform {
            let state = try await self.workflow.deleteInstance(number: number)
            await self.apply(state)
            await self.update(
                status: "\(title) deleted",
                message: "The instance bundle was moved to Trash and removed from Sandfort. If UTM still shows an unavailable entry, select that entry in UTM and use its trash button to remove the stale registration."
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
        pendingSandboxAction = nil
        perform {
            let networkDescription = networkMode == .offline
                ? "Network mode: offline. The guest cannot reach the Internet or your Mac."
                : "Network mode: Internet enabled for this run. Host sharing and incoming port forwarding remain disabled."
            switch action {
            case let .reset(number):
                try await self.workflow.runClean(
                    instanceNumber: number,
                    networkMode: networkMode,
                    event: self.eventHandler
                )
                await self.update(
                    status: "Sandbox Instance \(number) started",
                    message: "UTM is opening Instance \(number), freshly restored from the protected baseline.\n\(networkDescription)"
                )
            case let .create(label):
                let state = try await self.workflow.createCleanInstance(
                    networkMode: networkMode,
                    label: label,
                    event: self.eventHandler
                )
                await self.apply(state)
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
        perform {
            try await self.workflow.openSetup()
            await self.update(status: "Opening Ubuntu setup", message: "The repaired setup VM is opening in UTM.")
        }
    }

    func doctor() {
        perform {
            let result = try await self.workflow.doctor()
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
        Task {
            do {
                try await operation()
            } catch {
                statusLine = "Stopped safely"
                output += "\n\(error.localizedDescription)\n"
                progressFraction = nil
            }
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
            statusLine = "Downloading Ubuntu…"
        case let .log(message):
            append(message)
        }
    }

    private func apply(_ state: SandboxState?) {
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
            statusLine = state.stage == .ready ? "Sandbox is ready" : "Ubuntu setup is in progress"
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
                    Text("Sandfort").font(.largeTitle.bold())
                    Text("Open suspicious coding challenges away from your Mac.")
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

            HStack(spacing: 12) {
                if model.stage == nil {
                    Button("Create Sandbox") { model.create() }
                        .buttonStyle(.borderedProminent)
                } else if model.stage == .provisioning {
                    Button("Finish Setup…") { model.showFinishConfirmation = true }
                        .buttonStyle(.borderedProminent)
                    Button("Open Setup VM") { model.openSetup() }
                } else {
                    if model.instances.isEmpty {
                        Button("New Clean Sandbox…") { model.beginNewCleanSandbox() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Menu("Run Instance \(model.selectedInstanceNumber)") {
                            Button("Resume Instance") { model.resumeSelectedInstance() }
                            Button("Rename Instance…") { model.beginRenameSelectedInstance() }
                            Divider()
                            Button("Reset & Run Clean…") { model.requestResetAndRunClean() }
                            Divider()
                            Button("Delete Instance…", role: .destructive) {
                                model.showDeleteConfirmation = true
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button("New Clean Sandbox…") { model.beginNewCleanSandbox() }
                    }
                }
                Button("Check My Mac") { model.doctor() }
                Button("Rebuild…") { model.showRebuildConfirmation = true }
                Spacer()
            }
            .disabled(model.isRunning)

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
                        Text("Displays all APT output in UTM. Leave off for concise progress messages.")
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
                            Text("Runs as root inside Ubuntu while creating the trusted baseline. Review every command; never paste an untrusted challenge script here.")
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
                GroupBox("Ubuntu sign-in") {
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
        .confirmationDialog("Has Ubuntu finished setup and been shut down?", isPresented: $model.showFinishConfirmation, titleVisibility: .visible) {
            Button("Protect Baseline and Create Instance 1") { model.finishSetup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do not shut Ubuntu down manually. Wait until setup verifies every selected tool and the VM powers itself off automatically. Copying a running or incomplete VM creates a broken baseline.")
        }
        .confirmationDialog("Delete the baseline and all sandbox instances?", isPresented: $model.showRebuildConfirmation, titleVisibility: .visible) {
            Button("Continue…", role: .destructive) { model.beginRebuildPasswordPrompt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the app-owned Protected Baseline, every numbered instance, and everything stored in them. The verified Ubuntu download is retained.")
        }
        .sheet(isPresented: $model.showRebuildPasswordPrompt) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Set the Ubuntu password for the new baseline")
                    .font(.title2.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The current password is prefilled. It will be set during baseline setup and shared by every instance created from it.")
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                HStack(spacing: 8) {
                    TextField("Ubuntu password", text: $model.rebuildPassword)
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
            Button("Move Instance to Trash", role: .destructive) { model.deleteSelectedInstance() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected instance must be stopped. Its independent disk and saved work will be moved to macOS Trash. The Protected Baseline and other instances will not be changed.")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private static let defaultSetupScript = """
    #!/usr/bin/env bash
    set -euo pipefail

    # Example:
    # apt-get install -y ripgrep
    """
}

@main
struct SandfortApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
            .commands {
                CommandGroup(replacing: .help) {
                    Button("Sandfort Help") {
                        NSApplication.shared.showHelp(nil)
                    }
                    .keyboardShortcut("?", modifiers: .command)
                }
            }
    }
}
