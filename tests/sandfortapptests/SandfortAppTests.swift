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
import XCTest
@testable import SandfortApp

final class SandfortAppTests: XCTestCase {
    func testGeneratedCredentialsUseAMemorableHyphenatedPhrase() {
        let credentials = LinuxGuestCatalog.defaultProfile.credentials()
        let parts = credentials.password.split(separator: "-")
        XCTAssertEqual(credentials.username, "sandfort")
        XCTAssertEqual(parts.count, 4)
        XCTAssertTrue(parts.allSatisfy { $0.allSatisfy(\.isLowercase) })
    }

    func testSharedGuestProvisioningSupportPreservesCommonSecurityInputs() throws {
        XCTAssertEqual(GuestProvisioningSupport.yamlSingleQuoted("safe'phrase"), "safe''phrase")
        XCTAssertEqual(GuestProvisioningSupport.completionMarkerPath, "/var/lib/sandfort/setup-complete")
        XCTAssertTrue(GuestProvisioningSupport.motd.contains("Do not enter personal credentials"))

        let custom = try XCTUnwrap(GuestProvisioningSupport.customSetupScript(
            from: "  #!/bin/sh\necho ready  \n"
        ))
        XCTAssertEqual(custom.command, "/var/lib/sandfort/custom-setup.sh")
        XCTAssertTrue(custom.writeFileEntry.contains(Data("#!/bin/sh\necho ready".utf8).base64EncodedString()))
        XCTAssertNil(try GuestProvisioningSupport.customSetupScript(from: " \n "))

        let node = GuestProvisioningSupport.nodeLTSInstallCommands(
            enabled: true,
            linuxArchiveArchitecture: "arm64"
        )
        XCTAssertTrue(node.contains("node-${nodeVersion}-linux-arm64.tar.xz"))
        XCTAssertTrue(node.contains("sha256sum --check"))
        XCTAssertEqual(
            GuestProvisioningSupport.nodeLTSInstallCommands(
                enabled: false,
                linuxArchiveArchitecture: "arm64"
            ),
            ""
        )
    }

    func testCloudInitISOHasCIDATAVolumeAndExpectedFiles() throws {
        let credentials = SandboxCredentials(username: "sandfort", password: "safe-test")
        let iso = try LinuxGuestCatalog.defaultProfile.seedISO(credentials: credentials)
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
        let iso = try LinuxGuestCatalog.defaultProfile.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(python: false, nodeJS: false)
        )
        XCTAssertNotNil(iso.range(of: Data("#   - git".utf8)))
        XCTAssertNotNil(iso.range(of: Data("#   - curl".utf8)))
        XCTAssertNil(iso.range(of: Data("#   - python3-pip".utf8)))
        XCTAssertNil(iso.range(of: Data("#   - nodejs".utf8)))
    }

    func testCustomGuestPasswordIsValidatedAndSafelyQuoted() throws {
        let credentials = try LinuxGuestCatalog.defaultProfile.credentials(password: "safe'phrase-123")
        XCTAssertEqual(credentials.password, "safe'phrase-123")
        let iso = try LinuxGuestCatalog.defaultProfile.seedISO(credentials: credentials)
        XCTAssertNotNil(iso.range(of: Data("password: 'safe''phrase-123'".utf8)))
        XCTAssertThrowsError(try LinuxGuestCatalog.defaultProfile.credentials(password: "short"))
        XCTAssertThrowsError(try LinuxGuestCatalog.defaultProfile.credentials(password: "contains space"))
        XCTAssertThrowsError(try LinuxGuestCatalog.defaultProfile.credentials(password: "contains\nnewline"))
        XCTAssertThrowsError(try LinuxGuestCatalog.defaultProfile.credentials(password: String(repeating: "x", count: 129)))
    }

    func testCloudInitCanMirrorDetailedSetupOutputToTerminal() throws {
        let iso = try LinuxGuestCatalog.defaultProfile.seedISO(
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
        let iso = try LinuxGuestCatalog.defaultProfile.seedISO(
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
        XCTAssertThrowsError(try LinuxGuestCatalog.defaultProfile.seedISO(
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

    func testLinuxGuestCatalogContainsTheCuratedProductionProfiles() throws {
        XCTAssertEqual(
            LinuxGuestCatalog.profiles.map(\.id),
            [
                "ubuntu-24.04-arm64", "fedora-44-arm64", "debian-13-arm64",
                "opensuse-leap-16.0-arm64"
            ]
        )
        XCTAssertEqual(LinuxGuestCatalog.profile(id: "ubuntu-24.04-arm64"), LinuxGuestCatalog.defaultProfile)
        XCTAssertNil(LinuxGuestCatalog.profile(id: "arbitrary-linux"))

        let profile = LinuxGuestCatalog.defaultProfile
        XCTAssertEqual(profile.displayName, "Ubuntu 24.04 LTS")
        XCTAssertEqual(profile.revision, 4)
        XCTAssertEqual(profile.setupDurationDescription, "10-30 minutes")
        XCTAssertEqual(profile.distributionName, "Ubuntu")
        XCTAssertEqual(profile.hardware.architecture, "arm64")
        XCTAssertEqual(profile.hardware.utmArchitecture, "aarch64")
        XCTAssertEqual(profile.hardware.utmTarget, "virt")
        XCTAssertEqual(profile.hardware.memoryMiB, 4096)
        XCTAssertEqual(profile.hardware.cpuCount, 4)
        XCTAssertEqual(profile.hardware.diskSizeGiB, 64)
        XCTAssertEqual(profile.image.url.host, "cloud-images.ubuntu.com")
        XCTAssertTrue(profile.image.url.path.contains("release-20260725"))
        XCTAssertEqual(profile.image.sha256.count, 64)

        let iso = try profile.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(python: false, nodeJS: false)
        )
        let finalizer = try decodedFinalizer(from: iso)
        XCTAssertTrue(finalizer.contains("apt-get update"))
        XCTAssertTrue(finalizer.contains("apt-get install -y ubuntu-desktop-minimal"))
        XCTAssertTrue(finalizer.contains("systemctl enable gdm3.service"))
        // Instances have a display and no serial device, so a VT1 getty would
        // show a text login prompt before the greeter and read as the only way in.
        XCTAssertTrue(finalizer.contains("systemctl mask getty@tty1.service"))
        XCTAssertTrue(finalizer.contains("systemctl is-enabled getty@tty1.service"))
        // The rescue console on Ctrl+Alt+F2 must survive.
        XCTAssertFalse(finalizer.contains("systemctl mask getty@.service"))
        XCTAssertFalse(finalizer.contains("mask autovt@"))
    }

    func testFedora44ProductionProfileHasImmutableVerifiedMetadata() throws {
        let fedora = LinuxGuestCatalog.fedora44ARM64
        XCTAssertEqual(fedora.id, "fedora-44-arm64")
        XCTAssertEqual(fedora.revision, 4)
        XCTAssertEqual(fedora.displayName, "Fedora Cloud 44")
        XCTAssertEqual(fedora.distributionName, "Fedora")
        XCTAssertEqual(fedora.setupDurationDescription, "20-45 minutes")
        XCTAssertEqual(fedora.provisioner, .fedora44)
        XCTAssertEqual(fedora.image.url.scheme, "https")
        XCTAssertEqual(fedora.image.url.host, "download.fedoraproject.org")
        XCTAssertTrue(fedora.image.url.path.contains("/releases/44/"))
        XCTAssertTrue(fedora.image.url.path.contains("Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2"))
        XCTAssertFalse(fedora.image.url.absoluteString.lowercased().contains("latest"))
        XCTAssertEqual(fedora.image.sha256, "55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b")
        XCTAssertEqual(fedora.image.sha256.count, 64)
        XCTAssertTrue(fedora.image.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(fedora.image.fileName, "Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2")
        XCTAssertEqual(fedora.hardware.architecture, "arm64")
        XCTAssertEqual(fedora.hardware.utmArchitecture, "aarch64")
        XCTAssertEqual(fedora.hardware.utmTarget, "virt")
        XCTAssertEqual(fedora.hardware.memoryMiB, 4096)
        XCTAssertEqual(fedora.hardware.cpuCount, 4)
        XCTAssertEqual(fedora.hardware.diskSizeGiB, 64)

        XCTAssertEqual(LinuxGuestCatalog.qualificationProfiles, [])
        XCTAssertTrue(LinuxGuestCatalog.profiles.contains(fedora))
        XCTAssertTrue(LinuxGuestCatalog.supportedProfiles.contains(fedora))
        XCTAssertEqual(LinuxGuestCatalog.profile(id: fedora.id), fedora)
        XCTAssertEqual(LinuxGuestCatalog.supportedProfile(
            id: fedora.id,
            revision: fedora.revision,
            imageSHA256: fedora.image.sha256
        ), fedora)
        let iso = try fedora.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: .recommended
        )
        XCTAssertNotNil(iso.range(of: Data("Fedora baseline setup has started".utf8)))
    }

    func testDebian13ProductionProfileHasImmutableVerifiedMetadata() throws {
        let debian = LinuxGuestCatalog.debian13ARM64
        XCTAssertEqual(debian.id, "debian-13-arm64")
        XCTAssertEqual(debian.revision, 7)
        XCTAssertEqual(debian.displayName, "Debian 13 (Trixie)")
        XCTAssertEqual(debian.distributionName, "Debian")
        XCTAssertEqual(debian.setupDurationDescription, "20-45 minutes")
        XCTAssertEqual(debian.provisioner, .debian13)
        XCTAssertEqual(debian.image.url.scheme, "https")
        XCTAssertEqual(debian.image.url.host, "cloud.debian.org")
        XCTAssertTrue(debian.image.url.path.contains("/trixie/20260712-2537/"))
        XCTAssertTrue(debian.image.url.path.hasSuffix("debian-13-generic-arm64-20260712-2537.qcow2"))
        XCTAssertFalse(debian.image.url.absoluteString.lowercased().contains("latest"))
        XCTAssertEqual(debian.image.sha256, "7e556159a995fa4634e2ea52228ec7a4226193e2d1a87e2c7158e4c6d53ed5fe")
        XCTAssertEqual(debian.image.fileName, "debian-13-generic-arm64-20260712-2537.qcow2")
        XCTAssertEqual(debian.hardware.memoryMiB, 4096)
        XCTAssertEqual(debian.hardware.cpuCount, 4)
        XCTAssertEqual(debian.hardware.diskSizeGiB, 64)

        XCTAssertEqual(LinuxGuestCatalog.qualificationProfiles, [])
        XCTAssertTrue(LinuxGuestCatalog.profiles.contains(debian))
        XCTAssertTrue(LinuxGuestCatalog.supportedProfiles.contains(debian))
        XCTAssertEqual(LinuxGuestCatalog.profile(id: debian.id), debian)
        XCTAssertEqual(LinuxGuestCatalog.qualificationProfile(id: debian.id), debian)
        let iso = try debian.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: .recommended
        )
        XCTAssertNotNil(iso.range(of: Data("Debian baseline setup has started".utf8)))
    }

    func testOpenSUSELeap16ProductionProfileHasImmutableVerifiedMetadata() throws {
        let opensuse = LinuxGuestCatalog.opensuseLeap16ARM64
        XCTAssertEqual(opensuse.id, "opensuse-leap-16.0-arm64")
        XCTAssertEqual(opensuse.revision, 8)
        XCTAssertEqual(opensuse.displayName, "openSUSE Leap 16.0")
        XCTAssertEqual(opensuse.distributionName, "openSUSE")
        XCTAssertEqual(opensuse.setupDurationDescription, "20-45 minutes")
        XCTAssertEqual(opensuse.provisioner, .opensuseLeap16)
        XCTAssertEqual(opensuse.image.url.scheme, "https")
        XCTAssertEqual(opensuse.image.url.host, "download.opensuse.org")
        XCTAssertTrue(opensuse.image.url.path.contains("/distribution/leap/16.0/appliances/"))
        XCTAssertTrue(opensuse.image.url.path.hasSuffix("Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2"))
        XCTAssertFalse(opensuse.image.url.absoluteString.lowercased().contains("current"))
        XCTAssertFalse(opensuse.image.url.absoluteString.lowercased().contains("latest"))
        XCTAssertEqual(opensuse.image.sha256, "2e9eeb56e7523775f1f01261f4900f289e20c38910226b0c1e5aa7228a84194a")
        XCTAssertEqual(opensuse.image.fileName, "Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2")
        XCTAssertEqual(opensuse.hardware.memoryMiB, 4096)
        XCTAssertEqual(opensuse.hardware.cpuCount, 4)
        XCTAssertEqual(opensuse.hardware.diskSizeGiB, 64)

        XCTAssertEqual(LinuxGuestCatalog.qualificationProfiles, [])
        XCTAssertTrue(LinuxGuestCatalog.profiles.contains(opensuse))
        XCTAssertTrue(LinuxGuestCatalog.supportedProfiles.contains(opensuse))
        XCTAssertEqual(LinuxGuestCatalog.profile(id: opensuse.id), opensuse)
        XCTAssertEqual(LinuxGuestCatalog.qualificationProfile(id: opensuse.id), opensuse)
        let iso = try opensuse.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: .recommended
        )
        XCTAssertNotNil(iso.range(of: Data("openSUSE baseline setup has started".utf8)))
    }

    func testSandboxLibraryPreservesLegacyEnvironmentAndIsolatesOtherProfiles() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let library = SandboxLibrary(applicationSupportURL: support)
        let ubuntu = LinuxGuestCatalog.ubuntu2404ARM64
        let fedora = LinuxGuestCatalog.fedora44ARM64
        let debian = LinuxGuestCatalog.debian13ARM64

        XCTAssertEqual(
            library.location(for: ubuntu).rootURL,
            library.rootURL.appendingPathComponent("Environments/\(ubuntu.id)", isDirectory: true)
        )
        XCTAssertEqual(library.cacheURL, library.rootURL.appendingPathComponent("Cache", isDirectory: true))

        try FileManager.default.createDirectory(at: library.rootURL, withIntermediateDirectories: true)
        let legacyState = SandboxState(
            stage: .ready,
            credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
            tools: .recommended,
            setupBundlePath: "/tmp/Legacy Ubuntu.utm",
            sandboxBundlePath: "/tmp/Legacy Instance.utm",
            guestProfileID: ubuntu.id,
            guestProfileRevision: ubuntu.revision,
            guestImageSHA256: ubuntu.image.sha256
        )
        try PropertyListEncoder().encode(legacyState).write(
            to: library.rootURL.appendingPathComponent("state.plist"),
            options: .atomic
        )

        let ubuntuLocation = library.location(for: ubuntu)
        let fedoraLocation = library.location(for: fedora)
        let debianLocation = library.location(for: debian)
        XCTAssertEqual(ubuntuLocation.rootURL, library.rootURL)
        XCTAssertTrue(ubuntuLocation.usesLegacyRoot)
        XCTAssertEqual(
            fedoraLocation.rootURL,
            library.rootURL.appendingPathComponent("Environments/\(fedora.id)", isDirectory: true)
        )
        XCTAssertFalse(fedoraLocation.usesLegacyRoot)
        XCTAssertEqual(
            debianLocation.rootURL,
            library.rootURL.appendingPathComponent("Environments/\(debian.id)", isDirectory: true)
        )
        XCTAssertFalse(debianLocation.usesLegacyRoot)
        XCTAssertEqual(
            SandfortWorkflowEnvironment.productionWorkspace(
                profile: fedora,
                rootURL: fedoraLocation.rootURL,
                cacheURL: library.cacheURL
            ).vmNamePrefix,
            "Sandfort — Fedora Cloud 44"
        )
        XCTAssertEqual(library.existingLocations(in: LinuxGuestCatalog.profiles), [ubuntuLocation])

        try FileManager.default.createDirectory(at: fedoraLocation.rootURL, withIntermediateDirectories: true)
        var fedoraState = legacyState
        fedoraState.guestProfileID = fedora.id
        fedoraState.guestProfileRevision = fedora.revision
        fedoraState.guestImageSHA256 = fedora.image.sha256
        try PropertyListEncoder().encode(fedoraState).write(to: fedoraLocation.stateURL, options: .atomic)
        XCTAssertEqual(
            library.existingLocations(in: LinuxGuestCatalog.profiles),
            [ubuntuLocation, fedoraLocation]
        )
    }

    func testFedoraCloudInitEnforcesDistributionSpecificProvisioningAndSecurity() throws {
        let credentials = SandboxCredentials(username: "sandfort", password: "safe'fedora-phrase")
        let iso = try FedoraCloudInit.seedISO(
            credentials: credentials,
            tools: .recommended,
            hardware: LinuxGuestCatalog.fedora44ARM64.hardware
        )
        let isoText = String(decoding: iso, as: UTF8.self)
        let finalizer = try decodedFinalizer(from: iso)

        XCTAssertTrue(isoText.contains("groups: [wheel]"))
        XCTAssertTrue(isoText.contains("password: 'safe''fedora-phrase'"))
        XCTAssertTrue(isoText.contains("PasswordAuthentication no"))
        XCTAssertTrue(isoText.contains("PermitRootLogin no"))
        XCTAssertTrue(isoText.contains("AllowTcpForwarding no"))
        XCTAssertTrue(isoText.contains("<zone target=\"DROP\">"))
        XCTAssertTrue(isoText.contains("upgrade_type = security"))
        XCTAssertTrue(isoText.contains("apply_updates = true"))
        XCTAssertTrue(isoText.contains("reboot = never"))
        XCTAssertTrue(isoText.contains("mode: poweroff"))
        XCTAssertTrue(isoText.contains("condition: [test, -f, /var/lib/sandfort/setup-complete]"))

        XCTAssertTrue(finalizer.contains("for attempt in 1 2 3"))
        XCTAssertTrue(finalizer.contains("dnf5 -y upgrade --refresh"))
        XCTAssertTrue(finalizer.contains("dnf5 -y environment install workstation-product-environment"))
        XCTAssertTrue(finalizer.contains("dnf5 environment info workstation-product-environment"))
        XCTAssertTrue(finalizer.contains("rpm -q gnome-shell"))
        XCTAssertTrue(finalizer.contains("rpm -q qemu-guest-agent"))
        XCTAssertTrue(finalizer.contains("rpm -q spice-vdagent"))
        XCTAssertTrue(finalizer.contains("systemctl mask sshd.service sshd.socket"))
        XCTAssertTrue(finalizer.contains("systemctl is-active --quiet sshd.service"))
        XCTAssertTrue(finalizer.contains("systemctl enable --now firewalld.service"))
        XCTAssertTrue(finalizer.contains("firewall-cmd --set-default-zone=sandfort"))
        XCTAssertTrue(finalizer.contains("firewall-cmd --zone=sandfort --query-service=ssh"))
        XCTAssertTrue(finalizer.contains("test \"$(getenforce)\" = Enforcing"))
        XCTAssertTrue(finalizer.contains("systemctl enable dnf5-automatic.timer"))
        XCTAssertTrue(finalizer.contains("systemctl mask getty@tty1.service"))
        XCTAssertTrue(finalizer.contains("systemctl is-enabled getty@tty1.service"))
        XCTAssertFalse(finalizer.contains("mask autovt@"))
        XCTAssertTrue(finalizer.contains("systemctl enable gdm.service"))
        XCTAssertTrue(finalizer.contains("systemctl enable qemu-guest-agent.service"))
        XCTAssertTrue(finalizer.contains("systemctl enable NetworkManager.service"))
        XCTAssertTrue(finalizer.contains("https://nodejs.org/dist/index.json"))
        XCTAssertTrue(finalizer.contains("linux-arm64.tar.xz"))
        XCTAssertTrue(finalizer.contains("sha256sum --check"))
        XCTAssertTrue(finalizer.contains("command -v python3"))
        XCTAssertTrue(finalizer.contains("python3 -m venv --help"))
        XCTAssertTrue(finalizer.contains("systemctl unmask --runtime serial-getty@ttyAMA0.service"))
        XCTAssertTrue(finalizer.contains("touch /var/lib/sandfort/setup-complete"))
        XCTAssertFalse(finalizer.contains("apt-get"))
        XCTAssertFalse(finalizer.contains("dpkg-query"))
        XCTAssertFalse(finalizer.contains("ufw "))
        XCTAssertFalse(isoText.lowercased().contains("selinux=0"))
        XCTAssertFalse(isoText.lowercased().contains("setenforce 0"))
    }

    func testOpenSUSECloudInitEnforcesDistributionSpecificProvisioningAndSecurity() throws {
        let credentials = SandboxCredentials(username: "sandfort", password: "safe'opensuse-phrase")
        let iso = try OpenSUSECloudInit.seedISO(
            credentials: credentials,
            tools: .recommended,
            hardware: LinuxGuestCatalog.opensuseLeap16ARM64.hardware
        )
        let isoText = String(decoding: iso, as: UTF8.self)
        let finalizer = try decodedFinalizer(from: iso)

        XCTAssertTrue(isoText.contains("groups: [wheel]"))
        XCTAssertTrue(isoText.contains("password: 'safe''opensuse-phrase'"))
        XCTAssertTrue(isoText.contains("PasswordAuthentication no"))
        XCTAssertTrue(isoText.contains("PermitRootLogin no"))
        XCTAssertTrue(isoText.contains("AllowTcpForwarding no"))
        XCTAssertTrue(isoText.contains("<zone target=\"DROP\">"))
        XCTAssertTrue(isoText.contains("network: {config: disabled}"))
        XCTAssertTrue(isoText.contains("id=sandfort"))
        XCTAssertTrue(isoText.contains("Type=oneshot"))
        XCTAssertTrue(isoText.contains("OnCalendar=daily"))
        XCTAssertTrue(isoText.contains("mode: poweroff"))
        XCTAssertTrue(isoText.contains("condition: [test, -f, /var/lib/sandfort/setup-complete]"))

        XCTAssertTrue(finalizer.contains("for attempt in 1 2 3"))
        XCTAssertTrue(finalizer.contains("zypper --non-interactive --gpg-auto-import-keys refresh"))
        XCTAssertTrue(finalizer.contains("zypper --non-interactive update"))
        XCTAssertTrue(finalizer.contains("rpm -q patterns-gnome-gnome"))
        XCTAssertTrue(finalizer.contains("rpm -q qemu-guest-agent"))
        XCTAssertTrue(finalizer.contains("rpm -q spice-vdagent"))
        // Leap's GNOME pattern ships no browser, so the profile must request one
        // explicitly and pin the branding provider for the unattended solver.
        XCTAssertTrue(isoText.contains("MozillaFirefox"))
        XCTAssertTrue(isoText.contains("MozillaFirefox-branding-openSUSE"))
        XCTAssertTrue(finalizer.contains("rpm -q MozillaFirefox"))
        XCTAssertTrue(finalizer.contains("command -v firefox"))
        // A sandbox must not gain a mail client, IRC client, BitTorrent client,
        // or VPN plugins from the broader openSUSE internet pattern.
        XCTAssertFalse(isoText.contains("patterns-gnome-gnome_internet"))
        XCTAssertFalse(isoText.contains("transmission"))
        XCTAssertFalse(isoText.contains("evolution"))
        XCTAssertTrue(finalizer.contains("systemctl mask sshd.service sshd.socket"))
        XCTAssertTrue(finalizer.contains("systemctl is-active --quiet sshd.service"))
        XCTAssertTrue(finalizer.contains("rm -f /etc/NetworkManager/system-connections/cloud-init-*"))
        XCTAssertTrue(finalizer.contains("systemctl enable --now firewalld.service"))
        XCTAssertTrue(finalizer.contains("firewall-cmd --set-default-zone=sandfort"))
        XCTAssertTrue(finalizer.contains("firewall-cmd --zone=sandfort --query-service=ssh"))
        XCTAssertTrue(finalizer.contains("test \"$(getenforce)\" = Enforcing"))
        XCTAssertTrue(finalizer.contains("systemctl enable sandfort-security-update.timer"))
        XCTAssertTrue(finalizer.contains("systemctl enable gdm.service || systemctl enable display-manager.service"))
        // Instances have a display and no serial device, so a VT1 getty would
        // show a text login prompt before GDM and read as the only way in.
        XCTAssertTrue(finalizer.contains("systemctl mask getty@tty1.service"))
        XCTAssertTrue(finalizer.contains("systemctl is-enabled getty@tty1.service"))
        // Masking one instance must not disable the Ctrl+Alt+F2 rescue console.
        XCTAssertFalse(finalizer.contains("systemctl mask getty@.service"))
        XCTAssertFalse(finalizer.contains("mask autovt@"))
        XCTAssertTrue(finalizer.contains("systemctl enable qemu-guest-agent.service"))
        XCTAssertTrue(finalizer.contains("systemctl enable NetworkManager.service"))
        XCTAssertTrue(finalizer.contains("https://nodejs.org/dist/index.json"))
        XCTAssertTrue(finalizer.contains("linux-arm64.tar.xz"))
        XCTAssertTrue(finalizer.contains("sha256sum --check"))
        XCTAssertTrue(finalizer.contains("command -v python3"))
        XCTAssertTrue(finalizer.contains("python3.13 -m pip --version"))
        XCTAssertTrue(finalizer.contains("touch /var/lib/sandfort/setup-complete"))
        XCTAssertFalse(finalizer.contains("apt-get"))
        XCTAssertFalse(finalizer.contains("dnf5"))
        XCTAssertFalse(finalizer.contains("ufw "))
        XCTAssertFalse(isoText.lowercased().contains("selinux=0"))
        XCTAssertFalse(isoText.lowercased().contains("setenforce 0"))
    }

    func testFedoraCloudInitHonorsOptionalToolsAndCustomSetupSafety() throws {
        let script = "#!/usr/bin/env bash\nset -euo pipefail\ndnf5 -y install ripgrep\n"
        let iso = try FedoraCloudInit.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(
                python: false,
                nodeJS: false,
                customSetupScript: script,
                verboseSetupLogging: true
            ),
            hardware: LinuxGuestCatalog.fedora44ARM64.hardware
        )
        let isoText = String(decoding: iso, as: UTF8.self)
        let finalizer = try decodedFinalizer(from: iso)
        let encodedScript = Data(script.trimmingCharacters(in: .whitespacesAndNewlines).utf8).base64EncodedString()
        XCTAssertTrue(isoText.contains(encodedScript))
        XCTAssertFalse(isoText.contains("dnf5 -y install ripgrep"))
        XCTAssertTrue(finalizer.contains("/var/lib/sandfort/custom-setup.sh"))
        XCTAssertTrue(finalizer.contains("exec > >(tee -a /var/log/sandfort-setup.log) 2>&1"))
        XCTAssertFalse(finalizer.contains("command -v python3"))
        XCTAssertFalse(finalizer.contains("command -v node"))
        XCTAssertFalse(finalizer.contains("https://nodejs.org/dist/index.json"))

        XCTAssertThrowsError(try FedoraCloudInit.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(
                python: false,
                nodeJS: false,
                customSetupScript: String(repeating: "x", count: 65_537)
            ),
            hardware: LinuxGuestCatalog.fedora44ARM64.hardware
        ))
    }

    func testDebianCloudInitEnforcesDistributionSpecificProvisioningAndSecurity() throws {
        let credentials = SandboxCredentials(username: "sandfort", password: "safe'debian-phrase")
        let iso = try DebianCloudInit.seedISO(
            credentials: credentials,
            tools: .recommended,
            hardware: LinuxGuestCatalog.debian13ARM64.hardware
        )
        let isoText = String(decoding: iso, as: UTF8.self)
        let finalizer = try decodedFinalizer(from: iso)

        XCTAssertTrue(isoText.contains("groups: [adm, sudo]"))
        XCTAssertTrue(isoText.contains("password: 'safe''debian-phrase'"))
        XCTAssertTrue(isoText.contains("PasswordAuthentication no"))
        XCTAssertTrue(isoText.contains("PermitRootLogin no"))
        XCTAssertTrue(isoText.contains("AllowTcpForwarding no"))
        XCTAssertTrue(isoText.contains("APT::Periodic::Unattended-Upgrade \"1\""))
        XCTAssertTrue(isoText.contains("/etc/NetworkManager/system-connections/sandfort.nmconnection"))
        XCTAssertTrue(isoText.contains("autoconnect-priority=100"))
        XCTAssertTrue(isoText.contains("[ifupdown]"))
        XCTAssertTrue(isoText.contains("managed=true"))
        XCTAssertTrue(isoText.contains("99-sandfort-disable-network-config.cfg"))
        XCTAssertTrue(isoText.contains("network: {config: disabled}"))
        XCTAssertFalse(isoText.contains("mac-address="))
        XCTAssertFalse(isoText.contains("interface-name="))
        XCTAssertTrue(isoText.contains("mode: poweroff"))
        XCTAssertTrue(isoText.contains("condition: [test, -f, /var/lib/sandfort/setup-complete]"))

        XCTAssertTrue(finalizer.contains("for attempt in 1 2 3"))
        XCTAssertTrue(finalizer.contains("apt-get update"))
        XCTAssertTrue(finalizer.contains("apt-get install -y apparmor"))
        XCTAssertTrue(finalizer.contains("task-gnome-desktop"))
        XCTAssertTrue(finalizer.contains("dpkg-query -W gdm3"))
        XCTAssertTrue(finalizer.contains("systemctl mask ssh.service ssh.socket"))
        XCTAssertTrue(finalizer.contains("rm -f /etc/network/interfaces.d/50-cloud-init"))
        XCTAssertTrue(finalizer.contains("rm -f /etc/netplan/*.yaml"))
        XCTAssertTrue(finalizer.contains("rm -f /run/udev/rules.d/90-netplan.rules"))
        XCTAssertTrue(finalizer.contains("systemctl disable networking.service"))
        XCTAssertTrue(finalizer.contains("MAC-independent DHCP profile"))
        XCTAssertTrue(finalizer.contains("mac-address|interface-name"))
        XCTAssertTrue(finalizer.contains("systemctl is-active --quiet ssh.service"))
        XCTAssertTrue(finalizer.contains("ufw default deny incoming"))
        XCTAssertTrue(finalizer.contains("ufw default allow outgoing"))
        XCTAssertTrue(finalizer.contains("ufw --force enable"))
        XCTAssertTrue(finalizer.contains("aa-enabled"))
        XCTAssertTrue(finalizer.contains("systemctl enable unattended-upgrades.service"))
        XCTAssertTrue(finalizer.contains("systemctl enable gdm3.service"))
        XCTAssertTrue(finalizer.contains("systemctl mask getty@tty1.service"))
        XCTAssertTrue(finalizer.contains("systemctl is-enabled getty@tty1.service"))
        XCTAssertFalse(finalizer.contains("mask autovt@"))
        XCTAssertTrue(finalizer.contains("systemctl enable qemu-guest-agent.service"))
        XCTAssertTrue(finalizer.contains("systemctl enable NetworkManager.service"))
        XCTAssertTrue(finalizer.contains("https://nodejs.org/dist/index.json"))
        XCTAssertTrue(finalizer.contains("linux-arm64.tar.xz"))
        XCTAssertTrue(finalizer.contains("sha256sum --check"))
        XCTAssertTrue(finalizer.contains("command -v python3"))
        XCTAssertTrue(finalizer.contains("python3 -m venv --help"))
        XCTAssertTrue(finalizer.contains("touch /var/lib/sandfort/setup-complete"))
        XCTAssertFalse(finalizer.contains("dnf5"))
        XCTAssertFalse(finalizer.contains("firewall-cmd"))
    }

    func testDebianCloudInitHonorsOptionalToolsAndCustomSetupSafety() throws {
        let script = "#!/usr/bin/env bash\nset -euo pipefail\napt-get install -y ripgrep\n"
        let iso = try DebianCloudInit.seedISO(
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: SandboxToolSelection(
                python: false,
                nodeJS: false,
                customSetupScript: script,
                verboseSetupLogging: true
            ),
            hardware: LinuxGuestCatalog.debian13ARM64.hardware
        )
        let isoText = String(decoding: iso, as: UTF8.self)
        let finalizer = try decodedFinalizer(from: iso)
        let encodedScript = Data(script.trimmingCharacters(in: .whitespacesAndNewlines).utf8).base64EncodedString()
        XCTAssertTrue(isoText.contains(encodedScript))
        XCTAssertFalse(isoText.contains("apt-get install -y ripgrep"))
        XCTAssertTrue(finalizer.contains("/var/lib/sandfort/custom-setup.sh"))
        XCTAssertTrue(finalizer.contains("exec > >(tee -a /var/log/sandfort-setup.log) 2>&1"))
        XCTAssertFalse(finalizer.contains("command -v python3"))
        XCTAssertFalse(finalizer.contains("command -v node"))
        XCTAssertFalse(finalizer.contains("https://nodejs.org/dist/index.json"))
    }

    func testEveryCatalogEntryHasAUniqueStableContract() {
        let entries = LinuxGuestCatalog.profiles + LinuxGuestCatalog.qualificationProfiles
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertEqual(Set(entries.map { "\($0.id)@\($0.revision)" }).count, entries.count)
        XCTAssertEqual(Set(entries.map(\.image.fileName)).count, entries.count)
        for profile in entries {
            XCTAssertGreaterThan(profile.revision, 0)
            XCTAssertEqual(profile.image.url.scheme, "https")
            XCTAssertEqual(profile.image.sha256.count, 64)
            XCTAssertTrue(profile.image.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertEqual(profile.hardware.architecture, "arm64")
            XCTAssertEqual(profile.hardware.utmArchitecture, "aarch64")
            XCTAssertEqual(profile.hardware.utmTarget, "virt")
            XCTAssertGreaterThanOrEqual(profile.hardware.memoryMiB, 2048)
            XCTAssertGreaterThanOrEqual(profile.hardware.cpuCount, 2)
            XCTAssertGreaterThanOrEqual(profile.hardware.diskSizeGiB, 32)
        }
    }

    func testNativeHasherMatchesDownloadedFedoraProfileWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SANDFORT_FEDORA_IMAGE"] else {
            throw XCTSkip("Set SANDFORT_FEDORA_IMAGE to independently verify the Fedora profile")
        }
        XCTAssertEqual(
            try DiskUtilities.sha256(of: URL(fileURLWithPath: path)),
            LinuxGuestCatalog.fedora44ARM64.image.sha256
        )
        XCTAssertNoThrow(try DiskUtilities.validateQCOW2Geometry(at: URL(fileURLWithPath: path)))
    }

    func testNativeHasherMatchesDownloadedDebianProfileWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SANDFORT_DEBIAN_IMAGE"] else {
            throw XCTSkip("Set SANDFORT_DEBIAN_IMAGE to independently verify the Debian profile")
        }
        XCTAssertEqual(
            try DiskUtilities.sha256(of: URL(fileURLWithPath: path)),
            LinuxGuestCatalog.debian13ARM64.image.sha256
        )
        XCTAssertNoThrow(try DiskUtilities.validateQCOW2Geometry(at: URL(fileURLWithPath: path)))
    }

    func testNativeHasherMatchesDownloadedOpenSUSEProfileWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SANDFORT_OPENSUSE_IMAGE"] else {
            throw XCTSkip("Set SANDFORT_OPENSUSE_IMAGE to independently verify the openSUSE profile")
        }
        XCTAssertEqual(
            try DiskUtilities.sha256(of: URL(fileURLWithPath: path)),
            LinuxGuestCatalog.opensuseLeap16ARM64.image.sha256
        )
        XCTAssertNoThrow(try DiskUtilities.validateQCOW2Geometry(at: URL(fileURLWithPath: path)))
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
        XCTAssertNil(state.guestProfileID)
        XCTAssertNil(state.guestProfileRevision)
        XCTAssertNil(state.guestImageSHA256)
        XCTAssertEqual(state.resolvedInstances, [SandboxInstance(
            number: 1,
            bundlePath: "/tmp/Legacy Sandbox.utm",
            vmName: "Sandbox Ubuntu ABC123"
        )])
    }

    func testExactGuestProfileIdentityRoundTripsInSandboxState() throws {
        let profile = LinuxGuestCatalog.defaultProfile
        let state = SandboxState(
            stage: .provisioning,
            credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
            tools: .recommended,
            setupBundlePath: "/tmp/Baseline.utm",
            sandboxBundlePath: nil,
            setupVMName: "Sandfort — Baseline Setup ABC123",
            sandboxVMName: nil,
            guestProfileID: profile.id,
            guestProfileRevision: profile.revision,
            guestImageSHA256: profile.image.sha256
        )
        let decoded = try PropertyListDecoder().decode(
            SandboxState.self,
            from: PropertyListEncoder().encode(state)
        )
        XCTAssertEqual(decoded.guestProfileID, "ubuntu-24.04-arm64")
        XCTAssertEqual(decoded.guestProfileRevision, 4)
        XCTAssertEqual(decoded.guestImageSHA256, profile.image.sha256)
    }

    func testCatalogResolvesExactAndLegacyBaselineProfilesWithoutGuessing() {
        let profile = LinuxGuestCatalog.defaultProfile
        XCTAssertEqual(
            LinuxGuestCatalog.supportedProfile(
                id: profile.id,
                revision: profile.revision,
                imageSHA256: profile.image.sha256
            ),
            profile
        )
        // Pre-revision state was built by Ubuntu revision 1, which no longer
        // exists. Refusing to resolve it is the point: mapping it onto the
        // current revision would claim provisioning guarantees it lacks.
        XCTAssertNil(LinuxGuestCatalog.supportedProfile(
            id: profile.id,
            revision: nil,
            imageSHA256: nil
        ))
        XCTAssertNil(LinuxGuestCatalog.legacyProfile(id: profile.id))
        XCTAssertNil(LinuxGuestCatalog.supportedProfile(
            id: profile.id,
            revision: profile.revision + 1,
            imageSHA256: profile.image.sha256
        ))
        XCTAssertNil(LinuxGuestCatalog.supportedProfile(
            id: profile.id,
            revision: profile.revision,
            imageSHA256: String(repeating: "0", count: 64)
        ))
        XCTAssertNil(LinuxGuestCatalog.supportedProfile(
            id: "unknown-linux",
            revision: nil,
            imageSHA256: nil
        ))
    }

    func testWorkflowProfileCompatibilityRequiresARebuildForPreRevisionState() throws {
        let profile = LinuxGuestCatalog.defaultProfile
        func state(
            stage: SandboxState.Stage = .ready,
            id: String? = nil,
            revision: Int? = nil,
            sha256: String? = nil
        ) -> SandboxState {
            SandboxState(
                stage: stage,
                credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
                tools: .recommended,
                setupBundlePath: "/tmp/Baseline.utm",
                sandboxBundlePath: "/tmp/Instance 1.utm",
                guestProfileID: id,
                guestProfileRevision: revision,
                guestImageSHA256: sha256
            )
        }

        // State with no persisted revision predates Ubuntu revision 2 and its
        // console-login fix, so it must require a rebuild rather than resolve.
        for legacyState in [state(), state(id: profile.id)] {
            XCTAssertThrowsError(
                try SandfortWorkflow.resolveGuestProfile(for: legacyState)
            ) { error in
                guard case SandboxError.incompatibleGuestProfile(_) = error else {
                    return XCTFail("Expected pre-revision state to require rebuild, received \(error)")
                }
            }
        }
        XCTAssertEqual(try SandfortWorkflow.resolveGuestProfile(
            for: state(
                id: profile.id,
                revision: profile.revision,
                sha256: profile.image.sha256
            ),
            requireExactMetadata: true
        ), profile)

        XCTAssertThrowsError(try SandfortWorkflow.resolveGuestProfile(
            for: state(stage: .provisioning, id: profile.id),
            requireExactMetadata: true
        )) { error in
            guard case SandboxError.incompleteSetupProfileMetadata = error else {
                return XCTFail("Expected incomplete setup metadata error, received \(error)")
            }
        }
        XCTAssertThrowsError(try SandfortWorkflow.resolveGuestProfile(
            for: state(id: profile.id, revision: profile.revision + 1, sha256: profile.image.sha256)
        )) { error in
            guard case SandboxError.incompatibleGuestProfile(_) = error else {
                return XCTFail("Expected incompatible profile error, received \(error)")
            }
        }
        XCTAssertThrowsError(try SandfortWorkflow.resolveGuestProfile(
            for: state(
                id: profile.id,
                revision: profile.revision,
                sha256: String(repeating: "0", count: 64)
            )
        )) { error in
            guard case SandboxError.incompatibleGuestProfile(_) = error else {
                return XCTFail("Expected incompatible profile error, received \(error)")
            }
        }
        XCTAssertThrowsError(try SandfortWorkflow.resolveGuestProfile(
            for: state(id: "unknown-linux")
        )) { error in
            guard case SandboxError.unsupportedGuestProfile(_) = error else {
                return XCTFail("Expected unsupported profile error, received \(error)")
            }
        }
    }

    func testFedoraQualificationRuntimeIsIsolatedFromProduction() throws {
        let production = SandfortRuntimeConfiguration.configuration(qualificationProfileID: nil)
        XCTAssertFalse(production.isQualification)
        XCTAssertEqual(production.displayName, "Sandfort")
        XCTAssertEqual(production.defaultProfile, LinuxGuestCatalog.defaultProfile)
        XCTAssertEqual(production.workflowEnvironment.supportDirectoryName, "Sandfort")
        XCTAssertEqual(production.workflowEnvironment.vmNamePrefix, "Sandfort")
        XCTAssertEqual(production.workflowEnvironment.supportedProfiles, LinuxGuestCatalog.supportedProfiles)
        XCTAssertEqual(production.selectableProfiles, LinuxGuestCatalog.profiles)
        XCTAssertTrue(production.cacheURL.path.hasSuffix("/Application Support/Sandfort/Cache"))

        let qualification = SandfortRuntimeConfiguration.configuration(
            qualificationProfileID: LinuxGuestCatalog.fedora44ARM64.id
        )
        let fedora = LinuxGuestCatalog.fedora44ARM64
        XCTAssertTrue(qualification.isQualification)
        XCTAssertEqual(qualification.defaultProfile, fedora)
        XCTAssertEqual(
            qualification.workflowEnvironment.supportDirectoryName,
            "Sandfort Fedora Qualification"
        )
        XCTAssertEqual(
            qualification.workflowEnvironment.vmNamePrefix,
            "Sandfort Fedora Qualification"
        )
        XCTAssertNil(qualification.workflowEnvironment.legacySupportDirectoryName)
        XCTAssertEqual(qualification.workflowEnvironment.supportedProfiles, [fedora])
        XCTAssertEqual(qualification.workflowEnvironment.legacyProfiles, [])
        XCTAssertEqual(qualification.selectableProfiles, [fedora])
        XCTAssertTrue(qualification.cacheURL.path.hasSuffix(
            "/Application Support/Sandfort Fedora Qualification/Cache"
        ))

        let fedoraState = SandboxState(
            stage: .provisioning,
            credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
            tools: .recommended,
            setupBundlePath: "/tmp/Fedora Qualification.utm",
            sandboxBundlePath: nil,
            guestProfileID: fedora.id,
            guestProfileRevision: fedora.revision,
            guestImageSHA256: fedora.image.sha256
        )
        XCTAssertEqual(
            try SandfortWorkflow.resolveGuestProfile(
                for: fedoraState,
                requireExactMetadata: true
            ),
            fedora
        )
        XCTAssertEqual(
            try SandfortWorkflow.resolveGuestProfile(
                for: fedoraState,
                environment: qualification.workflowEnvironment,
                requireExactMetadata: true
            ),
            fedora
        )
    }

    /// Ubuntu is the default production profile, so its qualification build has
    /// the most to prove: selecting it must not reach production state, even
    /// though production would resolve the same profile.
    func testUbuntuQualificationRuntimeIsIsolatedFromProduction() throws {
        let ubuntu = LinuxGuestCatalog.ubuntu2404ARM64
        let qualification = SandfortRuntimeConfiguration.configuration(
            qualificationProfileID: ubuntu.id
        )
        XCTAssertTrue(qualification.isQualification)
        XCTAssertEqual(qualification.defaultProfile, ubuntu)
        XCTAssertEqual(qualification.displayName, "Sandfort — Ubuntu Qualification")
        XCTAssertEqual(
            qualification.workflowEnvironment.supportDirectoryName,
            "Sandfort Ubuntu Qualification"
        )
        XCTAssertEqual(
            qualification.workflowEnvironment.vmNamePrefix,
            "Sandfort Ubuntu Qualification"
        )
        XCTAssertNil(qualification.workflowEnvironment.legacySupportDirectoryName)
        XCTAssertEqual(qualification.workflowEnvironment.supportedProfiles, [ubuntu])
        XCTAssertEqual(qualification.selectableProfiles, [ubuntu])
        XCTAssertTrue(qualification.cacheURL.path.hasSuffix(
            "/Application Support/Sandfort Ubuntu Qualification/Cache"
        ))
        XCTAssertNotEqual(
            qualification.supportRootURL,
            SandfortRuntimeConfiguration.production.supportRootURL
        )

        let state = SandboxState(
            stage: .provisioning,
            credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
            tools: .recommended,
            setupBundlePath: "/tmp/Ubuntu Qualification.utm",
            sandboxBundlePath: nil,
            guestProfileID: ubuntu.id,
            guestProfileRevision: ubuntu.revision,
            guestImageSHA256: ubuntu.image.sha256
        )
        XCTAssertEqual(
            try SandfortWorkflow.resolveGuestProfile(
                for: state,
                environment: qualification.workflowEnvironment,
                requireExactMetadata: true
            ),
            ubuntu
        )

        // Every superseded revision must still require a rebuild.
        for incompatibleRevision in [1, 2, 3] {
            var incompatibleState = state
            incompatibleState.guestProfileRevision = incompatibleRevision
            XCTAssertThrowsError(try SandfortWorkflow.resolveGuestProfile(
                for: incompatibleState,
                environment: qualification.workflowEnvironment,
                requireExactMetadata: true
            )) { error in
                guard case let SandboxError.incompatibleGuestProfile(profileID) = error else {
                    return XCTFail("Expected Ubuntu revision \(incompatibleRevision) to require rebuild")
                }
                XCTAssertEqual(profileID, ubuntu.id)
            }
        }
    }

    func testDebianQualificationRuntimeIsIsolatedFromProduction() throws {
        let debian = LinuxGuestCatalog.debian13ARM64
        let qualification = SandfortRuntimeConfiguration.configuration(
            qualificationProfileID: debian.id
        )
        XCTAssertTrue(qualification.isQualification)
        XCTAssertEqual(qualification.defaultProfile, debian)
        XCTAssertEqual(qualification.displayName, "Sandfort — Debian Qualification")
        XCTAssertEqual(
            qualification.workflowEnvironment.supportDirectoryName,
            "Sandfort Debian Qualification"
        )
        XCTAssertEqual(
            qualification.workflowEnvironment.vmNamePrefix,
            "Sandfort Debian Qualification"
        )
        XCTAssertEqual(qualification.workflowEnvironment.supportedProfiles, [debian])
        XCTAssertEqual(qualification.workflowEnvironment.legacyProfiles, [])
        XCTAssertEqual(qualification.selectableProfiles, [debian])
        XCTAssertTrue(qualification.cacheURL.path.hasSuffix(
            "/Application Support/Sandfort Debian Qualification/Cache"
        ))

        let state = SandboxState(
            stage: .provisioning,
            credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
            tools: .recommended,
            setupBundlePath: "/tmp/Debian Qualification.utm",
            sandboxBundlePath: nil,
            guestProfileID: debian.id,
            guestProfileRevision: debian.revision,
            guestImageSHA256: debian.image.sha256
        )
        XCTAssertEqual(
            try SandfortWorkflow.resolveGuestProfile(
                for: state,
                environment: qualification.workflowEnvironment,
                requireExactMetadata: true
            ),
            debian
        )
        XCTAssertEqual(
            try SandfortWorkflow.resolveGuestProfile(
                for: state,
                environment: .production,
                requireExactMetadata: true
            ),
            debian
        )

        for incompatibleRevision in [1, 2, 3, 4, 5, 6] {
            var incompatibleState = state
            incompatibleState.guestProfileRevision = incompatibleRevision
            XCTAssertThrowsError(try SandfortWorkflow.resolveGuestProfile(
                for: incompatibleState,
                environment: qualification.workflowEnvironment,
                requireExactMetadata: true
            )) { error in
                guard case let SandboxError.incompatibleGuestProfile(profileID) = error else {
                    return XCTFail("Expected Debian revision \(incompatibleRevision) to require rebuild")
                }
                XCTAssertEqual(profileID, debian.id)
            }
        }
    }

    func testOpenSUSEQualificationRuntimeIsIsolatedFromProduction() throws {
        let opensuse = LinuxGuestCatalog.opensuseLeap16ARM64
        let qualification = SandfortRuntimeConfiguration.configuration(
            qualificationProfileID: opensuse.id
        )
        XCTAssertTrue(qualification.isQualification)
        XCTAssertEqual(qualification.defaultProfile, opensuse)
        XCTAssertEqual(qualification.displayName, "Sandfort — openSUSE Qualification")
        XCTAssertEqual(
            qualification.workflowEnvironment.supportDirectoryName,
            "Sandfort openSUSE Qualification"
        )
        XCTAssertEqual(
            qualification.workflowEnvironment.vmNamePrefix,
            "Sandfort openSUSE Qualification"
        )
        XCTAssertNil(qualification.workflowEnvironment.legacySupportDirectoryName)
        XCTAssertEqual(qualification.workflowEnvironment.supportedProfiles, [opensuse])
        XCTAssertEqual(qualification.workflowEnvironment.legacyProfiles, [])
        XCTAssertEqual(qualification.selectableProfiles, [opensuse])
        XCTAssertTrue(qualification.cacheURL.path.hasSuffix(
            "/Application Support/Sandfort openSUSE Qualification/Cache"
        ))

        let state = SandboxState(
            stage: .provisioning,
            credentials: SandboxCredentials(username: "sandfort", password: "river-lantern-amber-willow"),
            tools: .recommended,
            setupBundlePath: "/tmp/openSUSE Qualification.utm",
            sandboxBundlePath: nil,
            guestProfileID: opensuse.id,
            guestProfileRevision: opensuse.revision,
            guestImageSHA256: opensuse.image.sha256
        )
        XCTAssertEqual(
            try SandfortWorkflow.resolveGuestProfile(
                for: state,
                environment: qualification.workflowEnvironment,
                requireExactMetadata: true
            ),
            opensuse
        )
        XCTAssertEqual(
            try SandfortWorkflow.resolveGuestProfile(
                for: state,
                environment: .production,
                requireExactMetadata: true
            ),
            opensuse
        )

        // Revisions 1 and 2 were only ever built by qualification builds: 1 had
        // no browser and 2 still showed a console login prompt before GDM.
        // Neither may be silently reused under the promoted contract.
        for incompatibleRevision in [1, 2, 3, 4] {
            var incompatibleState = state
            incompatibleState.guestProfileRevision = incompatibleRevision
            XCTAssertThrowsError(try SandfortWorkflow.resolveGuestProfile(
                for: incompatibleState,
                environment: qualification.workflowEnvironment,
                requireExactMetadata: true
            )) { error in
                guard case let SandboxError.incompatibleGuestProfile(profileID) = error else {
                    return XCTFail("Expected openSUSE revision \(incompatibleRevision) to require rebuild")
                }
                XCTAssertEqual(profileID, opensuse.id)
            }
        }
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
            setupVMImportedName: "Sandfort — Baseline Setup ABC123",
            sandboxVMName: "Sandfort — Instance 1 — ABC123",
            instances: [
                SandboxInstance(number: 1, bundlePath: "/tmp/Instance 1.utm", vmName: "Sandfort — Instance 1 — ABC123"),
                SandboxInstance(number: 2, bundlePath: "/tmp/Instance 2.utm", vmName: "Sandfort — Instance 2 — ABC123")
            ],
            nextInstanceNumber: 3
        )

        XCTAssertEqual(state.utmRegistrationNames, [
            "Sandfort — Protected Baseline ABC123",
            "Sandfort — Baseline Setup ABC123",
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

    func testUTMRegistryRecognizesApplicationNotRunningError() {
        XCTAssertTrue(UTMRegistryController.isApplicationNotRunning(NSError(
            domain: NSOSStatusErrorDomain,
            code: -600
        )))
        XCTAssertFalse(UTMRegistryController.isApplicationNotRunning(NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(errAENoSuchObject)
        )))
        XCTAssertFalse(UTMRegistryController.isApplicationNotRunning(NSError(
            domain: NSCocoaErrorDomain,
            code: -600
        )))
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
        let ubuntu = LinuxGuestCatalog.defaultProfile
        // Pinned to the synthetic image this test actually writes. The builder
        // verifies the disk it copied into the bundle, so a profile claiming
        // Ubuntu's checksum over a 128 KiB stub is now rejected — which is the
        // point of that check, not an obstacle to it.
        let profile = LinuxGuestProfile(
            id: "test-profile",
            revision: 7,
            displayName: "Test Linux",
            distributionName: "Test",
            utmIconNames: ["ubuntu"],
            setupDurationDescription: "a few minutes",
            image: LinuxGuestProfile.Image(
                url: ubuntu.image.url,
                sha256: try DiskUtilities.sha256(of: image),
                fileName: ubuntu.image.fileName,
                downloadSizeDescription: ubuntu.image.downloadSizeDescription
            ),
            hardware: LinuxGuestProfile.Hardware(
                architecture: "test-arm64",
                utmArchitecture: "test-aarch64",
                utmTarget: "test-virt",
                utmFirmwareVarsName: "test-vars.fd",
                serialConsoleDevice: "ttyTEST0",
                linuxArchiveArchitecture: "test-arm64",
                materialsInterface: "SCSI",
                memoryMiB: 3072,
                cpuCount: 2,
                diskSizeGiB: 72
            ),
            provisioner: .ubuntu2404
        )
        let builder = UTMBundleBuilder(firmwareURLOverride: firmware)
        try builder.createSetupBundle(
            at: setup,
            name: "Sandfort — Baseline Setup TEST01",
            from: image,
            profile: profile,
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: .recommended
        )
        let setupDiskHeader = try Data(contentsOf: setup.appendingPathComponent("Data/sandfort.qcow2")).prefix(32)
        XCTAssertEqual(Array(setupDiskHeader[24..<32]), [0, 0, 0, 18, 0, 0, 0, 0])
        try builder.createCleanBundle(
            from: setup,
            at: clean,
            name: "Sandfort — Instance 1 — TEST01",
            profile: profile,
            networkMode: .offline
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.appendingPathComponent("Data/efi_vars.fd").path))

        let setupPlistData = try Data(contentsOf: setup.appendingPathComponent("config.plist"))
        let setupPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: setupPlistData, format: nil) as? [String: Any])
        XCTAssertEqual((setupPlist["Information"] as? [String: Any])?["Name"] as? String, "Sandfort — Baseline Setup TEST01")
        // Written at creation, not only retrofitted by repair.
        XCTAssertEqual((setupPlist["Information"] as? [String: Any])?["Icon"] as? String, "ubuntu")
        XCTAssertEqual((setupPlist["Information"] as? [String: Any])?["IconCustom"] as? Bool, false)
        let setupSystem = try XCTUnwrap(setupPlist["System"] as? [String: Any])
        XCTAssertEqual(setupSystem["Architecture"] as? String, "test-aarch64")
        XCTAssertEqual(setupSystem["Target"] as? String, "test-virt")
        XCTAssertEqual(setupSystem["MemorySize"] as? Int, 3072)
        XCTAssertEqual(setupSystem["CPUCount"] as? Int, 2)
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
        try builder.repairBundle(at: setup, profile: profile, role: .protectedBaseline)
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
        XCTAssertEqual((plist["Information"] as? [String: Any])?["Icon"] as? String, "ubuntu")
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
            profile: profile,
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

        try builder.resetCleanBundle(from: setup, at: clean, profile: profile, networkMode: .internet)
        let internetPlistData = try Data(contentsOf: clean.appendingPathComponent("config.plist"))
        let internetPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: internetPlistData, format: nil) as? [String: Any])
        let internetNetwork = try XCTUnwrap((internetPlist["Network"] as? [[String: Any]])?.first)
        XCTAssertEqual(internetNetwork["IsolateFromHost"] as? Bool, false)
        XCTAssertEqual(internetNetwork["PortForward"] as? [String], [])

        try builder.repairBundle(at: clean, profile: profile, role: .cleanInstance)
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

        try builder.resetCleanBundle(from: setup, at: clean, profile: profile, networkMode: .offline)
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
