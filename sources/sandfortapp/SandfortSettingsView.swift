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

            SandfortAdvancedSettingsView(runtime: runtime)
                .tabItem {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
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

/// Pins the UTM that Sandfort drives.
///
/// A testing aid, and labelled as one rather than hidden. Sandfort supports UTM
/// 4.7.5 and 5.0.4, and they differ at run time — 5.0.4 added the
/// `reload configuration` command that lets a materials disc reach a resumed
/// instance without quitting UTM, and 4.7.5 has no such command. Verifying
/// either path means choosing which copy is driven, and Launch Services picks
/// on its own otherwise.
///
/// Unset is the default and changes nothing.
private struct SandfortAdvancedSettingsView: View {
    let runtime: SandfortRuntimeConfiguration
    @State private var pinnedPath = UTMLauncher.pinnedApplicationURL?.path ?? ""
    @State private var problem = ""

    var body: some View {
        Form {
            Section("UTM version") {
                LabeledContent("Pinned application") {
                    Text(pinnedPath.isEmpty ? "None — Sandfort finds UTM automatically" : pinnedPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(pinnedPath.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Button("Choose UTM…") { choose() }
                    Button("Clear") { clear() }
                        .disabled(pinnedPath.isEmpty)
                    Spacer()
                    if !problem.isEmpty {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Text("For testing against a specific UTM version. Leave this unset unless you have a reason: Sandfort otherwise finds UTM wherever macOS has registered it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("A pinned copy is used for launching, for the UEFI firmware Sandfort reads, and for every command it sends — so it must be the copy you actually run. If it is not open when Sandfort needs it, Sandfort opens that copy rather than talking to a different one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Check My Mac reports which UTM is in use, and says so when a pin is being ignored because the application has moved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// A panel rather than a text field: a typed path is a typo waiting to point
    /// Sandfort at something that is not UTM, and the firmware read follows
    /// whatever is resolved.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Pin"
        panel.message = "Choose the UTM application Sandfort should use."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        // Validated on selection rather than at launch, so a mis-pick is a
        // message here instead of a confusing failure much later.
        guard UTMLauncher.readBundleIdentifier(at: chosen) == UTMLauncher.bundleIdentifier else {
            problem = "That is not UTM."
            return
        }
        UTMLauncher.pinnedApplicationURL = chosen
        pinnedPath = chosen.path
        problem = ""
    }

    private func clear() {
        UTMLauncher.pinnedApplicationURL = nil
        pinnedPath = ""
        problem = ""
    }
}
