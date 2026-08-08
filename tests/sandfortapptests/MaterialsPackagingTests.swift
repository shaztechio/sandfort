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

/// Packing is the only path by which a file from the user's Mac reaches a
/// sandbox, so what it accepts and what it refuses is a security boundary, not a
/// convenience. The guest is handed a copy Sandfort built — never the original —
/// which is what makes the reverse direction impossible by construction.
final class MaterialsPackagingTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func file(_ name: String, bytes: Int = 32, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    // MARK: - What comes out

    func testAPickedFilePassesThroughUnchanged() throws {
        let root = try workspace()
        let source = try file("take-home.zip", bytes: 4096, in: root)

        let image = try MaterialsPackager.pack(contentsOf: source)

        XCTAssertEqual(image.displayName, "take-home.zip")
        XCTAssertEqual(image.byteCount, 4096, "a file is carried as-is, not re-archived")
        XCTAssertEqual(image.sourcePath, source.path)
    }

    /// A folder cannot go on the image as a folder — the writer is flat — so it
    /// is archived first. `NSFileCoordinator` does this with a system API rather
    /// than a hand-written archive format, which is the whole reason this feature
    /// adds no new byte-level code.
    func testAPickedFolderBecomesASingleZip() throws {
        let root = try workspace()
        let folder = root.appendingPathComponent("challenge", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try file("challenge/main.py", in: root)
        _ = try file("challenge/src/lib.py", in: root)

        let image = try MaterialsPackager.pack(contentsOf: folder)

        XCTAssertEqual(image.displayName, "challenge.zip")
        XCTAssertTrue(image.payloadIsArchive, "a folder is reported as archived, so the UI can say so")

        // The payload really is a zip. Read from the image rather than from a
        // retained copy: keeping the payload beside the ISO would double peak
        // memory, which is the cost the size limit exists to bound.
        let start = MaterialsImage.payloadBlock * 2048
        XCTAssertEqual(
            image.data.subdata(in: start..<(start + 4)), Data([0x50, 0x4B, 0x03, 0x04]),
            "the bytes on the image start with the zip magic"
        )
    }

    // MARK: - The image is mountable and correctly labelled

    func testTheImageIsAnISOWithTheExpectedVolumeAndEntry() throws {
        let root = try workspace()
        let image = try MaterialsPackager.pack(contentsOf: try file("notes.txt", in: root))

        XCTAssertEqual(image.data.subdata(in: 32769..<32774), Data("CD001".utf8))
        let volume = String(decoding: image.data.subdata(in: 32808..<32826), as: UTF8.self)
        XCTAssertEqual(volume, MaterialsPackager.volumeName,
                       "the guest finds this by label, so it is a fixed constant")

        let text = String(decoding: image.data, as: UTF8.self)
        XCTAssertTrue(text.contains("MATERIAL;1"))
        XCTAssertTrue(text.contains("notes.txt"), "the Rock Ridge name is what the guest sees")
    }

    /// The label must not vary with what the user picked: the mount instructions
    /// in HELP name it literally, and a per-file label would make them wrong.
    func testTheVolumeLabelDoesNotDependOnTheSource() throws {
        let root = try workspace()
        for name in ["a.zip", "totally-different-name.tar.gz"] {
            let image = try MaterialsPackager.pack(contentsOf: try file(name, in: root))
            let volume = String(decoding: image.data.subdata(in: 32808..<32826), as: UTF8.self)
            XCTAssertEqual(volume, MaterialsPackager.volumeName)
        }
    }

    // MARK: - Names are sanitised, because the guest kernel parses them

    func testHostileAndAwkwardNamesAreSanitised() throws {
        let root = try workspace()
        let cases = [
            ("my challenge.zip", "my_challenge.zip"),
            ("emoji🎉.zip", "emoji_.zip"),
            ("..hidden.zip", "..hidden.zip")
        ]
        for (given, expected) in cases {
            let image = try MaterialsPackager.pack(contentsOf: try file(given, bytes: 8, in: root))
            XCTAssertEqual(image.displayName, expected, "\(given) should sanitise to \(expected)")
        }
    }

    /// A name long enough to trap the ISO writer must be truncated here rather
    /// than rejected — the user picked a legitimate file, and its name is not
    /// their problem to fix.
    ///
    /// 200 characters, not 300: a single path component is capped at 255 bytes,
    /// so a 300-character name cannot be created to test with. That limit is
    /// also why the writer's 201-byte trap was hard to reach from a real file —
    /// and exactly why it should not be relied on, since the name reaching the
    /// writer need not have come from the filesystem.
    func testAnOverlongNameIsTruncatedRatherThanRefused() throws {
        let root = try workspace()
        let long = String(repeating: "n", count: 200) + ".zip"
        let image = try MaterialsPackager.pack(contentsOf: try file(long, bytes: 8, in: root))

        XCTAssertLessThanOrEqual(image.displayName.utf8.count, ISO9660Writer.maximumNameBytes)
        XCTAssertTrue(image.displayName.hasSuffix(".zip"), "the extension survives truncation")
    }

    /// And the lengths the filesystem will not let a test create are checked
    /// against the sanitiser directly, since nothing guarantees a name reaching
    /// it came from a file on disk.
    func testSanitisationBoundsAnyLengthItIsGiven() {
        for count in [65, 201, 300, 5000] {
            let name = MaterialsPackager.sanitized(
                String(repeating: "n", count: count) + ".zip", addingExtension: nil
            )
            XCTAssertLessThanOrEqual(
                name.utf8.count, ISO9660Writer.maximumNameBytes,
                "a \(count)-character name must be bounded, not passed to the writer"
            )
            XCTAssertNoThrow(try ISO9660Writer.validate(
                volumeName: MaterialsPackager.volumeName,
                entries: [.init(identifier: MaterialsPackager.isoIdentifier, name: name, byteCount: 1)]
            ), "whatever the sanitiser returns must be something the writer accepts")
        }
    }

    // MARK: - Refusals

    /// The size is read before the bytes are. Packing something enormous only to
    /// throw it away would take minutes and gigabytes of memory.
    func testAnOversizedFileIsRefusedFromItsSizeAlone() throws {
        let root = try workspace()
        let big = root.appendingPathComponent("huge.bin")
        // Sparse: the file reports its size without occupying it.
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(MaterialsPackager.maximumPayloadBytes) + 1)
        try handle.close()

        XCTAssertThrowsError(try MaterialsPackager.pack(contentsOf: big)) { error in
            guard case .materialsTooLarge = error as? SandboxError else {
                return XCTFail("expected .materialsTooLarge, got \(error)")
            }
        }
    }

    /// A folder is measured before it is archived, and the refusal must not
    /// conflate the two thresholds. `total` is unarchived content; the 512 MiB
    /// limit applies to the archive. Reporting one as the other would tell
    /// someone their 3 GB folder fits inside a 512 MB limit.
    ///
    /// The ceiling is injected so this needs a folder of a few bytes rather than
    /// four gigabytes.
    func testAnEnormousFolderIsRefusedBeforeItIsArchived() throws {
        let root = try workspace()
        let folder = root.appendingPathComponent("huge", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try file("huge/a.bin", bytes: 512, in: root)
        _ = try file("huge/b.bin", bytes: 512, in: root)

        XCTAssertThrowsError(
            try MaterialsPackager.pack(contentsOf: folder, unarchivedCeiling: 100)
        ) { error in
            guard case let .materialsSourceTooLargeToArchive(byteCount, packedLimit)
                    = error as? SandboxError else {
                return XCTFail("expected .materialsSourceTooLargeToArchive, got \(error)")
            }
            XCTAssertGreaterThan(byteCount, 100, "it reports what it measured")
            XCTAssertEqual(
                packedLimit, MaterialsPackager.maximumPayloadBytes,
                "and names the limit that will actually apply, not the ceiling it tripped"
            )
            let message = (error as? SandboxError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("before"), "the message separates the two measures")
            XCTAssertTrue(message.contains("once archived"), "and says which one is the real limit")
        }
    }

    func testAMissingSourceIsRefused() throws {
        let root = try workspace()
        XCTAssertThrowsError(
            try MaterialsPackager.pack(contentsOf: root.appendingPathComponent("nope.zip"))
        ) { error in
            guard case .materialsUnreadable = error as? SandboxError else {
                return XCTFail("expected .materialsUnreadable, got \(error)")
            }
        }
    }

    func testAnEmptyFileIsRefusedRatherThanProducingAnEmptyImage() throws {
        let root = try workspace()
        XCTAssertThrowsError(
            try MaterialsPackager.pack(contentsOf: try file("empty.bin", bytes: 0, in: root))
        ) { error in
            guard case .materialsUnreadable = error as? SandboxError else {
                return XCTFail("expected .materialsUnreadable, got \(error)")
            }
        }
    }
}
