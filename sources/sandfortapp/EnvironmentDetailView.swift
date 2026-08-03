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

/// The selected environment: what state it is in, the one action that makes
/// sense next, its instances, and its credentials.
///
/// The previous layout put every action in one row, so `Delete Environment…`
/// sat beside `Check My Mac`, and the instance being acted on was chosen in a
/// picker far from the menu that acted on it. Here the primary action is alone,
/// destructive actions are behind a menu, and each instance carries its own.
struct EnvironmentDetailView: View {
    @ObservedObject var model: SandfortViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let notice = model.runtime.qualificationNotice {
                CalloutBox(title: "\(model.guestProfile.distributionName) qualification", text: notice)
            }
            if let issue = model.baselineCompatibilityIssue {
                CalloutBox(title: "Baseline compatibility", text: issue)
            }

            if model.stage == .ready {
                instancesSection
            }
            if model.credentials != nil {
                credentialsSection
            }

            Spacer(minLength: 0)
            ActivityLogView(model: model)

            Text("Resume preserves a potentially contaminated session. Reset & Run Clean discards that instance's changes. Never start the Protected Baseline in UTM, and do not put personal accounts or secrets in a guest.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.title2.bold())
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            primaryActions
            Menu {
                Button("Development Tools…") { model.showBaselineTools = true }
                    .disabled(model.stage == .provisioning)
                if model.stage != nil {
                    Divider()
                    Button("Rebuild \(model.guestProfile.distributionName)…") {
                        model.showRebuildConfirmation = true
                    }
                    Button("Delete Environment…", role: .destructive) {
                        model.showDeleteEnvironmentConfirmation = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions for this environment")
            .accessibilityLabel("More actions")
        }
        .disabled(model.isRunning)
    }

    private var headerTitle: String {
        model.stage == nil ? model.selectedBaselineProfile.displayName : model.guestProfile.displayName
    }

    /// States what this environment is, so the user does not have to infer it
    /// from which buttons happen to be present.
    private var headerSubtitle: String {
        switch model.stage {
        case .none:
            return "Not created yet · \(model.selectedBaselineProfile.setupDurationDescription) to build"
        case .provisioning:
            return "Baseline setup in progress · do not shut the VM down yourself"
        case .ready:
            let count = model.instances.count
            let instances = count == 1 ? "1 instance" : "\(count) instances"
            return "Protected baseline · revision \(model.guestProfile.revision) · \(instances)"
        }
    }

    @ViewBuilder
    private var primaryActions: some View {
        switch model.stage {
        case .none:
            Button(model.runtime.isQualification
                   ? "Create \(model.guestProfile.distributionName) Qualification VM"
                   : "Create \(model.selectedBaselineProfile.distributionName) Environment") {
                model.create()
            }
            .buttonStyle(.borderedProminent)
        case .provisioning:
            Button("Open Setup VM") { model.openSetup() }
                .disabled(model.baselineCompatibilityIssue != nil)
            Button("Finish Setup…") { model.showFinishConfirmation = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.baselineCompatibilityIssue != nil)
        case .ready:
            Button("New Clean Sandbox…") { model.beginNewCleanSandbox() }
                .buttonStyle(.borderedProminent)
                .disabled(model.baselineCompatibilityIssue != nil)
        }
    }

    // MARK: - Instances

    private var instancesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sandbox instances").font(.headline)
            if model.instances.isEmpty {
                Text("No clean instances exist. Create one from the protected baseline when you are ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.instances.enumerated()), id: \.element.id) { index, instance in
                        if index > 0 { Divider() }
                        InstanceRow(model: model, instance: instance)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            }
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.guestProfile.distributionName) sign-in").font(.headline)
            if let credentials = model.credentials {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(credentials.username)
                        .textSelection(.enabled)
                    Text(model.revealGuestPassword ? credentials.password : String(repeating: "•", count: 14))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(model.revealGuestPassword ? credentials.password : "Password hidden")
                    Spacer()
                    Button {
                        model.revealGuestPassword.toggle()
                    } label: {
                        Image(systemName: model.revealGuestPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focusable(false)
                    .help(model.revealGuestPassword ? "Hide the guest password" : "Show the guest password")
                    .accessibilityLabel(model.revealGuestPassword ? "Hide password" : "Show password")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(credentials.password, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focusable(false)
                    .help("Copy the guest password")
                    .accessibilityLabel("Copy password")
                }
                .padding(9)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            }
        }
    }
}

/// One instance, carrying the actions that apply to it. Selection and action are
/// the same gesture, so a stale picker cannot send Reset to the wrong sandbox.
struct InstanceRow: View {
    @ObservedObject var model: SandfortViewModel
    let instance: SandboxInstance

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(instance.displayTitle)
            Spacer()
            Button("Resume") { model.resume(instance: instance.number) }
                .help("Reopen this instance with its files and processes intact")
            Button("Reset & Run Clean…") { model.resetAndRunClean(instance: instance.number) }
                .disabled(model.baselineCompatibilityIssue != nil)
                .help("Discard this instance's changes and restore it from the protected baseline")
            Menu {
                Button("Rename Instance…") { model.beginRename(instance: instance.number) }
                Divider()
                Button("Delete Instance…", role: .destructive) {
                    model.requestDelete(instance: instance.number)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions for \(instance.displayTitle)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .disabled(model.isRunning)
    }
}

/// A bordered notice used for the qualification banner and compatibility
/// warnings, which are both orange and both need to wrap.
struct CalloutBox: View {
    let title: String
    let text: String

    var body: some View {
        GroupBox(title) {
            Text(text)
                .foregroundStyle(.orange)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
