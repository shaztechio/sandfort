import Foundation
import XCTest
@testable import SandfortApp

final class SandfortAppTests: XCTestCase {
    func testGeneratedCredentialsUseAMemorableHyphenatedPhrase() {
        let credentials = CloudInit.credentials()
        let parts = credentials.password.split(separator: "-")
        XCTAssertEqual(credentials.username, "sandfort")
        XCTAssertEqual(parts.count, 4)
        XCTAssertTrue(parts.allSatisfy { $0.allSatisfy(\.isLowercase) })
    }

    func testCloudInitISOHasCIDATAVolumeAndExpectedFiles() throws {
        let credentials = SandboxCredentials(username: "sandfort", password: "safe-test")
        let iso = try CloudInit.seedISO(credentials: credentials)
        XCTAssertEqual(String(data: iso.subdata(in: 32_769..<32_774), encoding: .ascii), "CD001")
        XCTAssertEqual(String(data: iso.subdata(in: 32_808..<32_814), encoding: .ascii), "CIDATA")
        XCTAssertNotNil(iso.range(of: Data("USER_DAT;1".utf8)))
        XCTAssertNotNil(iso.range(of: Data("META_DAT;1".utf8)))
        XCTAssertNotNil(iso.range(of: Data([0x53, 0x50, 7, 1, 0xbe, 0xef, 0])))
        XCTAssertNotNil(iso.range(of: Data([0x4e, 0x4d])))
        XCTAssertNotNil(iso.range(of: Data("# sandfort packages:".utf8)))
        XCTAssertNotNil(iso.range(of: Data("password: 'safe-test'".utf8)))
        XCTAssertNotNil(iso.range(of: Data("#   - python3-pip".utf8)))
        XCTAssertNotNil(iso.range(of: Data("#   - python3-venv".utf8)))
        XCTAssertNil(iso.range(of: Data("#   - nodejs".utf8)))
        XCTAssertNil(iso.range(of: Data("#   - npm".utf8)))
        XCTAssertNotNil(iso.range(of: Data("mode: poweroff".utf8)))
        XCTAssertNotNil(iso.range(of: Data("condition: [test, -f, /var/lib/sandfort/setup-complete]".utf8)))
        XCTAssertNotNil(iso.range(of: Data("[Sandfort] Baseline setup has started.".utf8)))
        XCTAssertNotNil(iso.range(of: Data("[systemctl, mask, --runtime, --now, serial-getty@ttyAMA0.service]".utf8)))
        XCTAssertNotNil(iso.range(of: Data("Storage=volatile".utf8)))
        XCTAssertNotNil(iso.range(of: Data("RuntimeMaxUse=16M".utf8)))
        let isoText = String(decoding: iso, as: UTF8.self)
        let finalizerSection = try XCTUnwrap(isoText.range(of: "- path: /var/lib/sandfort/baseline-finalize.sh"))
        let finalizerTail = isoText[finalizerSection.lowerBound...]
        let contentLine = try XCTUnwrap(finalizerTail.split(separator: "\n").first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("content: ")
        })
        let encodedFinalizer = contentLine.trimmingCharacters(in: .whitespaces).dropFirst("content: ".count)
        let finalizer = String(decoding: try XCTUnwrap(Data(base64Encoded: String(encodedFinalizer))), as: UTF8.self)
        XCTAssertTrue(finalizer.contains("journalctl --rotate"))
        XCTAssertTrue(finalizer.contains("journalctl --vacuum-size=16M"))
        XCTAssertTrue(finalizer.contains("systemctl mask systemd-journal-flush.service"))
        XCTAssertTrue(finalizer.contains("systemctl restart systemd-journald.service"))
        XCTAssertTrue(finalizer.contains("apt-get clean"))
        XCTAssertTrue(finalizer.contains("sync"))
        XCTAssertTrue(finalizer.contains("https://nodejs.org/dist/index.json"))
        XCTAssertTrue(finalizer.contains("linux-arm64.tar.xz"))
        XCTAssertTrue(finalizer.contains("SHASUMS256.txt"))
        XCTAssertTrue(finalizer.contains("sha256sum --check"))
        XCTAssertTrue(finalizer.contains("command -v node"))
        XCTAssertTrue(finalizer.contains("command -v npm"))
        XCTAssertTrue(finalizer.contains("systemctl unmask --runtime serial-getty@ttyAMA0.service"))
        XCTAssertTrue(finalizer.contains("systemctl start serial-getty@ttyAMA0.service"))
        XCTAssertTrue(finalizer.contains("dpkg-query -W gdm3"))
        XCTAssertTrue(finalizer.contains("printf '%s\\n' /usr/sbin/gdm3 > /etc/X11/default-display-manager"))
        XCTAssertTrue(finalizer.contains("systemctl is-enabled --quiet gdm3.service"))
        XCTAssertTrue(finalizer.contains("systemctl mask systemd-networkd-wait-online.service"))
        XCTAssertTrue(finalizer.contains("systemctl mask NetworkManager-wait-online.service"))
        if let output = ProcessInfo.processInfo.environment["SANDBOX_VM_ISO_TEST_OUTPUT"] {
            try iso.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    func testCloudInitOmitsOptionalToolsWhenDeselected() throws {
        let iso = try CloudInit.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(python: false, nodeJS: false)
        )
        XCTAssertNotNil(iso.range(of: Data("#   - git".utf8)))
        XCTAssertNotNil(iso.range(of: Data("#   - curl".utf8)))
        XCTAssertNil(iso.range(of: Data("#   - python3-pip".utf8)))
        XCTAssertNil(iso.range(of: Data("#   - nodejs".utf8)))
    }

    func testCustomGuestPasswordIsValidatedAndSafelyQuoted() throws {
        let credentials = try CloudInit.credentials(password: "safe'phrase-123")
        XCTAssertEqual(credentials.password, "safe'phrase-123")
        let iso = try CloudInit.seedISO(credentials: credentials)
        XCTAssertNotNil(iso.range(of: Data("password: 'safe''phrase-123'".utf8)))
        XCTAssertThrowsError(try CloudInit.credentials(password: "short"))
        XCTAssertThrowsError(try CloudInit.credentials(password: "contains space"))
        XCTAssertThrowsError(try CloudInit.credentials(password: "contains\nnewline"))
        XCTAssertThrowsError(try CloudInit.credentials(password: String(repeating: "x", count: 129)))
    }

    func testCloudInitCanMirrorDetailedSetupOutputToTerminal() throws {
        let iso = try CloudInit.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(
                python: false,
                nodeJS: false,
                verboseSetupLogging: true
            )
        )
        let finalizer = try decodedFinalizer(from: iso)
        XCTAssertTrue(finalizer.contains("exec > >(tee -a /var/log/sandfort-setup.log) 2>&1"))
        XCTAssertFalse(finalizer.contains("exec 3>&1"))
    }

    func testCloudInitSafelyEmbedsCustomSetupScript() throws {
        let script = "#!/usr/bin/env bash\nset -euo pipefail\napt-get install -y ripgrep\n"
        let iso = try CloudInit.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(python: false, nodeJS: false, customSetupScript: script)
        )
        let encoded = Data(script.trimmingCharacters(in: .whitespacesAndNewlines).utf8).base64EncodedString()
        XCTAssertNotNil(iso.range(of: Data("encoding: b64".utf8)))
        XCTAssertNotNil(iso.range(of: Data(encoded.utf8)))
        XCTAssertNotNil(iso.range(of: Data("/var/lib/sandfort/custom-setup.sh".utf8)))
        XCTAssertNotNil(iso.range(of: Data("/var/lib/sandfort/baseline-finalize.sh".utf8)))
        XCTAssertNil(iso.range(of: Data("apt-get install -y ripgrep".utf8)))
    }

    func testCloudInitRejectsOversizedCustomSetupScript() {
        XCTAssertThrowsError(try CloudInit.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(
                python: false,
                nodeJS: false,
                customSetupScript: String(repeating: "x", count: 65_537)
            )
        ))
    }

    func testQCOW2ResizeUpdatesVirtualSizeOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var header = Data(repeating: 0, count: 128 * 1024)
        header.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])
        header.replaceSubrange(4..<8, with: [0, 0, 0, 3])
        header.replaceSubrange(20..<24, with: [0, 0, 0, 16])
        header.replaceSubrange(36..<40, with: [0, 0, 0, 7])
        header.replaceSubrange(40..<48, with: [0, 0, 0, 0, 0, 1, 0, 0])
        try header.write(to: url)
        try DiskUtilities.resizeQCOW2(at: url, toGiB: 64)
        let result = try Data(contentsOf: url)
        XCTAssertEqual(Array(result[24..<32]), [0, 0, 0, 16, 0, 0, 0, 0])
        XCTAssertEqual(Array(result[36..<40]), [0, 0, 0, 128])
        XCTAssertNoThrow(try DiskUtilities.validateQCOW2Geometry(at: url))
    }

    func testQCOW2ResizeAgainstCachedOfficialImageWhenAvailable() throws {
        let source = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Sandfort/Cache/ubuntu-24.04-server-cloudimg-arm64-20260725.img")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Official image is not cached") }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".qcow2")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: source, to: copy)
        try DiskUtilities.resizeQCOW2(at: copy, toGiB: 64)
        XCTAssertNoThrow(try DiskUtilities.validateQCOW2Geometry(at: copy))
        let header = try Data(contentsOf: copy, options: .mappedIfSafe).prefix(48)
        XCTAssertEqual(Array(header[24..<32]), [0, 0, 0, 16, 0, 0, 0, 0])
        XCTAssertEqual(Array(header[36..<40]), [0, 0, 0, 128])
    }

    func testConfigurationUsesImmutableOfficialUbuntuRelease() {
        let configuration = SandfortConfiguration.current
        XCTAssertEqual(configuration.imageURL.host, "cloud-images.ubuntu.com")
        XCTAssertTrue(configuration.imageURL.path.contains("release-20260725"))
        XCTAssertEqual(configuration.imageSHA256.count, 64)
    }

    func testLegacySingleInstanceStateDecodesAsInstanceOne() throws {
        let legacy: [String: Any] = [
            "stage": "ready",
            "credentials": ["username": "sandbox", "password": "river-lantern-amber-willow"],
            "setupBundlePath": "/tmp/Legacy Baseline.utm",
            "sandboxBundlePath": "/tmp/Legacy Sandbox.utm",
            "setupVMName": "Sandbox Ubuntu Setup ABC123",
            "sandboxVMName": "Sandbox Ubuntu ABC123"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0)
        let state = try PropertyListDecoder().decode(SandboxState.self, from: data)
        XCTAssertNil(state.instances)
        XCTAssertEqual(state.resolvedInstances, [SandboxInstance(
            number: 1,
            bundlePath: "/tmp/Legacy Sandbox.utm",
            vmName: "Sandbox Ubuntu ABC123"
        )])
    }

    func testNamedInstanceKeepsItsPermanentNumberAndRoundTrips() throws {
        let instance = SandboxInstance(
            number: 3,
            bundlePath: "/tmp/Sandfort — Instance 3 — ABC123.utm",
            vmName: "Sandfort — Instance 3 — Interview Challenge — ABC123",
            label: "Interview Challenge"
        )
        XCTAssertEqual(instance.displayTitle, "Sandbox Instance 3 — Interview Challenge")
        let decoded = try PropertyListDecoder().decode(
            SandboxInstance.self,
            from: PropertyListEncoder().encode(instance)
        )
        XCTAssertEqual(decoded, instance)
        XCTAssertEqual(
            try SandboxInstance.normalizedLabel("  Interview\n   Challenge  "),
            "Interview Challenge"
        )
        XCTAssertThrowsError(try SandboxInstance.normalizedLabel(String(repeating: "x", count: 49)))
    }

    func testDeletedInstanceNumbersAreNotReused() {
        var state = SandboxState(
            stage: .ready,
            credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
            tools: .recommended,
            setupBundlePath: "/tmp/Baseline.utm",
            sandboxBundlePath: "/tmp/Instance 1.utm",
            setupVMName: "Sandfort — Protected Baseline ABC123",
            sandboxVMName: "Sandfort — Instance 1 — ABC123",
            instances: [
                SandboxInstance(number: 1, bundlePath: "/tmp/Instance 1.utm", vmName: "Instance 1"),
                SandboxInstance(number: 2, bundlePath: "/tmp/Instance 2.utm", vmName: "Instance 2")
            ],
            nextInstanceNumber: 3
        )
        state.replaceInstances(state.resolvedInstances.filter { $0.number != 2 })
        XCTAssertEqual(state.allocateInstanceNumber(), 3)
        state.replaceInstances([])
        XCTAssertEqual(state.allocateInstanceNumber(), 4)
    }

    func testRebuildCleanupIncludesBaselineAndEveryNumberedInstance() {
        let state = SandboxState(
            stage: .ready,
            credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
            tools: .recommended,
            setupBundlePath: "/tmp/Baseline.utm",
            sandboxBundlePath: "/tmp/Instance 1.utm",
            setupVMName: "Sandfort — Protected Baseline ABC123",
            sandboxVMName: "Sandfort — Instance 1 — ABC123",
            instances: [
                SandboxInstance(number: 1, bundlePath: "/tmp/Instance 1.utm", vmName: "Sandfort — Instance 1 — ABC123"),
                SandboxInstance(number: 2, bundlePath: "/tmp/Instance 2.utm", vmName: "Sandfort — Instance 2 — ABC123")
            ],
            nextInstanceNumber: 3
        )

        XCTAssertEqual(state.utmRegistrationNames, [
            "Sandfort — Protected Baseline ABC123",
            "Sandfort — Instance 1 — ABC123",
            "Sandfort — Instance 2 — ABC123"
        ])
    }

    func testUTMDeleteSpecifierTargetsOneVirtualMachineByExactName() {
        let name = "Sandfort — Instance 2 — ABC123"
        let specifier = UTMRegistryController.objectSpecifier(named: name)

        XCTAssertEqual(specifier.descriptorType, DescType(typeObjectSpecifier))
        XCTAssertEqual(
            specifier.paramDescriptor(forKeyword: AEKeyword(keyAEKeyData))?.stringValue,
            name
        )
        XCTAssertEqual(
            specifier.paramDescriptor(forKeyword: AEKeyword(keyAEKeyForm))?.enumCodeValue,
            OSType(formName)
        )
    }

    func testUTMBundlesEnforceHostIsolationAndCleanBaselineMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("source.img")
        var header = Data(repeating: 0, count: 128 * 1024)
        header.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])
        header.replaceSubrange(4..<8, with: [0, 0, 0, 3])
        header.replaceSubrange(20..<24, with: [0, 0, 0, 16])
        header.replaceSubrange(36..<40, with: [0, 0, 0, 7])
        header.replaceSubrange(40..<48, with: [0, 0, 0, 0, 0, 1, 0, 0])
        try header.write(to: image)
        let firmware = root.appendingPathComponent("firmware.fd")
        try Data(repeating: 0xa5, count: 4096).write(to: firmware)

        let setup = root.appendingPathComponent("Setup.utm", isDirectory: true)
        let clean = root.appendingPathComponent("Clean.utm", isDirectory: true)
        let clean2 = root.appendingPathComponent("Clean2.utm", isDirectory: true)
        let builder = UTMBundleBuilder(configuration: .current, firmwareURLOverride: firmware)
        try builder.createSetupBundle(
            at: setup,
            name: "Sandfort — Baseline Setup TEST01",
            from: image,
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: .recommended
        )
        try builder.createCleanBundle(
            from: setup,
            at: clean,
            name: "Sandfort — Instance 1 — TEST01",
            networkMode: .offline
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.appendingPathComponent("Data/efi_vars.fd").path))

        let setupPlistData = try Data(contentsOf: setup.appendingPathComponent("config.plist"))
        let setupPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: setupPlistData, format: nil) as? [String: Any])
        XCTAssertEqual((setupPlist["Information"] as? [String: Any])?["Name"] as? String, "Sandfort — Baseline Setup TEST01")
        XCTAssertEqual((setupPlist["Display"] as? [Any])?.count, 0)
        let setupSerial = try XCTUnwrap((setupPlist["Serial"] as? [[String: Any]])?.first)
        XCTAssertEqual(setupSerial["Mode"] as? String, "Terminal")
        XCTAssertEqual(setupSerial["Target"] as? String, "Auto")
        let setupQEMU = try XCTUnwrap(setupPlist["QEMU"] as? [String: Any])
        XCTAssertEqual(setupQEMU["DebugLog"] as? Bool, true)
        let setupDrives = try XCTUnwrap(setupPlist["Drive"] as? [[String: Any]])
        let seedDrive = try XCTUnwrap(setupDrives.first { $0["ImageName"] as? String == "seed.iso" })
        XCTAssertEqual(seedDrive["ImageType"] as? String, "Disk")
        XCTAssertEqual(seedDrive["Interface"] as? String, "VirtIO")
        XCTAssertEqual(seedDrive["ReadOnly"] as? Bool, true)
        XCTAssertNil(seedDrive["Removable"])
        let setupNetwork = try XCTUnwrap((setupPlist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual(setupNetwork["IsolateFromHost"] as? Bool, false)

        try builder.setDisplayName("Sandfort — Protected Baseline TEST01", at: setup)
        try builder.repairBundle(at: setup)
        let protectedPlistData = try Data(contentsOf: setup.appendingPathComponent("config.plist"))
        let protectedPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: protectedPlistData, format: nil) as? [String: Any])
        XCTAssertEqual(
            (protectedPlist["Information"] as? [String: Any])?["Name"] as? String,
            "Sandfort — Protected Baseline TEST01"
        )
        XCTAssertEqual((protectedPlist["Display"] as? [Any])?.count, 0)
        XCTAssertEqual((protectedPlist["Serial"] as? [Any])?.count, 1)
        let protectedNetwork = try XCTUnwrap((protectedPlist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual(protectedNetwork["IsolateFromHost"] as? Bool, true)

        let plistData = try Data(contentsOf: clean.appendingPathComponent("config.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual((plist["Information"] as? [String: Any])?["Name"] as? String, "Sandfort — Instance 1 — TEST01")
        XCTAssertNotNil(plist["Serial"] as? [Any])
        XCTAssertNotNil(plist["Sound"] as? [Any])
        let display = try XCTUnwrap((plist["Display"] as? [[String: Any]])?.first)
        XCTAssertEqual(display["Hardware"] as? String, "virtio-gpu-pci")
        XCTAssertEqual((plist["Serial"] as? [Any])?.count, 0)
        let qemu = try XCTUnwrap(plist["QEMU"] as? [String: Any])
        XCTAssertEqual(qemu["AdditionalArguments"] as? [String], [])
        XCTAssertEqual(qemu["DebugLog"] as? Bool, true)
        let sharing = try XCTUnwrap(plist["Sharing"] as? [String: Any])
        XCTAssertEqual(sharing["DirectoryShareMode"] as? String, "None")
        XCTAssertEqual(sharing["ClipboardSharing"] as? Bool, false)
        let network = try XCTUnwrap((plist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual(network["IsolateFromHost"] as? Bool, true)
        XCTAssertEqual(network["PortForward"] as? [String], [])
        let input = try XCTUnwrap(plist["Input"] as? [String: Any])
        XCTAssertEqual(input["UsbSharing"] as? Bool, false)

        try builder.createCleanBundle(
            from: setup,
            at: clean2,
            name: "Sandfort — Instance 2 — TEST01",
            networkMode: .offline
        )
        let secondPlistData = try Data(contentsOf: clean2.appendingPathComponent("config.plist"))
        let secondPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: secondPlistData, format: nil) as? [String: Any])
        XCTAssertNotEqual(
            (plist["Information"] as? [String: Any])?["UUID"] as? String,
            (secondPlist["Information"] as? [String: Any])?["UUID"] as? String
        )
        XCTAssertNotEqual(
            ((plist["Network"] as? [[String: Any]])?.first)?["MacAddress"] as? String,
            ((secondPlist["Network"] as? [[String: Any]])?.first)?["MacAddress"] as? String
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: clean2.appendingPathComponent("Data/sandfort.qcow2").path))

        try builder.resetCleanBundle(from: setup, at: clean, networkMode: .internet)
        let internetPlistData = try Data(contentsOf: clean.appendingPathComponent("config.plist"))
        let internetPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: internetPlistData, format: nil) as? [String: Any])
        let internetNetwork = try XCTUnwrap((internetPlist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual(internetNetwork["IsolateFromHost"] as? Bool, false)
        XCTAssertEqual(internetNetwork["PortForward"] as? [String], [])

        try builder.repairBundle(at: clean)
        let resumedPlistData = try Data(contentsOf: clean.appendingPathComponent("config.plist"))
        let resumedPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: resumedPlistData, format: nil) as? [String: Any])
        let resumedNetwork = try XCTUnwrap((resumedPlist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual(resumedNetwork["IsolateFromHost"] as? Bool, false)
        XCTAssertEqual(resumedNetwork["PortForward"] as? [String], [])

        try builder.setDisplayName("Sandfort — Instance 1 — Interview Challenge — TEST01", at: clean)
        let renamedPlistData = try Data(contentsOf: clean.appendingPathComponent("config.plist"))
        let renamedPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: renamedPlistData, format: nil) as? [String: Any])
        XCTAssertEqual(
            (renamedPlist["Information"] as? [String: Any])?["Name"] as? String,
            "Sandfort — Instance 1 — Interview Challenge — TEST01"
        )
        XCTAssertEqual(
            (renamedPlist["Information"] as? [String: Any])?["UUID"] as? String,
            (resumedPlist["Information"] as? [String: Any])?["UUID"] as? String
        )

        try builder.resetCleanBundle(from: setup, at: clean, networkMode: .offline)
        let offlinePlistData = try Data(contentsOf: clean.appendingPathComponent("config.plist"))
        let offlinePlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: offlinePlistData, format: nil) as? [String: Any])
        let offlineNetwork = try XCTUnwrap((offlinePlist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual(offlineNetwork["IsolateFromHost"] as? Bool, true)
    }

    private func decodedFinalizer(from iso: Data) throws -> String {
        let isoText = String(decoding: iso, as: UTF8.self)
        let section = try XCTUnwrap(isoText.range(of: "- path: /var/lib/sandfort/baseline-finalize.sh"))
        let tail = isoText[section.lowerBound...]
        let contentLine = try XCTUnwrap(tail.split(separator: "\n").first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("content: ")
        })
        let encoded = contentLine.trimmingCharacters(in: .whitespaces).dropFirst("content: ".count)
        return String(decoding: try XCTUnwrap(Data(base64Encoded: String(encoded))), as: UTF8.self)
    }
}
