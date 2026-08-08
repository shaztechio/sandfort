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

import Foundation

/// What an instance carries, said out loud at the moment it is launched.
///
/// Right before running untrusted code the question is *what is in this
/// sandbox*, and the app used to answer nothing. Everything here already exists
/// in saved state; this only describes it.
///
/// One formatter for all three launch paths — Create, Reset, Resume — because
/// three call sites writing their own version is how they drift into disagreeing
/// about the same instance.
///
/// **Nothing here may ever emit the guest password or the custom setup script's
/// contents.** The script is arbitrary user text that ran as root, the activity
/// log has a copy button, and `AGENTS.md` forbids logging either. The formatter
/// is handed a `SandboxToolSelection` that *contains* the script, so this is a
/// live hazard rather than a theoretical one, and `InstanceLaunchSummaryTests`
/// pins it with a script full of secret-shaped text.
enum InstanceLaunchSummary {
    /// How the instance's network was decided for this launch.
    enum Network {
        /// Create and Reset choose a mode and write it into the configuration.
        case chosen(SandboxNetworkMode)
        /// Resume deliberately preserves whatever the instance last ran with,
        /// and the workflow does not read it back — so claiming a mode here
        /// would be a guess printed as fact.
        case preserved
    }

    /// `tools` is optional because state written before tool selections were
    /// persisted has none. That case says so rather than defaulting to
    /// `.recommended`, which would state a fabricated fact about what is in the
    /// guest — the same error as claiming a network mode Resume does not know.
    static func lines(
        instance: SandboxInstance,
        profile: LinuxGuestProfile,
        tools: SandboxToolSelection?,
        network: Network
    ) -> [String] {
        var lines = [identity(instance, profile: profile, network: network)]
        guard let tools else {
            lines.append("Baseline tools: not recorded for this baseline.")
            lines.append(materials(instance))
            return lines
        }
        lines.append("Baseline tools: \(toolNames(tools).joined(separator: ", ")).")
        if hasCustomSetupScript(tools) {
            // Its own line, not an item in the tool list. Tools come from a fixed
            // menu; a custom script is arbitrary change to the guest, and it is
            // what you would want to know first when a sandbox behaves oddly.
            lines.append(
                "This baseline was built with a custom setup script, which ran as root during setup."
            )
        }
        lines.append(materials(instance))
        return lines
    }

    private static func identity(
        _ instance: SandboxInstance,
        profile: LinuxGuestProfile,
        network: Network
    ) -> String {
        switch network {
        case .chosen(let mode):
            let described = mode == .offline ? "offline" : "Internet-enabled"
            return "\(instance.displayTitle) — \(profile.displayName), \(described)."
        case .preserved:
            return "\(instance.displayTitle) — \(profile.displayName), "
                + "resuming with the network mode it last ran with."
        }
    }

    /// The fixed baseline set, plus whatever was selected. Deliberately not
    /// `SandboxToolSelection.description`, which folds the custom script in as
    /// though it were another tool.
    private static func toolNames(_ tools: SandboxToolSelection) -> [String] {
        var names = ["Git", "curl", "jq"]
        if tools.python { names.append("Python 3") }
        if tools.nodeJS { names.append("Node.js LTS") }
        if tools.installsVSCode { names.append("Visual Studio Code") }
        return names
    }

    private static func hasCustomSetupScript(_ tools: SandboxToolSelection) -> Bool {
        tools.customSetupScript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Materials are per instance, and testing showed that scoping is not
    /// obvious. "None attached" is a normal state, so it is stated rather than
    /// left to silence — an absent line reads as an unanswered question.
    ///
    /// The source path is deliberately omitted. It is a path on the user's Mac,
    /// it is not needed to answer "what is in this sandbox", and the activity log
    /// is something people paste into issues.
    private static func materials(_ instance: SandboxInstance) -> String {
        guard instance.hasMaterials else { return "Materials: none attached." }
        let name = instance.materialsDisplayName ?? "materials"
        var described = name
        if let bytes = instance.materialsByteCount {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            described += " (\(formatter.string(fromByteCount: Int64(bytes))))"
        }
        if instance.materialsIsArchive == true {
            described += ", a folder sent as one .zip archive"
        }
        return "Materials: \(described), read-only."
    }
}
