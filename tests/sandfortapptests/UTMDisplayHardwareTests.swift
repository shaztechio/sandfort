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

/// The display device is one word in a plist, and on UTM 5 that word decides
/// whether the guest gets host GPU acceleration.
///
/// UTM 5's graphics rewrite gates Venus/Vulkan and the DirectX-over-Metal
/// backend on a single predicate in `UTMQemuConfiguration+Arguments.swift`:
///
/// ```swift
/// display.hardware.rawValue.contains("-gl-") || display.hardware.rawValue.hasSuffix("-gl")
/// ```
///
/// `virtio-gpu-pci` matches neither, so SPICE is started with `gl=off` and none
/// of `hostmem=8G`, `blob=true`, `venus=true`, or `neptune=true` is emitted.
/// Changing the device to a `-gl` variant would silently opt every sandbox into
/// a host GPU path with an 8 GiB host memory window — new guest-to-host attack
/// surface acquired by editing one string, with no other visible symptom.
///
/// So the spelling is asserted rather than assumed. If a `-gl` device is ever
/// wanted, that is a security-model decision and this test is where it should
/// be argued, not a detail to slip past in a rendering fix.
///
/// Established by reading UTM 5.0.4's source. `virtio-gpu-pci` is present in an
/// installed 5.0.4's binary and its new `QEMURenderServer.app` did ship, so the
/// feature is real and the gating predicate is what keeps it away from this
/// display — but no VM has been booted under UTM 5 to see it render. See
/// docs/utm-version-audit.md §3. Issue #25.
final class UTMDisplayHardwareTests: XCTestCase {
    private func configuration(setupMode: Bool) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // repairBundle writes the display for a clean instance without needing
        // a disk, firmware, or seed ISO, so it is the cheapest way to observe
        // exactly what the builder puts in the plist.
        let seed: [String: Any] = [
            "Information": ["Name": "Sandfort — Ubuntu — Instance 1 — TEST"],
            "Display": [],
            "Network": [["IsolateFromHost": true, "PortForward": []]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: seed, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("config.plist"))

        try UTMBundleBuilder().repairBundle(
            at: root,
            profile: LinuxGuestCatalog.defaultProfile,
            role: setupMode ? .setup : .cleanInstance
        )
        let repaired = try Data(contentsOf: root.appendingPathComponent("config.plist"))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: repaired, format: nil) as? [String: Any]
        )
    }

    /// The device itself. Pinned by name because UTM reads this exact string.
    func testInstancesUseTheNonAcceleratedVirtioDisplay() throws {
        let plist = try configuration(setupMode: false)
        let display = try XCTUnwrap((plist["Display"] as? [[String: Any]])?.first)
        XCTAssertEqual(display["Hardware"] as? String, "virtio-gpu-pci")
    }

    /// The property that actually matters, stated as UTM 5 states it. This
    /// keeps passing if the device is ever legitimately changed to another
    /// non-GL one, and fails the moment acceleration is switched on.
    func testTheDisplayDeviceDoesNotRequestHostGPUAcceleration() throws {
        let plist = try configuration(setupMode: false)
        let hardware = try XCTUnwrap((plist["Display"] as? [[String: Any]])?.first?["Hardware"] as? String)

        XCTAssertFalse(
            hardware.contains("-gl-") || hardware.hasSuffix("-gl"),
            """
            “\(hardware)” is a GL display device. On UTM 5 that enables Venus/Vulkan \
            or the Neptune DirectX backend and an 8 GiB host memory window, which is \
            guest-to-host attack surface the security model does not account for.
            """
        )
    }

    /// The provisioning VM is built with a serial console and no display at
    /// all, which is the strongest form of the same guarantee. Asserted so a
    /// change to the setup path cannot quietly give the baseline a GPU.
    func testTheSetupVirtualMachineHasNoDisplayAtAll() throws {
        let plist = try configuration(setupMode: true)
        XCTAssertEqual((plist["Display"] as? [[String: Any]])?.count, 0)
    }
}
