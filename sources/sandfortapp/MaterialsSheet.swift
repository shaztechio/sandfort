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

import SwiftUI

/// Sends a file or folder from the Mac into one clean instance, as a read-only
/// disc image.
///
/// Scoped to the **selected instance** rather than to the next launch. The
/// development-tools sheet already carries the risk of reading as "applies now"
/// when it means "applies to the next baseline", and a materials sheet that
/// configured some future instance would repeat that mistake. Choosing here
/// attaches to the instance named in the title, and takes effect the next time
/// that instance is launched.
struct MaterialsSheet: View {
    @ObservedObject var model: SandfortViewModel
    let onClose: () -> Void

    private var instance: SandboxInstance? { model.selectedInstance }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.bold())

            Text("Sandbox instances have no shared folders, clipboard, or USB, so there is otherwise no way to get a file from this Mac into one. Materials are the exception, and they only go one way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if let instance, instance.hasMaterials {
                attached(instance)
            } else {
                Text("Nothing is attached to this instance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(instance?.hasMaterials == true ? "Replace…" : "Choose File or Folder…") {
                    model.chooseMaterialsForSelectedInstance()
                }
                .disabled(!model.canChooseMaterials)
                if instance?.hasMaterials == true {
                    Button("Remove", role: .destructive) {
                        model.removeMaterialsFromSelectedInstance()
                    }
                    .disabled(!model.canChooseMaterials)
                }
            }

            Divider()

            Text("Sandfort copies what you choose into a read-only disc image before the instance starts. The guest reads that copy — it cannot change it, and it has no path to the original or to anything else on this Mac. What it cannot do is give it back: anything you send in is readable by whatever runs in that sandbox. Do not send credentials, keys, or files you would not show to the code you are about to run.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Text("Up to \(sizeLimit). A folder is sent as a single .zip archive — extract it inside the sandbox. For anything larger, run the instance with Internet access and download it there instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .disabled(model.isRunning)
    }

    private var title: String {
        guard let instance else { return "Materials" }
        return "Materials for \(instance.displayTitle)"
    }

    private var sizeLimit: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(MaterialsPackager.maximumPayloadBytes))
    }

    /// What is attached, and — the part that matters on a Reset — that it is the
    /// image approved then, not the current contents of where it came from.
    @ViewBuilder
    private func attached(_ instance: SandboxInstance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "opticaldiscdrive")
                    .foregroundStyle(.secondary)
                Text(instance.materialsDisplayName ?? "materials")
                    .font(.body.weight(.medium))
            }
            Text(subtitle(instance))
                .font(.caption)
                .foregroundStyle(.secondary)
            if instance.materialsIsArchive == true {
                Text("This was a folder, so the guest sees one .zip archive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Resetting this instance re-attaches this image — not a fresh copy of its source, which may have changed since.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func subtitle(_ instance: SandboxInstance) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var parts: [String] = []
        if let bytes = instance.materialsByteCount {
            parts.append(formatter.string(fromByteCount: Int64(bytes)))
        }
        if let packedAt = instance.materialsPackedAt {
            parts.append("prepared \(packedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if let source = instance.materialsSourcePath {
            parts.append("from \(source)")
        }
        return parts.joined(separator: " · ")
    }
}
