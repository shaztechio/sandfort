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

/// What the Mac is, as distinct from what slice this process happens to be
/// running as.
///
/// This used to be a compile-time `#if arch(arm64)`, which answers a different
/// question and answers it wrongly in one real case: tick "Open using Rosetta"
/// on Sandfort and the arm64 branch vanishes, so an Apple-silicon Mac was
/// reported as "an unsupported architecture". `doctor()` exists to be believed,
/// so it has to describe the machine.
enum HostArchitecture: Sendable, Hashable {
    case appleSilicon
    case intel

    /// The single UTM guest architecture this host can run under a hypervisor.
    ///
    /// UTM's `hasHypervisorSupport` is false whenever the guest architecture
    /// differs from the host's, and when it is false UTM ignores
    /// `"Hypervisor": true` and launches QEMU with `-accel tcg` instead —
    /// silently, and one to two orders of magnitude slower. Nothing in the UI
    /// would say so.
    var acceleratedGuestArchitecture: String {
        switch self {
        case .appleSilicon: return "aarch64"
        case .intel: return "x86_64"
        }
    }

    func canHardwareAccelerate(_ utmArchitecture: String) -> Bool {
        utmArchitecture == acceleratedGuestArchitecture
    }

    var name: String {
        switch self {
        case .appleSilicon: return "Apple silicon (arm64)"
        case .intel: return "Intel (x86_64)"
        }
    }

    /// Reads an integer `sysctl`, returning nil when the name does not exist.
    /// `sysctl.proc_translated` is absent entirely on an Intel Mac, so an
    /// absent value has to mean "no" rather than trap.
    static func integerSysctl(
        _ name: String,
        query: (String, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int>?) -> Int32 = {
            sysctlbyname($0, $1, $2, nil, 0)
        }
    ) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard query(name, &value, &size) == 0, size == MemoryLayout<Int32>.size else {
            return nil
        }
        return value
    }

    /// True when this process is an x86-64 binary translated by Rosetta on an
    /// Apple-silicon Mac.
    static func isTranslated(flag: (String) -> Int32? = { integerSysctl($0) }) -> Bool {
        flag("sysctl.proc_translated") == 1
    }

    /// `flag` is injectable so both machines can be tested from either machine.
    ///
    /// Order matters. Rosetta hides `hw.optional.arm64` from the translated
    /// process, so the translation flag has to be consulted as well rather than
    /// treated as a refinement of the hardware flag.
    static func detected(flag: (String) -> Int32? = { integerSysctl($0) }) -> HostArchitecture {
        if flag("hw.optional.arm64") == 1 { return .appleSilicon }
        if flag("sysctl.proc_translated") == 1 { return .appleSilicon }
        return .intel
    }

    static var current: HostArchitecture { detected() }

    /// How `doctor()` describes the machine, including the Rosetta case, which
    /// is worth surfacing: a translated Sandfort is not broken, but it is not
    /// what anyone intended either.
    static func description(
        architecture: HostArchitecture = .current,
        translated: Bool = isTranslated()
    ) -> String {
        guard translated else { return architecture.name }
        return "\(architecture.name), and Sandfort is running under Rosetta translation"
    }
}
