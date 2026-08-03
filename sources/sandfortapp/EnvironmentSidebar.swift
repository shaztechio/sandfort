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

/// Lists the Linux environments and lets one be selected.
///
/// Environments were previously a row of fixed-width buttons that showed
/// selection by tint, which is not a macOS selection idiom and ran out of room
/// as profiles were added. A `List` selection scales and behaves the way the
/// rest of the system does.
struct EnvironmentSidebar: View {
    @ObservedObject var model: SandfortViewModel

    var body: some View {
        List(selection: sidebarSelection) {
            Section("Environments") {
                ForEach(model.environments) { environment in
                    EnvironmentSidebarRow(
                        title: environment.profile.displayName,
                        detail: environment.statusDescription,
                        state: environment.stage == .ready ? .ready : .working
                    )
                    .tag(environment.id)
                }

                // The profile chosen for a baseline that does not exist yet, so
                // the sidebar shows where it will appear rather than nothing.
                if model.stage == nil,
                   !model.environments.contains(where: { $0.id == model.selectedBaselineProfile.id }) {
                    EnvironmentSidebarRow(
                        title: model.selectedBaselineProfile.displayName,
                        detail: "Not created",
                        state: .absent
                    )
                    .tag(model.selectedBaselineProfile.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.availableProfiles.isEmpty {
                    Menu("Add Linux Environment…") {
                        ForEach(model.availableProfiles) { profile in
                            Button(profile.displayName) { model.beginAddEnvironment(profile) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(model.isRunning)
                }
                Divider()
                // The icon is the only colour in an otherwise grey window, and
                // the version is what bug reports ask for.
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(model.runtime.appVersionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Routes `List` selection through the model's own selection method, which
    /// resolves the environment's workflow. Selection is ignored while an
    /// operation is running, matching the previous behavior.
    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { model.selectedEnvironmentID ?? model.selectedBaselineProfile.id },
            set: { newValue in
                guard let newValue, !model.isRunning else { return }
                model.selectEnvironment(newValue)
            }
        )
    }
}

private struct EnvironmentSidebarRow: View {
    enum State {
        case ready, working, absent
    }

    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var indicatorColor: Color {
        switch state {
        case .ready: return .green
        case .working: return .orange
        case .absent: return .secondary.opacity(0.4)
        }
    }
}
