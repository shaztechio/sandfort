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

import Foundation

enum SandboxNetworkMode: Sendable {
    case offline
    case internet
}

struct SandboxCredentials: Codable, Sendable {
    let username: String
    let password: String
}

struct SandboxToolSelection: Codable, Sendable {
    var python: Bool
    var nodeJS: Bool
    var customSetupScript: String? = nil
    var verboseSetupLogging: Bool? = nil
    /// Optional so tool selections persisted before VS Code existed still
    /// decode. Absent means on, matching the default for new baselines.
    var vsCode: Bool? = nil

    var installsVSCode: Bool { vsCode ?? true }

    static let recommended = SandboxToolSelection(python: true, nodeJS: true, vsCode: true)

    var description: String {
        var names = ["Git", "curl", "jq"]
        if python { names.append("Python 3") }
        if nodeJS { names.append("latest Node.js LTS") }
        if installsVSCode { names.append("Visual Studio Code") }
        if customSetupScript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            names.append("custom setup script")
        }
        return names.joined(separator: ", ")
    }
}

struct SandboxInstance: Codable, Identifiable, Sendable, Equatable {
    var id: Int { number }
    let number: Int
    var bundlePath: String
    var vmName: String
    var label: String? = nil

    var displayTitle: String {
        guard let label, !label.isEmpty else { return "Sandbox Instance \(number)" }
        return "Sandbox Instance \(number) — \(label)"
    }

    static func normalizedLabel(_ label: String?) throws -> String? {
        guard let label else { return nil }
        let normalized = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count <= 48 else { throw SandboxError.invalidInstanceName }
        return normalized.isEmpty ? nil : normalized
    }
}

struct SandboxState: Codable, Sendable {
    enum Stage: String, Codable, Sendable {
        case provisioning
        case ready
    }

    var stage: Stage
    var credentials: SandboxCredentials
    var tools: SandboxToolSelection?
    var setupBundlePath: String
    var sandboxBundlePath: String?
    var setupVMName: String? = nil
    var sandboxVMName: String? = nil
    var instances: [SandboxInstance]? = nil
    var nextInstanceNumber: Int? = nil
    var guestProfileID: String? = nil
    var guestProfileRevision: Int? = nil
    var guestImageSHA256: String? = nil

    var resolvedInstances: [SandboxInstance] {
        if let instances, !instances.isEmpty {
            return instances.sorted { $0.number < $1.number }
        }
        guard let sandboxBundlePath else { return [] }
        return [SandboxInstance(
            number: 1,
            bundlePath: sandboxBundlePath,
            vmName: sandboxVMName ?? "Sandfort — Instance 1",
            label: nil
        )]
    }

    var utmRegistrationNames: [String] {
        var seen: Set<String> = []
        return ([setupVMName].compactMap { $0 } + resolvedInstances.map(\.vmName))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    mutating func replaceInstances(_ newInstances: [SandboxInstance]) {
        let sorted = newInstances.sorted { $0.number < $1.number }
        instances = sorted
        sandboxBundlePath = sorted.first?.bundlePath
        sandboxVMName = sorted.first?.vmName
    }

    mutating func allocateInstanceNumber() -> Int {
        let number = max(nextInstanceNumber ?? 1, (resolvedInstances.map(\.number).max() ?? 0) + 1)
        nextInstanceNumber = number + 1
        return number
    }
}

enum WorkflowEvent: Sendable {
    case phase(String)
    case progress(completed: Int64, total: Int64)
    case log(String)
}

enum SandboxError: LocalizedError {
    case utmNotInstalled
    case invalidDownloadResponse
    case checksumMismatch(expected: String, actual: String)
    case invalidCloudDisk(String)
    case alreadyExists
    case sandboxNotCreated
    case setupNotComplete
    case utmResourcesMissing
    case virtualMachineRunning
    case setupScriptTooLarge
    case sandboxInstanceNotFound
    case invalidInstanceName
    case invalidGuestPassword
    case unsupportedGuestProfile(String)
    case incompatibleGuestProfile(String)
    case incompleteSetupProfileMetadata

    var errorDescription: String? {
        switch self {
        case .utmNotInstalled:
            return "UTM is not installed in Applications. Install UTM, then try again."
        case .invalidDownloadResponse:
            return "The Linux image download server returned an unexpected response."
        case let .checksumMismatch(expected, actual):
            return "The Linux image failed SHA-256 verification (expected \(expected), received \(actual)). Nothing was opened."
        case let .invalidCloudDisk(reason):
            return "The downloaded cloud disk is invalid: \(reason)"
        case .alreadyExists:
            return "A sandbox already exists. Use Rebuild if you want to replace it."
        case .sandboxNotCreated:
            return "Create the sandbox first."
        case .setupNotComplete:
            return "Finish the Linux guest setup before creating clean sessions."
        case .utmResourcesMissing:
            return "UTM's ARM64 UEFI firmware could not be found. Reinstall the current version of UTM."
        case .virtualMachineRunning:
            return "Shut down the virtual machine in UTM before restoring or copying its clean disk."
        case .setupScriptTooLarge:
            return "The custom setup script is larger than 64 KiB. Shorten it, or have it download a verified setup file inside the guest."
        case .sandboxInstanceNotFound:
            return "That sandbox instance no longer exists. Create a new clean sandbox instance."
        case .invalidInstanceName:
            return "Sandbox names must be 48 characters or fewer."
        case .invalidGuestPassword:
            return "The guest password must contain 8 to 128 visible characters with no spaces or line breaks."
        case let .unsupportedGuestProfile(profileID):
            return "This sandbox uses the unsupported Linux guest profile '\(profileID)'. Reinstall a compatible Sandfort version or rebuild it with a supported profile."
        case let .incompatibleGuestProfile(profileID):
            return "This baseline uses an incompatible revision or image of the Linux guest profile '\(profileID)'. You may Resume an existing instance without changing it, or choose Rebuild to create a compatible baseline."
        case .incompleteSetupProfileMetadata:
            return "This unfinished setup predates exact Linux profile tracking, so Sandfort cannot safely recreate its setup media. Choose Rebuild to start a verified setup."
        }
    }
}
