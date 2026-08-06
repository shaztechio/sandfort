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

/// `repairBundle` used to infer a VM's role from its display name, matching
/// substrings like "Baseline Setup" and "Protected Baseline". That name contains
/// the user's own instance label: `normalizedLabel` collapses whitespace and caps
/// the length at 48 characters and constrains nothing else.
///
/// So naming an instance "Baseline Setup" reclassified it as the provisioning VM
/// on the next `currentState()`, which cleared `IsolateFromHost` — turning an
/// instance the user chose to run offline, and which the app still listed as
/// offline, into one with host and Internet reachability.
///
/// AGENTS.md already required the opposite: "Treat optional instance labels as
/// display metadata only." Role is now passed in by the caller, which always
/// knows it.
///
/// Found by the Claude pass of the security review, issue #9.
final class BundleRoleTests: XCTestCase {
    private func instanceBundle(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = [
            "Information": ["Name": name],
            // The state an offline instance is left in by setCleanNetworkMode.
            "Network": [["IsolateFromHost": true, "PortForward": []]],
            "Display": [], "Serial": [], "QEMU": ["AdditionalArguments": []]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("config.plist"))
        return root
    }

    private func network(of url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url.appendingPathComponent("config.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        return try XCTUnwrap((plist["Network"] as? [[String: Any]])?.first)
    }

    /// The label is the attack surface: it is free text from the rename field.
    func testAnInstanceLabelCannotTurnOffItsIsolation() throws {
        for label in ["Baseline Setup", "repro for Baseline Setup bug", "Sandbox Ubuntu Setup"] {
            let url = try instanceBundle(named: "Sandfort — Instance 2 — \(label) — TAG")
            try UTMBundleBuilder().repairBundle(
                at: url, profile: LinuxGuestCatalog.defaultProfile, role: .cleanInstance
            )
            XCTAssertEqual(
                try network(of: url)["IsolateFromHost"] as? Bool, true,
                "label \"\(label)\" must not clear IsolateFromHost on an instance"
            )
        }
    }

    /// The mirror case: a label must not force isolation on either, which would
    /// silently override an Internet-enabled instance the user chose.
    func testAnInstanceLabelCannotForceIsolationEither() throws {
        let url = try instanceBundle(named: "Sandfort — Instance 3 — Protected Baseline — TAG")
        // An instance the user launched Internet-enabled.
        let configURL = url.appendingPathComponent("config.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: try Data(contentsOf: configURL), format: nil) as? [String: Any])
        plist["Network"] = [["IsolateFromHost": false, "PortForward": []]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: configURL)

        try UTMBundleBuilder().repairBundle(
            at: url, profile: LinuxGuestCatalog.defaultProfile, role: .cleanInstance
        )
        XCTAssertEqual(try network(of: url)["IsolateFromHost"] as? Bool, false,
                       "Resume must preserve the instance's last explicit network mode")
    }

    /// A label must not strip an instance's display and hand it a serial console.
    func testAnInstanceLabelCannotTakeAwayItsDisplay() throws {
        let url = try instanceBundle(named: "Sandfort — Instance 4 — Baseline Setup — TAG")
        try UTMBundleBuilder().repairBundle(
            at: url, profile: LinuxGuestCatalog.defaultProfile, role: .cleanInstance
        )
        let data = try Data(contentsOf: url.appendingPathComponent("config.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual((plist["Display"] as? [Any])?.count, 1, "an instance keeps its desktop")
        XCTAssertEqual((plist["Serial"] as? [Any])?.count, 0, "an instance gets no serial console")
    }

    /// The roles the caller declares must still behave as before.
    func testDeclaredRolesStillGetTheirOwnPolicy() throws {
        let setup = try instanceBundle(named: "anything at all")
        try UTMBundleBuilder().repairBundle(
            at: setup, profile: LinuxGuestCatalog.defaultProfile, role: .setup
        )
        XCTAssertEqual(try network(of: setup)["IsolateFromHost"] as? Bool, false,
                       "provisioning needs the network")

        let baseline = try instanceBundle(named: "anything at all")
        try UTMBundleBuilder().repairBundle(
            at: baseline, profile: LinuxGuestCatalog.defaultProfile, role: .protectedBaseline
        )
        XCTAssertEqual(try network(of: baseline)["IsolateFromHost"] as? Bool, true,
                       "the protected baseline stays offline")
    }
}
