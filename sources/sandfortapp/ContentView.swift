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
