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
