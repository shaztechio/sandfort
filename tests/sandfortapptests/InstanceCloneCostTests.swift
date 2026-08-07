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

import Darwin
import XCTest
@testable import SandfortApp

/// Issue #7 asked whether a QCOW2 backing file should replace the per-instance
/// copy of the baseline disk, on the premise that `FileManager.copyItem` byte-copies
/// roughly 6 GB per instance. It does not. On APFS `copyItem` clones: the copy is
/// made by sharing the source's extents, and the kernel splits a block only when
/// one side writes to it.
///
/// Measured on a real Ubuntu baseline bundle, 5.68 GiB allocated:
/// 0.005 s, a 0.002 GiB volume free-space delta, and all 4,000 sampled logical
/// offsets in the copy mapping to the same physical device offset as the source.
/// The same file byte-copied with `copyfile(COPYFILE_DATA)` took 5.5 s per 2 GiB.
/// `du` reports the full size for each clone because it counts blocks per file, so
/// two 6 GB numbers that sum to 13 GB can be the same 6 GB counted twice — which
/// is what the issue's measurement was.
///
/// So the storage win a backing file offers is already there, and it arrives
/// without the coupling: a clone is independent the instant it exists, while a
/// backing file would make every instance a permanent dependant of the baseline
/// that `Rebuild` deletes. See `docs/security-model.md`.
///
/// These cases exist to keep that true. The property is invisible — an instance
/// built by a streaming byte copy behaves identically and only costs time and
/// disk — so nothing else would notice a refactor that lost it.
final class InstanceCloneCostTests: XCTestCase {
    // MARK: - Extent inspection

    /// Physical device offset backing `byte` of the file, via `F_LOG2PHYS_EXT`.
    /// Two files whose logical offsets resolve to the same physical offset are
    /// sharing storage.
    private func physicalOffset(of url: URL, atByte byte: off_t) -> Int64? {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = log2phys()
        info.l2p_flags = 0
        info.l2p_contigbytes = 4096
        info.l2p_devoffset = byte
        guard fcntl(descriptor, F_LOG2PHYS_EXT, &info) != -1 else { return nil }
        return info.l2p_devoffset
    }

    /// Flush before inspecting: an extent that is still a dirty page has no
    /// physical address to report yet.
    private func flush(_ url: URL) {
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_FULLFSYNC)
    }

    /// Cloning is a filesystem capability, not a guarantee. A test volume without
    /// it says nothing about the property under test.
    private func requireCloningVolume(at root: URL) throws {
        let source = root.appendingPathComponent("clone-probe")
        let destination = root.appendingPathComponent("clone-probe-copy")
        try Data("probe".utf8).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw XCTSkip("the test volume does not support file cloning (\(String(cString: strerror(errno)))")
        }
        guard physicalOffset(of: source, atByte: 0) != nil else {
            throw XCTSkip("the test volume does not report physical extents")
        }
    }

    private let sampleStride: off_t = 256 * 1024

    /// Compares the extents of two files at every `sampleStride` boundary and
    /// returns the offsets that resolve to different physical storage.
    private func unsharedOffsets(_ a: URL, _ b: URL, from first: off_t = 0) -> [off_t] {
        flush(a)
        flush(b)
        let limit = min(fileSize(a), fileSize(b))
        var unshared: [off_t] = []
        var offset = first
        while offset < limit {
            defer { offset += sampleStride }
            guard let left = physicalOffset(of: a, atByte: offset),
                  let right = physicalOffset(of: b, atByte: offset) else { continue }
            if left != right { unshared.append(offset) }
        }
        return unshared
    }

    private func fileSize(_ url: URL) -> off_t {
        var status = stat()
        stat(url.path, &status)
        return status.st_size
    }

    // MARK: - Fixture

    /// A QCOW2 the resize path accepts, padded with incompressible data so there
    /// are real extents to compare. Cluster bits 16, seven L1 entries at offset
    /// 0x10000 — the header the existing resize tests use.
    private func writeImage(at url: URL, payloadMiB: Int = 8) throws {
        var header = Data(repeating: 0, count: 128 * 1024)
        header.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])
        header.replaceSubrange(4..<8, with: [0, 0, 0, 3])
        header.replaceSubrange(20..<24, with: [0, 0, 0, 16])
        header.replaceSubrange(36..<40, with: [0, 0, 0, 7])
        header.replaceSubrange(40..<48, with: [0, 0, 0, 0, 0, 1, 0, 0])
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for _ in 0..<payloadMiB {
            var block = Data(count: 1024 * 1024)
            block.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for index in 0..<words.count { words[index] = UInt64.random(in: 0...UInt64.max) }
            }
            try handle.write(contentsOf: block)
        }
        try handle.synchronize()
    }

    private struct Fixture {
        let root: URL
        let setup: URL
        let instance: URL
        let profile: LinuxGuestProfile
        let builder: UTMBundleBuilder
        var baselineDisk: URL { setup.appendingPathComponent("Data/sandfort.qcow2") }
        var instanceDisk: URL { instance.appendingPathComponent("Data/sandfort.qcow2") }
    }

    /// Builds a baseline and one instance through the real provider calls.
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try requireCloningVolume(at: root)

        let image = root.appendingPathComponent("source.qcow2")
        try writeImage(at: image)
        let firmware = root.appendingPathComponent("firmware.fd")
        try Data(repeating: 0xa5, count: 4096).write(to: firmware)

        let profile = LinuxGuestCatalog.defaultProfile
        let builder = UTMBundleBuilder(firmwareURLOverride: firmware)
        let setup = root.appendingPathComponent("Setup.utm", isDirectory: true)
        try builder.createSetupBundle(
            at: setup,
            name: "Sandfort — Protected Baseline CLONE01",
            from: image,
            profile: profile,
            credentials: SandboxCredentials(username: "sandfort", password: "safe-test"),
            tools: .recommended
        )
        let instance = root.appendingPathComponent("Instance1.utm", isDirectory: true)
        try builder.createCleanBundle(
            from: setup,
            at: instance,
            name: "Sandfort — Instance 1 — CLONE01",
            profile: profile,
            networkMode: .offline
        )
        return Fixture(root: root, setup: setup, instance: instance, profile: profile, builder: builder)
    }

    // MARK: - Cases

    /// The claim the issue disputed. Every sampled block of a new instance's disk
    /// is the baseline's block until something writes to it.
    func testCreatingAnInstanceSharesTheBaselineDiskRatherThanCopyingIt() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            unsharedOffsets(fixture.baselineDisk, fixture.instanceDisk), [],
            "a new instance must clone the baseline disk, not byte-copy it"
        )
    }

    /// The same has to hold for the download: four environments built from one
    /// cached image must not cost four copies of it.
    func testABaselineClonesTheVerifiedImageItWasBuiltFrom() throws {
        let fixture = try makeFixture()
        let image = fixture.root.appendingPathComponent("source.qcow2")
        // The first two 64 KiB clusters are excluded on purpose. `resizeQCOW2`
        // rewrites the virtual size in the header cluster and extends the L1
        // table in the one after it; those two writes are exactly the
        // copy-on-write splits they should be, and nothing beyond them moves.
        XCTAssertEqual(
            unsharedOffsets(image, fixture.baselineDisk, from: 128 * 1024), [],
            "a baseline must clone the cached image apart from the metadata resize rewrites"
        )
    }

    /// **Reset & Run Clean** restores the instance from the baseline. That path
    /// removes the disk and copies it again, so it has to clone as well —
    /// otherwise every reset pays the copy that creation avoided.
    func testResettingAnInstanceRestoresItByCloningToo() throws {
        let fixture = try makeFixture()
        let handle = try FileHandle(forUpdating: fixture.instanceDisk)
        try handle.seek(toOffset: 3 * 1024 * 1024)
        try handle.write(contentsOf: Data(repeating: 0xcc, count: 1024 * 1024))
        try handle.synchronize()
        try handle.close()

        try fixture.builder.resetCleanBundle(
            from: fixture.setup,
            at: fixture.instance,
            profile: fixture.profile,
            networkMode: .offline
        )
        XCTAssertEqual(
            unsharedOffsets(fixture.baselineDisk, fixture.instanceDisk, from: 128 * 1024), [],
            "reset must restore the instance by cloning the baseline disk"
        )
    }

    /// The security half, and the reason this is not the same thing as a QCOW2
    /// backing file. Shared extents are copy-on-write in the kernel: a write
    /// through the instance's disk splits the block and cannot reach the
    /// baseline. A backing file shares at the image layer instead, where the
    /// guest's own hypervisor does the writing.
    func testWritingToAnInstanceCannotReachTheBaseline() throws {
        let fixture = try makeFixture()
        let offset: off_t = 4 * 1024 * 1024
        let before = try Data(contentsOf: fixture.baselineDisk)

        let handle = try FileHandle(forUpdating: fixture.instanceDisk)
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data(repeating: 0x5a, count: 128 * 1024))
        try handle.synchronize()
        try handle.close()

        XCTAssertEqual(
            try Data(contentsOf: fixture.baselineDisk), before,
            "an instance's writes must never appear in the protected baseline"
        )
        let unshared = unsharedOffsets(fixture.baselineDisk, fixture.instanceDisk)
        XCTAssertTrue(
            unshared.contains(offset),
            "the written block must have been split away from the baseline's storage"
        )
        XCTAssertFalse(
            unshared.contains(offset + 1024 * 1024),
            "only the written blocks split; the rest stays shared"
        )
    }
}
