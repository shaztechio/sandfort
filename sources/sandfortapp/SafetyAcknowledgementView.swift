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
