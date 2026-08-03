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

/// Configuration for the next baseline: development tools, setup output, and
/// the custom setup script.
///
/// This was a disclosure group in the main window, permanently present and
/// resizing the window when opened, even though it only applies when a baseline
/// is built. It is a sheet now, reached from the environment's actions menu.
/// The settings themselves are unchanged and still take effect on the next
/// create or rebuild.
struct BaselineToolsSheet: View {
    @ObservedObject var model: SandfortViewModel
    let onClose: () -> Void

    static let defaultSetupScript = """
    #!/usr/bin/env bash
    set -euo pipefail

    # Install additional trusted tools with this guest's package manager.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Development tools for the next baseline")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("These apply when a baseline is created or rebuilt. They do not change the current baseline or any existing instance.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Python 3 + pip + venv", isOn: $model.tools.python)
            Toggle("Latest Node.js LTS + npm", isOn: $model.tools.nodeJS)
            Toggle("Visual Studio Code", isOn: Binding(
                get: { model.tools.installsVSCode },
                set: { model.tools.vsCode = $0 }
            ))
            Text("Visual Studio Code is downloaded from Microsoft and checksum-verified during setup. It is Microsoft's build with stock settings, so its telemetry is on by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Git, curl, and jq are always included.")
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
            if model.advancedMode {
                TextEditor(text: Binding(
                    get: { model.tools.customSetupScript ?? Self.defaultSetupScript },
                    set: { model.tools.customSetupScript = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 170)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                Text("Runs as root inside \(model.selectedBaselineProfile.displayName) while creating the trusted baseline. Review every command; never paste an untrusted challenge script here. A non-zero exit fails the whole setup and no baseline is created.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .disabled(model.isRunning || model.stage == .provisioning)
    }
}
