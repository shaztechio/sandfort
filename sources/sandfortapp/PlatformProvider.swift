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

/// Host-specific VM packaging boundary. Future app targets can supply a provider
/// for another hypervisor without changing downloading, verification, or cloud-init.
protocol VirtualMachineProvider: Sendable {
    var identifier: String { get }
    func createSetupBundle(at: URL, name: String, from: URL, profile: LinuxGuestProfile, credentials: SandboxCredentials, tools: SandboxToolSelection) throws
    func createCleanBundle(from: URL, at: URL, name: String, profile: LinuxGuestProfile, networkMode: SandboxNetworkMode) throws
    func resetCleanBundle(from: URL, at: URL, profile: LinuxGuestProfile, networkMode: SandboxNetworkMode) throws
    func repairBundle(at: URL, profile: LinuxGuestProfile) throws
    func setDisplayName(_ name: String, at: URL) throws
    func ensureBundleNotRunning(at: URL) throws
}
