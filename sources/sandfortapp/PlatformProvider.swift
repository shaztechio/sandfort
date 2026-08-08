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

/// Host-specific VM packaging boundary. Future app targets can supply a provider
/// for another hypervisor without changing downloading, verification, or cloud-init.
/// What a bundle is for. Passed in by the caller, which always knows, rather
/// than inferred from the VM's display name — that name contains the user's own
/// instance label, so sniffing it let a label decide an isolation policy.
enum VirtualMachineRole: Sendable {
    /// The provisioning VM. Needs the network to install packages, and a serial
    /// console because cloud images log setup to the serial port.
    case setup
    /// The finished baseline every instance is restored from. Always offline.
    case protectedBaseline
    /// A disposable numbered instance. Keeps its own last explicit network mode.
    case cleanInstance
}

protocol VirtualMachineProvider: Sendable {
    var identifier: String { get }
    /// Builds the provisioning VM from a verified image.
    ///
    /// The image arrives already checked against `profile.image.sha256`, and an
    /// implementation must check it **again** against the disk it placed in the
    /// bundle, before anything modifies that disk. The caller verifies a file in
    /// the shared cache; what boots is a copy, and only the provider is in a
    /// position to confirm those are the same bytes. A failure must throw and
    /// leave nothing behind that a later step could mistake for a baseline.
    func createSetupBundle(at: URL, name: String, from: URL, profile: LinuxGuestProfile, credentials: SandboxCredentials, tools: SandboxToolSelection) throws
    func createCleanBundle(from: URL, at: URL, name: String, profile: LinuxGuestProfile, networkMode: SandboxNetworkMode) throws
    func resetCleanBundle(from: URL, at: URL, profile: LinuxGuestProfile, networkMode: SandboxNetworkMode) throws
    func repairBundle(at: URL, profile: LinuxGuestProfile, role: VirtualMachineRole) throws
    /// Places a materials image in a clean instance's bundle and attaches it
    /// read-only.
    ///
    /// Never called for a setup VM or a protected baseline, and `repairBundle`
    /// removes one from those roles if it somehow arrives. The guest is handed
    /// an image Sandfort built from a copy, never the user's file, so there is
    /// no path back to the original whatever the hypervisor does with the drive.
    ///
    /// Deliberately a requirement rather than a parameter on `createCleanBundle`,
    /// and deliberately without a default implementation: a provider that
    /// silently ignored materials would tell a user their files are in a sandbox
    /// that does not have them.
    func attachMaterials(_ image: MaterialsImage, to bundleURL: URL) throws
    /// Removes a materials image from a bundle: the drive entry **and** the file.
    ///
    /// The counterpart of `attachMaterials`, and not optional. Clearing the
    /// record without detaching would let a user remove their file, resume, and
    /// still find it mounted in the sandbox — the opposite of what removal
    /// means, and a copy of their file left somewhere they believe is empty.
    func detachMaterials(from bundleURL: URL) throws
    func setDisplayName(_ name: String, at: URL) throws
    func ensureBundleNotRunning(at: URL) throws
}
