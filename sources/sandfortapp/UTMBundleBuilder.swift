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

struct UTMBundleBuilder: VirtualMachineProvider {
    var firmwareURLOverride: URL? = nil
    var identifier: String { "macos-arm64.utm-qemu" }

    func createSetupBundle(at bundleURL: URL, name: String, from imageURL: URL, profile: LinuxGuestProfile, credentials: SandboxCredentials, tools: SandboxToolSelection) throws {
        let fileManager = FileManager.default
        let dataURL = bundleURL.appendingPathComponent("Data", isDirectory: true)
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)

        let diskName = "sandfort.qcow2"
        let diskURL = dataURL.appendingPathComponent(diskName)
        try fileManager.copyItem(at: imageURL, to: diskURL)
        try DiskUtilities.resizeQCOW2(at: diskURL, toGiB: profile.hardware.diskSizeGiB)
        guard let firmwareURL = firmwareURLOverride ?? Self.utmFirmwareURL() else {
            throw SandboxError.utmResourcesMissing
        }
        try fileManager.copyItem(at: firmwareURL, to: dataURL.appendingPathComponent("efi_vars.fd"))
        try profile.seedISO(credentials: credentials, tools: tools).write(
            to: dataURL.appendingPathComponent("seed.iso"),
            options: .atomic
        )
        try writeConfiguration(
            at: bundleURL,
            name: name,
            diskName: diskName,
            profile: profile,
            setupMode: true
        )
    }

    func createCleanBundle(
        from setupURL: URL,
        at destinationURL: URL,
        name: String,
        profile: LinuxGuestProfile,
        networkMode: SandboxNetworkMode
    ) throws {
        let fileManager = FileManager.default
        try DiskUtilities.ensureNotInUse(try diskURL(in: setupURL))
        try fileManager.copyItem(at: setupURL, to: destinationURL)
        let diskName = try diskName(in: destinationURL)
        try writeConfiguration(
            at: destinationURL,
            name: name,
            diskName: diskName,
            profile: profile,
            setupMode: false
        )
        try setCleanNetworkMode(networkMode, at: destinationURL)
    }

    func resetCleanBundle(from setupURL: URL, at destinationURL: URL, profile: LinuxGuestProfile, networkMode: SandboxNetworkMode) throws {
        let fileManager = FileManager.default
        try DiskUtilities.ensureNotInUse(try diskURL(in: setupURL))
        try DiskUtilities.ensureNotInUse(try diskURL(in: destinationURL))
        let sourceData = setupURL.appendingPathComponent("Data", isDirectory: true)
        let destinationData = destinationURL.appendingPathComponent("Data", isDirectory: true)
        let replacements = [
            (try diskURL(in: setupURL), try diskURL(in: destinationURL)),
            (sourceData.appendingPathComponent("efi_vars.fd"), destinationData.appendingPathComponent("efi_vars.fd"))
        ]
        for (source, destination) in replacements {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        try repairBundle(at: destinationURL, profile: profile, role: .cleanInstance)
        try setCleanNetworkMode(networkMode, at: destinationURL)
    }

    func repairBundle(at bundleURL: URL, profile: LinuxGuestProfile, role: VirtualMachineRole) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let data = try Data(contentsOf: configURL)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SandboxError.invalidCloudDisk("the UTM configuration is not a property-list dictionary")
        }
        plist["Serial"] = plist["Serial"] ?? []
        plist["Sound"] = plist["Sound"] ?? []
        // Role comes from the caller. It used to be read out of
        // Information.Name by matching "Baseline Setup" and "Protected
        // Baseline" — but that name embeds the user's instance label, so
        // renaming an instance "Baseline Setup" reclassified it as the
        // provisioning VM and cleared IsolateFromHost on the next state read.
        let isSetup = role == .setup
        let isProtectedBaseline = role == .protectedBaseline
        let isBaseline = isSetup || isProtectedBaseline
        plist["Display"] = isBaseline ? [] : [displayConfiguration]
        plist["Serial"] = isBaseline ? [serialTerminalConfiguration] : []
        if var networks = plist["Network"] as? [[String: Any]] {
            for index in networks.indices {
                // Provisioning needs Internet and the protected baseline must
                // stay offline. Instances preserve their last explicit mode so
                // Resume does not silently alter a saved session.
                if isSetup {
                    networks[index]["IsolateFromHost"] = false
                } else if isProtectedBaseline {
                    networks[index]["IsolateFromHost"] = true
                }
                networks[index]["PortForward"] = []
            }
            plist["Network"] = networks
        }
        if var drives = plist["Drive"] as? [[String: Any]] {
            for index in drives.indices {
                drives[index].removeValue(forKey: "Removable")
                if drives[index]["ImageName"] as? String == "seed.iso" {
                    // USB media may appear after cloud-init searches for NoCloud data.
                    // VirtIO exposes this CIDATA ISO as a block device during early boot.
                    drives[index]["ImageType"] = "Disk"
                    drives[index]["Interface"] = "VirtIO"
                    drives[index]["InterfaceVersion"] = 1
                    drives[index]["ReadOnly"] = true
                }
            }
            plist["Drive"] = drives
        }
        if var qemu = plist["QEMU"] as? [String: Any] {
            qemu["AdditionalArguments"] = []
            qemu["DebugLog"] = true
            plist["QEMU"] = qemu
        }
        // Isolation has to be reasserted here, not only written once at
        // creation. UTM's own settings UI can turn clipboard sharing, a shared
        // host directory, or USB passthrough on for any VM in its library, and
        // nothing else puts them back — so an instance kept them across Resume
        // while the app went on claiming the opposite.
        //
        // Merged rather than replaced, so a key UTM adds in a later version
        // survives while the ones this app makes promises about do not drift.
        var sharing = plist["Sharing"] as? [String: Any] ?? [:]
        sharing["ClipboardSharing"] = false
        sharing["DirectoryShareMode"] = "None"
        sharing["DirectoryShareReadOnly"] = true
        plist["Sharing"] = sharing

        var input = plist["Input"] as? [String: Any] ?? [:]
        input["UsbSharing"] = false
        input["MaximumUsbShare"] = 0
        input["UsbBusSupport"] = input["UsbBusSupport"] ?? "3.0"
        plist["Input"] = input
        let repaired = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try repaired.write(to: configURL, options: .atomic)
        if let disk = try? diskURL(in: bundleURL),
           (try? DiskUtilities.ensureNotInUse(disk)) != nil {
            try DiskUtilities.resizeQCOW2(at: disk, toGiB: profile.hardware.diskSizeGiB)
        }
    }

    func setDisplayName(_ name: String, at bundleURL: URL) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        let data = try Data(contentsOf: configURL)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SandboxError.invalidCloudDisk("the UTM configuration is not a property-list dictionary")
        }
        var information = plist["Information"] as? [String: Any] ?? [:]
        information["Name"] = name
        plist["Information"] = information
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: configURL, options: .atomic)
    }

    func ensureBundleNotRunning(at bundleURL: URL) throws {
        try DiskUtilities.ensureNotInUse(try diskURL(in: bundleURL))
    }

    private func diskName(in bundleURL: URL) throws -> String {
        let dataURL = bundleURL.appendingPathComponent("Data", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "qcow2" })?.lastPathComponent ?? "sandfort.qcow2"
    }

    private func diskURL(in bundleURL: URL) throws -> URL {
        let dataURL = bundleURL.appendingPathComponent("Data", isDirectory: true)
        guard let disk = try FileManager.default.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "qcow2" }) else {
            throw SandboxError.invalidCloudDisk("the UTM bundle has no QCOW2 disk")
        }
        return disk
    }

    private func writeConfiguration(at bundleURL: URL, name: String, diskName: String, profile: LinuxGuestProfile, setupMode: Bool) throws {
        let machineID = UUID().uuidString.uppercased()
        let diskID = UUID().uuidString.uppercased()
        let seedID = UUID().uuidString.uppercased()
        let plist: [String: Any] = [
            "Backend": "QEMU",
            "ConfigurationVersion": 4,
            "Information": [
                "IconCustom": false,
                "Name": name,
                "UUID": machineID
            ],
            "System": [
                "Architecture": profile.hardware.utmArchitecture,
                "CPU": "default",
                "CPUCount": profile.hardware.cpuCount,
                "CPUFlagsAdd": [],
                "CPUFlagsRemove": [],
                "ForceMulticore": false,
                "JITCacheSize": 0,
                "MemorySize": profile.hardware.memoryMiB,
                "Target": profile.hardware.utmTarget
            ],
            "QEMU": [
                "AdditionalArguments": [],
                "BalloonDevice": true,
                "DebugLog": true,
                "Hypervisor": true,
                "PS2Controller": false,
                "RNGDevice": true,
                "RTCLocalTime": false,
                "TPMDevice": false,
                "TSO": false,
                "UEFIBoot": true
            ],
            "Display": setupMode ? [] : [displayConfiguration],
            "Drive": [[
                "Identifier": diskID,
                "ImageName": diskName,
                "ImageType": "Disk",
                "Interface": "VirtIO",
                "InterfaceVersion": 1,
                "ReadOnly": false
            ], [
                "Identifier": seedID,
                "ImageName": "seed.iso",
                "ImageType": "Disk",
                "Interface": "VirtIO",
                "InterfaceVersion": 1,
                "ReadOnly": true
            ]],
            "Input": [
                "MaximumUsbShare": 0,
                "UsbBusSupport": "3.0",
                "UsbSharing": false
            ],
            "Network": [[
                "Hardware": "virtio-net-pci",
                "IsolateFromHost": !setupMode,
                "MacAddress": randomMACAddress(),
                "Mode": "Emulated",
                "PortForward": []
            ]],
            "Sharing": [
                "ClipboardSharing": false,
                "DirectoryShareMode": "None",
                "DirectoryShareReadOnly": true
            ],
            "Serial": setupMode ? [serialTerminalConfiguration] : [],
            "Sound": []
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundleURL.appendingPathComponent("config.plist"), options: .atomic)
    }

    private func setCleanNetworkMode(_ mode: SandboxNetworkMode, at bundleURL: URL) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        let data = try Data(contentsOf: configURL)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SandboxError.invalidCloudDisk("the UTM configuration is not a property-list dictionary")
        }
        guard var networks = plist["Network"] as? [[String: Any]], !networks.isEmpty else {
            throw SandboxError.invalidCloudDisk("the clean UTM configuration has no network device")
        }
        for index in networks.indices {
            networks[index]["IsolateFromHost"] = mode == .offline
            networks[index]["PortForward"] = []
        }
        plist["Network"] = networks
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: configURL, options: .atomic)
    }

    private func randomMACAddress() -> String {
        let bytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
        return ([0x52, 0x54, 0x00] + bytes).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private var displayConfiguration: [String: Any] {
        [
            "DownscalingFilter": "Linear",
            "DynamicResolution": true,
            "Hardware": "virtio-gpu-pci",
            "NativeResolution": false,
            "UpscalingFilter": "Nearest"
        ]
    }

    private var serialTerminalConfiguration: [String: Any] {
        [
            "Mode": "Terminal",
            "Target": "Auto",
            "Terminal": [
                "BackgroundColor": "#000000",
                "CursorBlink": true,
                "Font": "Menlo",
                "FontSize": 12,
                "ForegroundColor": "#ffffff"
            ]
        ]
    }

    /// Derived from wherever UTM was actually resolved, so this and the install
    /// check can never disagree. They could before: both repeated the same two
    /// hardcoded paths, and a UTM installed elsewhere produced a misleading
    /// "reinstall UTM" error about a perfectly good installation.
    ///
    /// Called from the workflow actor, never the main actor, so the resolver it
    /// uses has to be callable from anywhere. Reaching a main-actor-isolated
    /// resolver from here through `MainActor.assumeIsolated` compiled and passed
    /// tests, then trapped at runtime on every baseline creation: it asserts the
    /// current executor rather than hopping to it.
    private static func utmFirmwareURL() -> URL? {
        guard let firmware = UTMLauncher.installation?.firmwareURL,
              FileManager.default.fileExists(atPath: firmware.path) else { return nil }
        return firmware
    }
}
