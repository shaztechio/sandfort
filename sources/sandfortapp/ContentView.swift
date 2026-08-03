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

/// The main window: environments on the left, the selected environment on the
/// right. This view is now only the shell, its sheets, and its dialogs; the
/// panes themselves live in EnvironmentSidebar and EnvironmentDetailView.
struct ContentView: View {
    @StateObject private var model = SandfortViewModel()

    var body: some View {
        NavigationSplitView {
            EnvironmentSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            EnvironmentDetailView(model: model)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItem {
                Button("Check My Mac") { model.doctor() }
                    .disabled(model.isRunning)
            }
            ToolbarItem {
                Button {
                    NSApplication.shared.showHelp(nil)
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Open Sandfort Help")
                .accessibilityLabel("Open Sandfort Help")
            }
        }
        .sheet(isPresented: $model.showSafetyAcknowledgement) {
            SafetyAcknowledgementView(
                mode: .firstRun,
                onAccept: { model.acknowledgeSafety() },
                onQuit: { model.declineSafetyAcknowledgement() }
            )
        }
        .sheet(isPresented: $model.showBaselineTools) {
            BaselineToolsSheet(model: model) { model.showBaselineTools = false }
        }
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
}
