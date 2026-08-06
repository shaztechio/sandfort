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

import XCTest
@testable import SandfortApp

/// `repairBundle` is where the app reasserts its isolation policy over a bundle
/// that already exists. It ran on every `currentState()`, reset `PortForward`
/// and `QEMU.AdditionalArguments`, and silently left `Sharing` and `Input`
/// exactly as it found them.
///
/// UTM's own settings UI can turn on clipboard sharing, a shared host directory,
/// or USB passthrough for any VM in its library. Nothing put that back, so an
/// instance kept those settings across Resume while the app went on claiming the
/// opposite.
///
/// Found by the Gemini pass of the security review, issue #11.
final class RepairBundleIsolationTests: XCTestCase {
    private func bundle(named name: String, sharingEnabled: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = [
            "Information": ["Name": name],
            "Sharing": sharingEnabled
                ? ["ClipboardSharing": true,
                   "DirectoryShareMode": "VirtFS",
                   "DirectoryShareReadOnly": false]
                : ["ClipboardSharing": false,
                   "DirectoryShareMode": "None",
                   "DirectoryShareReadOnly": true],
            "Input": sharingEnabled
                ? ["MaximumUsbShare": 3, "UsbBusSupport": "3.0", "UsbSharing": true]
                : ["MaximumUsbShare": 0, "UsbBusSupport": "3.0", "UsbSharing": false],
            "Network": [["IsolateFromHost": false, "PortForward": [["HostPort": 2222]]]],
            "QEMU": ["AdditionalArguments": [["Argument": "-nographic"]]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("config.plist"))
        return root
    }

    /// The role a caller would pass for each bundle under test.
    private var role: VirtualMachineRole { .cleanInstance }

    private func repaired(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url.appendingPathComponent("config.plist"))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    /// The guarantee in security-model.md: no host directory sharing, no
    /// synchronized clipboard, no automatic USB sharing — in every mode.
    func testRepairTurnsSharingAndUsbBackOff() throws {
        let url = try bundle(named: "Sandfort — Ubuntu — Instance 1 — TEST", sharingEnabled: true)
        try UTMBundleBuilder().repairBundle(at: url, profile: LinuxGuestCatalog.defaultProfile, role: role)
        let plist = try repaired(url)

        let sharing = try XCTUnwrap(plist["Sharing"] as? [String: Any])
        XCTAssertEqual(sharing["ClipboardSharing"] as? Bool, false)
        XCTAssertEqual(sharing["DirectoryShareMode"] as? String, "None")
        XCTAssertEqual(sharing["DirectoryShareReadOnly"] as? Bool, true)

        let input = try XCTUnwrap(plist["Input"] as? [String: Any])
        XCTAssertEqual(input["UsbSharing"] as? Bool, false)
        XCTAssertEqual(input["MaximumUsbShare"] as? Int, 0)
    }

    /// The protected baseline is the thing every instance is restored from, so
    /// it matters most that its isolation cannot be edited away in UTM.
    func testRepairTurnsSharingOffForTheProtectedBaselineToo() throws {
        let url = try bundle(named: "Sandfort — Ubuntu — Protected Baseline TEST", sharingEnabled: true)
        try UTMBundleBuilder().repairBundle(
            at: url, profile: LinuxGuestCatalog.defaultProfile, role: .protectedBaseline)
        let plist = try repaired(url)

        XCTAssertEqual((plist["Sharing"] as? [String: Any])?["ClipboardSharing"] as? Bool, false)
        XCTAssertEqual((plist["Input"] as? [String: Any])?["UsbSharing"] as? Bool, false)
        // The baseline must also stay offline, which already worked.
        let network = try XCTUnwrap((plist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual(network["IsolateFromHost"] as? Bool, true)
    }

    /// A bundle that was already correct must come out unchanged, so the repair
    /// cannot be blamed for drift it did not cause.
    func testRepairLeavesAnAlreadyIsolatedBundleAlone() throws {
        let url = try bundle(named: "Sandfort — Ubuntu — Instance 2 — TEST", sharingEnabled: false)
        try UTMBundleBuilder().repairBundle(at: url, profile: LinuxGuestCatalog.defaultProfile, role: role)
        let plist = try repaired(url)

        XCTAssertEqual((plist["Sharing"] as? [String: Any])?["DirectoryShareMode"] as? String, "None")
        XCTAssertEqual((plist["Input"] as? [String: Any])?["MaximumUsbShare"] as? Int, 0)
    }

    /// Port forwarding already worked; keeping it asserted here means one test
    /// covers the whole "reassert isolation" contract rather than half of it.
    func testRepairStillClearsPortForwardsAndExtraQemuArguments() throws {
        let url = try bundle(named: "Sandfort — Ubuntu — Instance 3 — TEST", sharingEnabled: true)
        try UTMBundleBuilder().repairBundle(at: url, profile: LinuxGuestCatalog.defaultProfile, role: role)
        let plist = try repaired(url)

        let network = try XCTUnwrap((plist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual((network["PortForward"] as? [Any])?.count, 0)
        XCTAssertEqual(((plist["QEMU"] as? [String: Any])?["AdditionalArguments"] as? [Any])?.count, 0)
    }
}
