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
