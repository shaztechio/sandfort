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

/// The image was verified in the shared cache and used from the bundle, with a
/// window in between. `verifiedImage` hashed the cached file and returned its
/// URL; `createSetupBundle` copied from that URL afterwards. Whatever the file
/// contained at copy time is what the VM booted, verified or not.
///
/// Found independently by the Gemini and Claude passes of the security review
/// (issues #11 and #18). Both rated it Low/Informational, and correctly: winning
/// this race needs a local process that can already overwrite the baseline
/// qcow2 or replace `Sandfort.app` outright. It is fixed anyway because
/// "verified before use" is only a useful sentence when the verified bytes and
/// the used bytes are the same bytes.
///
/// The fix is one SHA-256 of the bundle's own disk, between the copy and the
/// resize that mutates it. Measured on an Apple silicon SSD, hashing the largest
/// catalog image (Ubuntu, 590 MB) takes about 0.48s with the buffer cache
/// bypassed — against a baseline creation that then spends 10-45 minutes
/// provisioning the guest.
final class BundleImageVerificationTests: XCTestCase {
    /// A QCOW2 valid enough for `resizeQCOW2` to accept and grow: signature,
    /// version 3, 64 KiB clusters, a 2 GiB virtual size below the profile's, and
    /// an L1 table with room to spare.
    ///
    /// `payload` distinguishes two otherwise identical images. A substituted
    /// image only has to be a *valid* QCOW2 to sail past every check the builder
    /// used to make, which is the whole point of the finding: the header
    /// arithmetic in `resizeQCOW2` is not an authenticity check.
    private func minimalQCOW2(payload: UInt8) -> Data {
        var image = Data(repeating: 0, count: 128 * 1024)
        image.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])        // "QFI\xfb"
        image.replaceSubrange(4..<8, with: [0, 0, 0, 3])                    // version 3
        image.replaceSubrange(20..<24, with: [0, 0, 0, 16])                 // 64 KiB clusters
        image.replaceSubrange(24..<32, with: [0, 0, 0, 0, 0x80, 0, 0, 0])   // 2 GiB virtual size
        image.replaceSubrange(36..<40, with: [0, 0, 0, 7])                  // L1 entries
        image.replaceSubrange(40..<48, with: [0, 0, 0, 0, 0, 1, 0, 0])      // L1 at 64 KiB
        image[100_000] = payload                                            // guest bytes
        return image
    }

    /// A profile identical to the shipped Ubuntu one except for the pinned
    /// checksum, so the test can pin whatever it actually wrote to the cache.
    private func profile(pinning sha256: String) -> LinuxGuestProfile {
        let ubuntu = LinuxGuestCatalog.defaultProfile
        return LinuxGuestProfile(
            id: ubuntu.id,
            revision: ubuntu.revision,
            displayName: ubuntu.displayName,
            distributionName: ubuntu.distributionName,
            utmIconNames: ubuntu.utmIconNames,
            setupDurationDescription: ubuntu.setupDurationDescription,
            image: LinuxGuestProfile.Image(
                url: ubuntu.image.url,
                sha256: sha256,
                fileName: ubuntu.image.fileName,
                downloadSizeDescription: ubuntu.image.downloadSizeDescription
            ),
            hardware: ubuntu.hardware,
            provisioner: ubuntu.provisioner
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func firmware(in root: URL) throws -> URL {
        let firmware = root.appendingPathComponent("firmware.fd")
        try Data(repeating: 0xa5, count: 4096).write(to: firmware)
        return firmware
    }

    private func credentials() -> SandboxCredentials {
        SandboxCredentials(username: "sandfort", password: "safe-test-password")
    }

    /// The whole race, in order: verify the cached image the way the workflow
    /// does, swap the file for a different valid QCOW2, then build the bundle.
    /// The substituted bytes must never become a bootable disk.
    func testASwappedCachedImageIsRejectedWhenTheBundleIsBuilt() throws {
        let root = try temporaryRoot()
        let cached = root.appendingPathComponent("ubuntu-cloudimg.img")
        try minimalQCOW2(payload: 0x11).write(to: cached)

        // What `SandfortWorkflow.verifiedImage` does, and where the window opens.
        let verified = try DiskUtilities.sha256(of: cached)
        let profile = profile(pinning: verified)

        // The hostile local process, between the check and the use.
        try minimalQCOW2(payload: 0x22).write(to: cached)
        let substituted = try DiskUtilities.sha256(of: cached)
        XCTAssertNotEqual(substituted, verified, "the swap must actually change the file")

        let bundle = root.appendingPathComponent("Setup.utm", isDirectory: true)
        let builder = UTMBundleBuilder(firmwareURLOverride: try firmware(in: root))
        XCTAssertThrowsError(
            try builder.createSetupBundle(
                at: bundle,
                name: "Sandfort — Baseline Setup TEST01",
                from: cached,
                profile: profile,
                credentials: credentials(),
                tools: .recommended
            ),
            "an image that changed after verification must not become a VM disk"
        ) { error in
            guard case let SandboxError.imageChangedBeforeUse(expected, actual) = error else {
                return XCTFail("expected a verification failure, got \(error)")
            }
            XCTAssertEqual(expected, verified)
            XCTAssertEqual(actual, substituted)
        }

        // Loud, and nothing left behind for a later step, or a user, to mistake
        // for a usable baseline.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundle.path),
            "a rejected bundle must not survive as a half-built one"
        )
    }

    /// The check has to be on the copy, not on the source. Hashing the cache
    /// again would pass here and still boot whatever landed in the bundle.
    func testAnUnchangedImageStillBuildsABundle() throws {
        let root = try temporaryRoot()
        let cached = root.appendingPathComponent("ubuntu-cloudimg.img")
        try minimalQCOW2(payload: 0x11).write(to: cached)
        let profile = profile(pinning: try DiskUtilities.sha256(of: cached))

        let bundle = root.appendingPathComponent("Setup.utm", isDirectory: true)
        try UTMBundleBuilder(firmwareURLOverride: try firmware(in: root)).createSetupBundle(
            at: bundle,
            name: "Sandfort — Baseline Setup TEST01",
            from: cached,
            profile: profile,
            credentials: credentials(),
            tools: .recommended
        )

        let disk = bundle.appendingPathComponent("Data/sandfort.qcow2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.path))
        // Resized afterwards, so the verified bytes are the ones the resize ran
        // on rather than the other way around.
        let header = try Data(contentsOf: disk).prefix(32)
        XCTAssertEqual(
            Array(header[24..<32]),
            [0, 0, 0, 16, 0, 0, 0, 0],
            "the disk is grown to the profile's 64 GiB after it verifies"
        )
    }

    /// Ordering, pinned by the diagnosis. A substitute that is not a QCOW2 at all
    /// would fail `resizeQCOW2` with `invalidCloudDisk` if the resize ran first.
    /// Reporting `imageChangedBeforeUse` instead proves the hash runs before
    /// anything writes to the copy — which is also the difference between "this
    /// file is corrupt" and "this file is not the one that was verified".
    func testUnverifiedBytesAreRejectedBeforeTheResizeTouchesThem() throws {
        let root = try temporaryRoot()
        let cached = root.appendingPathComponent("ubuntu-cloudimg.img")
        try Data(repeating: 0x5a, count: 128 * 1024).write(to: cached)
        let profile = profile(pinning: String(repeating: "0", count: 64))

        let bundle = root.appendingPathComponent("Setup.utm", isDirectory: true)
        XCTAssertThrowsError(
            try UTMBundleBuilder(firmwareURLOverride: try firmware(in: root)).createSetupBundle(
                at: bundle,
                name: "Sandfort — Baseline Setup TEST01",
                from: cached,
                profile: profile,
                credentials: credentials(),
                tools: .recommended
            )
        ) { error in
            guard case SandboxError.imageChangedBeforeUse = error else {
                return XCTFail("verification must run before the resize, got \(error)")
            }
        }
    }

    /// A pre-existing directory at the destination is not this method's to
    /// delete. Cleanup after a failure removes what the call created, and
    /// nothing else.
    func testFailureLeavesAPreExistingDestinationDirectoryAlone() throws {
        let root = try temporaryRoot()
        let cached = root.appendingPathComponent("ubuntu-cloudimg.img")
        try minimalQCOW2(payload: 0x11).write(to: cached)
        let profile = profile(pinning: String(repeating: "0", count: 64))

        let bundle = root.appendingPathComponent("Setup.utm", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let bystander = bundle.appendingPathComponent("keep-me.txt")
        try Data("keep me".utf8).write(to: bystander)

        XCTAssertThrowsError(
            try UTMBundleBuilder(firmwareURLOverride: try firmware(in: root)).createSetupBundle(
                at: bundle,
                name: "Sandfort — Baseline Setup TEST01",
                from: cached,
                profile: profile,
                credentials: credentials(),
                tools: .recommended
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent("Data/sandfort.qcow2").path
            ),
            "the unverified copy must go even when the directory around it stays"
        )
    }
}
