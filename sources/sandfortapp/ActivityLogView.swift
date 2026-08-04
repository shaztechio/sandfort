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

/// Status, progress, and the activity log.
///
/// The log used to occupy a large pane whether or not anything had happened.
/// It is collapsed by default and expands on demand, while the status line and
/// progress stay visible because they are what the user is waiting on during a
/// 20 to 45 minute baseline build.
struct ActivityLogView: View {
    @ObservedObject var model: SandfortViewModel
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.statusLine).font(.headline)
                if let fraction = model.progressFraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if model.isRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
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
            }

            DisclosureGroup("Activity log", isExpanded: $isExpanded) {
                ScrollView {
                    Text(model.output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 140, maxHeight: 260)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .font(.callout)
        }
        // Something going wrong is exactly when the log should not be hidden.
        .onChange(of: model.isRunning) { running in
            if running { isExpanded = true }
        }
    }
}
