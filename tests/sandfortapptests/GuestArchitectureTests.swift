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

import CryptoKit
import XCTest
@testable import SandfortApp

/// The architecture axis: which values are architecture-shaped, where they come
/// from, and — first — that making them explicit changed nothing in the guest.
final class GuestArchitectureTests: XCTestCase {
    private let credentials = SandboxCredentials(
        username: "sandfort",
        password: "golden-test-password"
    )

    /// Every generated `user-data`, without the ISO around it. `meta-data`
    /// carries a fresh UUID on every call, so the ISO as a whole is not stable
    /// and is not what the guest is built from anyway.
    private func userData(
        _ profile: LinuxGuestProfile,
        tools: SandboxToolSelection
    ) throws -> String {
        let text = String(
            decoding: try profile.seedISO(credentials: credentials, tools: tools),
            as: UTF8.self
        )
        let start = try XCTUnwrap(text.range(of: "#cloud-config"))
        let tail = text[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "$UPTIME seconds"))
        return String(tail[..<end.upperBound])
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The constraint that matters

    /// Captured from the generated output *before* the architecture axis
    /// existed, and unchanged by introducing it.
    ///
    /// This is the whole safety argument for shipping the change without a
    /// profile revision. Everything these tests cover is embedded in the guest,
    /// so a stray space would force every existing user to Rebuild — and
    /// nothing else in the suite would notice, because every other assertion
    /// here is a `contains`.
    ///
    /// **A failure here is not a test to update.** It means the guest changed.
    /// Either undo the change, or bump the profile's revision and say so in the
    /// pull request, per `AGENTS.md`.
    private static let goldenUserDataDigests: [String: [String: String]] = [
        "ubuntu-24.04-arm64": [
            "recommended": "c2ad0ed4323f701d33826c8500702cf35762983b27da8b3a112414833de1773c",
            "bare": "0692d4ad8e7ea42a6e4293a36aa6989168f326042c58f65a16b059d073114606",
            "custom": "d945990b3f90f366efb1bd21759d011112d637764f55a43c9acb473c207cae84"
        ],
        "fedora-44-arm64": [
            "recommended": "7a025de7947f0b06522690c613f04908bee8e323e944d3f9bdd498084cbfc8be",
            "bare": "975d8a1abef48e8be654b40db862f427bbef3d2ebaa59d81b4114ea3b5f5cdd4",
            "custom": "b7475e8b17ac03f9aa2433fbdfd4fce0777f983faf1b42c21b987b48e9bff0f1"
        ],
        "debian-13-arm64": [
            "recommended": "cd1151acd8dfc879a8275a5042d54db94b1cf300b19c9977af7dba74eab806dd",
            "bare": "eb66123488c06a52e8b0831199a9f98327ce20efa095b3df6fb3b205870f24f4",
            "custom": "a17a9994419c5895754cdc21a6d028d946f60da120e61fe440777ee286d14e3d"
        ],
        "opensuse-leap-16.0-arm64": [
            // Revision 7: a file manager, gvfs, gvfs-backends, and udisks2.
            // Leap's GNOME pattern provides none of them. Revision 6 added the
            // first three and was still not enough — core gvfs does not carry
            // the udisks2 volume monitor, so Files showed no removable media.
            "recommended": "93a5dc078de2463fcfde835043bf4c819904721f384046d45bf84c78700452d9",
            "bare": "c8c1811367826663f1ee6b1c220fb7c47b478cc5bd9aefd30859066582dee454",
            "custom": "f41962f89bef56b1633402dfabbb97be12a4ba3ae8a5b6b82e0d9753bd572716"
        ]
    ]

    /// Three selections rather than one, because the architecture-shaped values
    /// live on both sides of a tools branch: the Node.js and VS Code installers
    /// are omitted entirely when deselected, and the custom-script path rewrites
    /// the logging preamble around them.
    private static let toolVariants: [String: SandboxToolSelection] = [
        "recommended": .recommended,
        "bare": SandboxToolSelection(python: false, nodeJS: false, vsCode: false),
        "custom": SandboxToolSelection(
            python: true,
            nodeJS: true,
            customSetupScript: "echo hello\n",
            verboseSetupLogging: true,
            vsCode: true
        )
    ]

    func testGeneratedCloudInitIsByteIdenticalForEveryProfile() throws {
        for profile in LinuxGuestCatalog.profiles {
            let expected = try XCTUnwrap(
                Self.goldenUserDataDigests[profile.id],
                "\(profile.id) has no recorded golden output"
            )
            for (name, tools) in Self.toolVariants {
                XCTAssertEqual(
                    digest(try userData(profile, tools: tools)),
                    expected[name],
                    "\(profile.id) (\(name)) cloud-init changed; existing baselines would need a Rebuild"
                )
            }
        }
    }

    // MARK: - The axis itself

    func testEveryProfileDeclaresItsArchitectureAxis() {
        for profile in LinuxGuestCatalog.profiles + LinuxGuestCatalog.qualificationProfiles {
            let hardware = profile.hardware
            XCTAssertFalse(hardware.utmFirmwareVarsName.isEmpty, profile.id)
            XCTAssertFalse(hardware.serialConsoleDevice.isEmpty, profile.id)
            XCTAssertFalse(hardware.linuxArchiveArchitecture.isEmpty, profile.id)
        }
    }

    /// Only ARM64 profiles ship. Recorded here so adding an x86-64 profile is a
    /// deliberate edit to a test that names the expectation, rather than a
    /// silent widening.
    func testTheShippedCatalogIsARM64Only() {
        for profile in LinuxGuestCatalog.profiles {
            XCTAssertEqual(profile.hardware.architecture, "arm64", profile.id)
            XCTAssertEqual(profile.hardware.utmArchitecture, "aarch64", profile.id)
            XCTAssertEqual(profile.hardware.utmFirmwareVarsName, "edk2-arm-vars.fd", profile.id)
            XCTAssertEqual(profile.hardware.serialConsoleDevice, "ttyAMA0", profile.id)
            XCTAssertEqual(profile.hardware.linuxArchiveArchitecture, "arm64", profile.id)
        }
    }

    /// The trap this change most easily walks into.
    ///
    /// Node.js publishes `node-vX-linux-x64.tar.xz` and VS Code's update
    /// channel is `linux-x64`. Neither vendor uses `x86_64`, which is what the
    /// architecture is called everywhere else in the catalog, or `amd64`, which
    /// is what Debian calls it. Two separate call sites consume the value, and
    /// a wrong one fails inside the guest half an hour into a baseline build.
    func testArchiveArchitectureUsesTheVendorSpelling() {
        let vendorSpelling = ["arm64": "arm64", "x86_64": "x64", "amd64": "x64"]
        for profile in LinuxGuestCatalog.profiles + LinuxGuestCatalog.qualificationProfiles {
            let expected = vendorSpelling[profile.hardware.architecture]
            XCTAssertEqual(
                profile.hardware.linuxArchiveArchitecture,
                expected,
                "\(profile.id) spells its archive architecture "
                    + "'\(profile.hardware.linuxArchiveArchitecture)'; Node.js and VS Code "
                    + "expect '\(expected ?? "an entry in this table")'"
            )
        }
    }

    /// Both consumers, checked together, because they are two call sites that
    /// happen to agree and nothing else makes them.
    func testBothVendorInstallersUseTheSameArchiveArchitecture() {
        for architecture in ["arm64", "x64"] {
            let node = GuestProvisioningSupport.nodeLTSInstallCommands(
                enabled: true,
                linuxArchiveArchitecture: architecture
            )
            let vsCode = GuestProvisioningSupport.vsCodeInstallCommands(
                enabled: true,
                linuxArchiveArchitecture: architecture
            )
            XCTAssertTrue(node.contains("node-${nodeVersion}-linux-\(architecture).tar.xz"))
            XCTAssertTrue(
                vsCode.contains("update.code.visualstudio.com/api/update/linux-\(architecture)/stable/latest")
            )
            for wrong in ["x86_64", "amd64"] where architecture != wrong {
                XCTAssertFalse(node.contains(wrong))
                XCTAssertFalse(vsCode.contains(wrong))
            }
        }
    }

    /// Threaded, not merely spelled the same. Each provisioner is handed
    /// hardware describing a different architecture, and its output has to
    /// follow — otherwise the literals are still in there and the profile
    /// fields are decoration.
    func testProvisionersEmitTheHardwareTheyAreGivenRatherThanALiteral() throws {
        let x86 = LinuxGuestProfile.Hardware(
            architecture: "x86_64",
            utmArchitecture: "x86_64",
            utmTarget: "q35",
            utmFirmwareVarsName: "edk2-i386-vars.fd",
            serialConsoleDevice: "ttyS0",
            linuxArchiveArchitecture: "x64",
                materialsInterface: "SCSI",
            memoryMiB: 4096,
            cpuCount: 4,
            diskSizeGiB: 64
        )
        let generated: [(String, Data)] = [
            ("ubuntu", try UbuntuCloudInit.seedISO(
                credentials: credentials, tools: .recommended, hardware: x86
            )),
            ("fedora", try FedoraCloudInit.seedISO(
                credentials: credentials, tools: .recommended, hardware: x86
            )),
            ("debian", try DebianCloudInit.seedISO(
                credentials: credentials, tools: .recommended, hardware: x86
            )),
            ("opensuse", try OpenSUSECloudInit.seedISO(
                credentials: credentials, tools: .recommended, hardware: x86
            ))
        ]
        for (name, iso) in generated {
            let text = String(decoding: iso, as: UTF8.self)
            let finalizer = try decodedFinalizer(from: text)
            XCTAssertTrue(
                text.contains("serial-getty@ttyS0.service"),
                "\(name) does not mask the serial console it was given"
            )
            XCTAssertTrue(
                finalizer.contains("serial-getty@ttyS0.service"),
                "\(name)'s failure path does not unmask the serial console it was given"
            )
            XCTAssertTrue(finalizer.contains("node-${nodeVersion}-linux-x64.tar.xz"), name)
            XCTAssertTrue(finalizer.contains("linux-x64/stable/latest"), name)
            XCTAssertFalse(text.contains("ttyAMA0"), "\(name) still hardcodes ttyAMA0")
            XCTAssertFalse(finalizer.contains("ttyAMA0"), "\(name) still hardcodes ttyAMA0")
            XCTAssertFalse(finalizer.contains("linux-arm64"), "\(name) still hardcodes arm64")
        }
    }

    /// The finalizer is base64 inside the seed, so architecture assertions have
    /// to decode it rather than match the YAML around it.
    private func decodedFinalizer(from isoText: String) throws -> String {
        let section = try XCTUnwrap(
            isoText.range(of: "- path: /var/lib/sandfort/baseline-finalize.sh")
        )
        let tail = isoText[section.lowerBound...]
        let contentLine = try XCTUnwrap(tail.split(separator: "\n").first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("content: ")
        })
        let encoded = contentLine.trimmingCharacters(in: .whitespaces).dropFirst("content: ".count)
        return String(decoding: try XCTUnwrap(Data(base64Encoded: String(encoded))), as: UTF8.self)
    }

    // MARK: - Firmware

    /// Resolved from the profile passed in, not from a constant path.
    func testFirmwareVariableStoreComesFromTheResolvedProfile() {
        let installation = UTMLauncher.Installation(
            applicationURL: URL(fileURLWithPath: "/Volumes/Tools/UTM.app", isDirectory: true),
            version: "4.7.5"
        )
        XCTAssertEqual(
            installation.firmwareURL(for: LinuxGuestCatalog.defaultProfile).lastPathComponent,
            "edk2-arm-vars.fd"
        )
        let intel = LinuxGuestProfile(
            id: "test-x86",
            revision: 1,
            displayName: "Test x86-64",
            distributionName: "Test",
            utmIconNames: ["ubuntu"],
            setupDurationDescription: "a few minutes",
            image: LinuxGuestCatalog.defaultProfile.image,
            hardware: LinuxGuestProfile.Hardware(
                architecture: "x86_64",
                utmArchitecture: "x86_64",
                utmTarget: "q35",
                utmFirmwareVarsName: "edk2-i386-vars.fd",
                serialConsoleDevice: "ttyS0",
                linuxArchiveArchitecture: "x64",
                materialsInterface: "SCSI",
                memoryMiB: 4096,
                cpuCount: 4,
                diskSizeGiB: 64
            ),
            provisioner: .ubuntu2404
        )
        XCTAssertEqual(
            installation.firmwareURL(for: intel).path,
            "/Volumes/Tools/UTM.app/Contents/Resources/qemu/edk2-i386-vars.fd"
        )
    }

    /// "UTM's ARM64 UEFI firmware" named the wrong file the moment a second
    /// architecture existed, and was needlessly specific before that.
    func testMissingFirmwareErrorDoesNotNameOneArchitecture() throws {
        let message = try XCTUnwrap(SandboxError.utmResourcesMissing.errorDescription)
        XCTAssertFalse(message.contains("ARM64"))
        XCTAssertTrue(message.contains("UEFI firmware"))
        XCTAssertTrue(message.contains("Reinstall"))
    }

    // MARK: - The host, at run time

    /// The live bug: `#if arch(arm64)` describes the slice that is running, so
    /// ticking "Open using Rosetta" made an Apple-silicon Mac report itself as
    /// unsupported. `doctor()` exists to be believed.
    func testRosettaTranslatedProcessStillReportsAppleSilicon() {
        // Rosetta hides hw.optional.arm64 from the translated process, which is
        // exactly why the translation flag has to be consulted separately.
        let translated = HostArchitecture.detected { name in
            name == "sysctl.proc_translated" ? 1 : nil
        }
        XCTAssertEqual(translated, .appleSilicon)
        XCTAssertTrue(HostArchitecture.isTranslated { _ in 1 })
        XCTAssertTrue(
            HostArchitecture.description(architecture: .appleSilicon, translated: true)
                .contains("Rosetta")
        )
    }

    func testAppleSiliconAndIntelAreDetectedFromTheMachineFlags() {
        XCTAssertEqual(
            HostArchitecture.detected { $0 == "hw.optional.arm64" ? 1 : nil },
            .appleSilicon
        )
        XCTAssertEqual(
            HostArchitecture.detected { $0 == "hw.optional.arm64" ? 0 : nil },
            .intel
        )
        XCTAssertEqual(HostArchitecture.detected { _ in nil }, .intel)
        XCTAssertFalse(HostArchitecture.isTranslated { _ in nil })
    }

    /// An unknown name has to read as absent rather than as a stale zero, since
    /// `sysctl.proc_translated` does not exist at all on an Intel Mac.
    func testSysctlReadsRealNamesAndRejectsUnknownOnes() {
        XCTAssertNil(HostArchitecture.integerSysctl("sandfort.no.such.sysctl"))
        XCTAssertNotNil(HostArchitecture.integerSysctl("hw.ncpu"))
    }

    // MARK: - The acceleration guard

    /// UTM's `hasHypervisorSupport` is false whenever the guest architecture
    /// differs from the host's, and when it is false UTM ignores
    /// `"Hypervisor": true` and starts QEMU with `-accel tcg` — silently.
    func testOnlyAMatchingGuestArchitectureCanBeAccelerated() {
        XCTAssertTrue(HostArchitecture.appleSilicon.canHardwareAccelerate("aarch64"))
        XCTAssertFalse(HostArchitecture.appleSilicon.canHardwareAccelerate("x86_64"))
        XCTAssertTrue(HostArchitecture.intel.canHardwareAccelerate("x86_64"))
        XCTAssertFalse(HostArchitecture.intel.canHardwareAccelerate("aarch64"))
    }

    /// Today a no-op — every shipped profile is aarch64 and every supported
    /// host is Apple silicon — but the guard has to exist before the first
    /// x86-64 profile does, because what it prevents looks like a working build
    /// that takes all day.
    func testCreatingAnUnacceleratableBaselineIsRefusedBeforeAnythingHappens() async throws {
        let host = HostArchitecture.current
        let mismatched = host == .appleSilicon ? "x86_64" : "aarch64"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = LinuxGuestProfile(
            id: "test-mismatched-architecture",
            revision: 1,
            displayName: "Test Foreign Guest",
            distributionName: "Test",
            utmIconNames: ["ubuntu"],
            setupDurationDescription: "a few minutes",
            image: LinuxGuestCatalog.defaultProfile.image,
            hardware: LinuxGuestProfile.Hardware(
                architecture: mismatched,
                utmArchitecture: mismatched,
                utmTarget: "virt",
                utmFirmwareVarsName: "edk2-arm-vars.fd",
                serialConsoleDevice: "ttyS0",
                linuxArchiveArchitecture: "x64",
                materialsInterface: "SCSI",
                memoryMiB: 4096,
                cpuCount: 4,
                diskSizeGiB: 64
            ),
            provisioner: .ubuntu2404
        )
        let workflow = SandfortWorkflow(
            environment: .productionWorkspace(
                profile: profile,
                rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            )
        )
        do {
            _ = try await workflow.create(
                profile: profile,
                tools: SandboxToolSelection(python: false, nodeJS: false, vsCode: false),
                event: { _ in }
            )
            XCTFail("a guest this Mac cannot accelerate must be refused")
        } catch let error as SandboxError {
            guard case let .unacceleratedGuestArchitecture(_, guestArchitecture, _) = error else {
                return XCTFail("expected an acceleration refusal, got \(error)")
            }
            XCTAssertEqual(guestArchitecture, mismatched)
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains("Test Foreign Guest"))
            XCTAssertTrue(message.contains(mismatched))
        }
        // Refused before any work: nothing was downloaded and no directory was
        // created, which is the point of putting the guard first.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// The converse, so the guard cannot be satisfied by refusing everything.
    func testEveryShippedProfileIsAcceleratableOnASupportedHost() {
        for profile in LinuxGuestCatalog.profiles {
            XCTAssertTrue(
                HostArchitecture.appleSilicon
                    .canHardwareAccelerate(profile.hardware.utmArchitecture),
                "\(profile.id) cannot be accelerated on the only host Sandfort supports"
            )
        }
    }

    // MARK: - What doctor() now reports

    func testDoctorReportsTheMachineItsMemoryAndItsFreeSpace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workflow = SandfortWorkflow(
            environment: .productionWorkspace(
                profile: LinuxGuestCatalog.defaultProfile,
                rootURL: root,
                cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
            )
        )
        let report = try await workflow.doctor()
        XCTAssertTrue(report.contains("This Mac is"))
        XCTAssertTrue(report.contains(HostArchitecture.current.name))
        XCTAssertTrue(report.contains("of memory"), "host RAM is not reported")
        XCTAssertTrue(report.contains("free for sandboxes"), "free space is not reported")
        // Nothing about a stale compile-time answer.
        XCTAssertFalse(report.contains("unsupported architecture"))
    }
}
