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

/// Materials are the only route by which anything from the user's Mac reaches a
/// sandbox, so where they may and may not go is an isolation rule.
///
/// Two of these guarantees are structural and one is enforced. The image is
/// built from a copy, so the guest can never reach the original whatever UTM
/// does; and `createSetupBundle` has no way to express materials at all. What
/// needs enforcing is that a clean instance's image stays read-only, and that a
/// baseline never carries one — which `repairBundle` is responsible for, because
/// it is the hook that runs on every state read.
final class MaterialsAttachmentTests: XCTestCase {
    private let builder = UTMBundleBuilder()

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A bundle shaped like one UTM would accept, without running a hypervisor.
    private func bundle(in root: URL, named name: String = "Instance1.utm") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Data", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Information": ["Name": "Sandfort — Instance 1"],
            "Drive": [
                ["Identifier": UUID().uuidString.uppercased(), "ImageName": "sandfort.qcow2",
                 "ImageType": "Disk", "Interface": "VirtIO", "InterfaceVersion": 1, "ReadOnly": false],
                ["Identifier": UUID().uuidString.uppercased(), "ImageName": "seed.iso",
                 "ImageType": "Disk", "Interface": "VirtIO", "InterfaceVersion": 1, "ReadOnly": true]
            ]
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("config.plist"))
        // Attaching takes a lock on the disk, and repairing resizes it, so the
        // fixture needs a QCOW2 both paths accept — the same header shape the
        // existing resize tests use.
        var header = Data(repeating: 0, count: 128 * 1024)
        header.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])   // QFI\u{fb}
        header.replaceSubrange(4..<8, with: [0, 0, 0, 3])               // version 3
        header.replaceSubrange(20..<24, with: [0, 0, 0, 16])            // cluster bits
        header.replaceSubrange(36..<40, with: [0, 0, 0, 7])             // L1 entries
        header.replaceSubrange(40..<48, with: [0, 0, 0, 0, 0, 1, 0, 0]) // L1 offset
        try header.write(to: url.appendingPathComponent("Data/sandfort.qcow2"))
        return url
    }

    private func drives(in bundleURL: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("config.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (plist as? [String: Any])?["Drive"] as? [[String: Any]] ?? []
    }

    private func materials(named name: String = "take-home.zip") throws -> MaterialsImage {
        let root = try workspace()
        let source = root.appendingPathComponent(name)
        try Data(repeating: 0x11, count: 2048).write(to: source)
        return try MaterialsPackager.pack(contentsOf: source)
    }

    private var profile: LinuxGuestProfile { LinuxGuestCatalog.defaultProfile }

    // MARK: - Attaching

    func testAttachingAddsAReadOnlyDriveAndTheImageItself() throws {
        let root = try workspace()
        let instance = try bundle(in: root)

        try builder.attachMaterials(try materials(), to: instance)

        let all = try drives(in: instance)
        XCTAssertEqual(all.count, 3, "the disk, the seed, and materials")
        let materialsDrive = try XCTUnwrap(all.first { $0["ImageName"] as? String == "materials.iso" })
        // Optical media on USB, so udisks2 treats it as removable and GNOME
        // Files shows it. A VirtIO disk has no hotpluggable bus, so it is
        // classed as an internal system drive and is not offered.
        XCTAssertEqual(materialsDrive["ImageType"] as? String, "CD")
        XCTAssertEqual(materialsDrive["Interface"] as? String, "USB")
        XCTAssertEqual(materialsDrive["InterfaceVersion"] as? Int, 1)
        XCTAssertEqual(materialsDrive["ReadOnly"] as? Bool, true, "the guest must not write to it")
        XCTAssertNil(materialsDrive["Removable"], "not ejectable from inside the guest")

        let identifiers = all.compactMap { $0["Identifier"] as? String }
        XCTAssertEqual(Set(identifiers).count, 3, "every drive needs its own identifier")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: instance.appendingPathComponent("Data/materials.iso").path
            )
        )
    }

    /// Choosing materials twice replaces them. Appending would leave two drives
    /// claiming the same image name, and the guest would see whichever UTM
    /// happened to enumerate first.
    func testAttachingTwiceReplacesRatherThanAccumulates() throws {
        let root = try workspace()
        let instance = try bundle(in: root)

        try builder.attachMaterials(try materials(named: "first.zip"), to: instance)
        try builder.attachMaterials(try materials(named: "second.zip"), to: instance)

        let all = try drives(in: instance)
        XCTAssertEqual(all.count, 3, "still one materials drive, not two")
        XCTAssertEqual(all.filter { $0["ImageName"] as? String == "materials.iso" }.count, 1)

        let image = try Data(contentsOf: instance.appendingPathComponent("Data/materials.iso"))
        XCTAssertTrue(
            String(decoding: image, as: UTF8.self).contains("second.zip"),
            "the newer choice is what the guest gets"
        )
    }

    /// A failed attach must not leave the user's file behind.
    ///
    /// The image is written before the plist that references it, so a failure in
    /// between would otherwise leave an orphaned copy inside the bundle with
    /// nothing pointing at it — the precise outcome the rest of this file exists
    /// to prevent. Failing without materials is fine; failing with a hidden copy
    /// of them is not.
    ///
    /// Getting the failure in the right place matters more than it looks. Making
    /// `config.plist` unreadable fails *before* the image is written, so the
    /// assertion passes trivially and proves nothing. The bundle directory is
    /// made read-only instead, leaving `Data/` writable: the image write and the
    /// permission change both succeed, and only the atomic plist rewrite — which
    /// needs a temporary file beside `config.plist` — fails.
    func testAFailedAttachLeavesNoOrphanedImage() throws {
        let root = try workspace()
        let instance = try bundle(in: root)
        let imageURL = instance.appendingPathComponent("Data/materials.iso")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: instance.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: instance.path
            )
        }

        XCTAssertThrowsError(try self.builder.attachMaterials(try self.materials(), to: instance))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: imageURL.path),
            "a failed attach must not leave the user's file in the bundle"
        )
    }

    // MARK: - The drift that repairBundle exists to undo

    /// `ReadOnly` is a key another application parses, and UTM's own settings UI
    /// can change it. A guarantee written once is a guarantee that drifts, which
    /// is why every other isolation key is reasserted here too.
    func testRepairReassertsReadOnlyOnAnInstance() throws {
        let root = try workspace()
        let instance = try bundle(in: root)
        try builder.attachMaterials(try materials(), to: instance)

        let configURL = instance.appendingPathComponent("config.plist")
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: try Data(contentsOf: configURL), format: nil
            ) as? [String: Any]
        )
        var all = try XCTUnwrap(plist["Drive"] as? [[String: Any]])
        let index = try XCTUnwrap(all.firstIndex { $0["ImageName"] as? String == "materials.iso" })
        all[index]["ReadOnly"] = false
        all[index]["Removable"] = true
        plist["Drive"] = all
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: configURL)

        try builder.repairBundle(at: instance, profile: profile, role: .cleanInstance)

        let repaired = try XCTUnwrap(
            try drives(in: instance).first { $0["ImageName"] as? String == "materials.iso" }
        )
        XCTAssertEqual(repaired["ReadOnly"] as? Bool, true, "read-only is restored")
        XCTAssertEqual(repaired["ImageType"] as? String, "CD",
                       "repair must reassert what attach wrote, or it undoes it")
        XCTAssertEqual(repaired["Interface"] as? String, "USB")
        XCTAssertNil(repaired["Removable"])
    }

    // MARK: - Materials never reach a baseline

    func testRepairStripsMaterialsFromABaselineAndFromDisk() throws {
        for role in [VirtualMachineRole.protectedBaseline, .setup] {
            let root = try workspace()
            let baseline = try bundle(in: root, named: "Baseline.utm")
            try builder.attachMaterials(try materials(), to: baseline)

            try builder.repairBundle(at: baseline, profile: profile, role: role)

            XCTAssertNil(
                try drives(in: baseline).first { $0["ImageName"] as? String == "materials.iso" },
                "\(role) must carry no materials drive"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: baseline.appendingPathComponent("Data/materials.iso").path
                ),
                "\(role) must not keep the payload either — an orphaned image is still the user's file"
            )
        }
    }

    /// `createCleanBundle` clones the whole baseline bundle, so a stray image in
    /// the baseline would propagate to every instance ever made from it — with
    /// no drive entry, because the plist is rewritten from scratch. That is an
    /// orphaned copy of the user's file in a place nobody would look.
    func testACleanBundleDoesNotInheritAStrayMaterialsImage() throws {
        let root = try workspace()
        let baseline = try bundle(in: root, named: "Baseline.utm")
        try Data(repeating: 0x22, count: 512)
            .write(to: baseline.appendingPathComponent("Data/materials.iso"))

        let instance = root.appendingPathComponent("Instance1.utm", isDirectory: true)
        try builder.createCleanBundle(
            from: baseline, at: instance, name: "Sandfort — Instance 1",
            profile: profile, networkMode: .offline
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: instance.appendingPathComponent("Data/materials.iso").path
            ),
            "an instance starts with no materials, whatever was left in the baseline"
        )
    }
}
