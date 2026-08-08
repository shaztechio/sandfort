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

/// The ISO writer used to trap rather than throw, and every trap was reachable
/// from a filename or a file size. That was survivable while its only inputs
/// were the two constants cloud-init needs; it is not survivable now a user can
/// choose what goes in.
///
/// A `try?` cannot catch a Swift trap — the same lesson `OpenPGPSignatureVerifier`
/// records. Every case here therefore asserts a *throw*, and several could not be
/// written at all against the previous API, which is the strongest evidence the
/// hardening was needed.
final class ISO9660WriterHardeningTests: XCTestCase {
    private func entry(
        identifier: String = "MATERIAL;1",
        name: String = "materials.zip",
        byteCount: Int = 16
    ) -> ISO9660Writer.Entry {
        ISO9660Writer.Entry(identifier: identifier, name: name, byteCount: byteCount)
    }

    private func assertRejects(
        _ volumeName: String = "SANDFORT_MATERIALS",
        entries: [ISO9660Writer.Entry],
        _ why: String,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ISO9660Writer.validate(volumeName: volumeName, entries: entries), why, line: line
        ) { error in
            guard case .invalidISOImage = error as? SandboxError else {
                return XCTFail("expected .invalidISOImage, got \(error)", line: line)
            }
        }
    }

    // MARK: - The three conditions that used to trap

    /// `record[0] = UInt8(length)` where `length = 54 + nameByteCount`, so a name
    /// over 201 bytes ended the process. 300 is comfortably past it.
    func testAnOverlongNameIsRejectedRatherThanTrapping() {
        assertRejects(entries: [entry(name: String(repeating: "a", count: 300))],
                      "a 300-byte name must throw, not trap")
    }

    /// The NM entry length is `UInt8(5 + name.count)`, a second trap at 250 —
    /// past the record-length one, so it is only reachable if the first is fixed
    /// carelessly. Both are covered by the same bound.
    func testTheNameBoundIsEnforcedAtItsEdge() throws {
        XCTAssertNoThrow(try ISO9660Writer.validate(
            volumeName: "SANDFORT_MATERIALS",
            entries: [entry(name: String(repeating: "a", count: 64))]
        ), "64 bytes is the documented limit and must be accepted")
        assertRejects(entries: [entry(name: String(repeating: "a", count: 65))],
                      "65 bytes is over the limit")
    }

    /// `writeBothEndian(UInt32(size), ...)` trapped at 4 GiB.
    ///
    /// This case is the reason validation is separate from writing: asserting it
    /// through `make` would mean allocating four gigabytes to prove a bound.
    func testAFileAtFourGiBIsRejectedWithoutAllocatingIt() {
        assertRejects(entries: [entry(byteCount: 0x1_0000_0000)],
                      "a 4 GiB payload must be rejected by declared size alone")
        XCTAssertNoThrow(try ISO9660Writer.validate(
            volumeName: "SANDFORT_MATERIALS",
            entries: [entry(byteCount: 0xFFFF_FFFF)]
        ), "one byte under the limit is still expressible in the format")
    }

    // MARK: - The condition that silently corrupted the image

    /// The root directory is declared as exactly one sector, and `replace` has no
    /// bounds check — so a directory over 2048 bytes overwrote the first file's
    /// data with no trap and no error. Silent corruption is worse than a crash.
    ///
    /// The entry-count and name-length bounds make that unreachable rather than
    /// merely unlikely: the largest directory they permit is well under a sector.
    /// This asserts that relationship, because it is the reason the corruption
    /// cannot happen — and it is exactly what would stop being true if someone
    /// later raised `maximumEntries` or `maximumNameBytes`. The guard inside
    /// `validate` stays as the backstop for that day; this test is what tells
    /// them they need it.
    func testTheBoundsMakeADirectoryOverflowUnreachable() throws {
        let worstCase = (0..<ISO9660Writer.maximumEntries).map {
            entry(
                identifier: "FILE\($0)0AB;1",
                name: String(repeating: "n", count: ISO9660Writer.maximumNameBytes)
            )
        }
        XCTAssertNoThrow(
            try ISO9660Writer.validate(volumeName: "SANDFORT_MATERIALS", entries: worstCase),
            "the largest directory the bounds permit must still fit one sector"
        )
        // And the count bound is the thing enforcing it.
        assertRejects(
            entries: worstCase + [entry(identifier: "ONEMORE;1", name: "extra.zip")],
            "more entries than the bound allows must be refused"
        )
    }

    // MARK: - The identifier collision

    /// Identifiers used to be assigned by position — entry 0 got `USER_DAT;1` and
    /// every other entry got `META_DAT;1` — so a third file silently produced a
    /// duplicate ISO9660 identifier. They are now supplied and must be unique.
    func testDuplicateIdentifiersAreRejected() {
        assertRejects(entries: [entry(identifier: "SAME_ID;1", name: "a.zip"),
                                entry(identifier: "SAME_ID;1", name: "b.zip")],
                      "two entries cannot share an ISO9660 identifier")
    }

    func testMalformedIdentifiersAreRejected() {
        for bad in ["lowercase;1", "NOVERSION", "TOOLONGIDENT;1", "SPACE D;1", ";1", "OK;2"] {
            assertRejects(entries: [entry(identifier: bad)], "\(bad) is not a valid identifier")
        }
    }

    // MARK: - Names that are structural, not decorative

    /// The Rock Ridge NM value is parsed by the guest kernel and used as a
    /// filename. A separator or a relative path in it is not a filename.
    func testNamesThatAreNotFilenamesAreRejected() {
        for bad in ["", ".", "..", "a/b.zip", "a\u{0}b", "sp ace.zip", "emoji🎉.zip"] {
            assertRejects(entries: [entry(name: bad)], "\(bad.debugDescription) is not a usable name")
        }
    }

    func testAnEmptyFileListIsRejectedRatherThanTrippingAPrecondition() {
        assertRejects(entries: [], "an empty image is a programming error, but it must still throw")
    }

    func testAMalformedVolumeNameIsRejected() {
        for bad in ["", String(repeating: "V", count: 33), "has space", "lower🎉"] {
            assertRejects(bad, entries: [entry()], "\(bad.debugDescription) is not a valid volume name")
        }
    }

    // MARK: - The happy path still produces a mountable image

    func testASingleEntryImageIsWellFormed() throws {
        let payload = Data(repeating: 0xAB, count: 3 * 1024 * 1024)
        let image = try ISO9660Writer.make(volumeName: "SANDFORT_MATERIALS", files: [
            ISO9660Writer.File(isoIdentifier: "MATERIAL;1", name: "materials.zip", data: payload)
        ])

        XCTAssertEqual(image.subdata(in: 32769..<32774), Data("CD001".utf8), "PVD signature")
        let volume = String(decoding: image.subdata(in: 32808..<32826), as: UTF8.self)
        XCTAssertEqual(volume, "SANDFORT_MATERIALS", "volume identifier at its fixed offset")

        let text = String(decoding: image, as: UTF8.self)
        XCTAssertTrue(text.contains("MATERIAL;1"), "the supplied identifier reaches the directory")
        XCTAssertTrue(text.contains("materials.zip"), "the Rock Ridge name reaches the directory")
        XCTAssertFalse(text.contains("USER_DAT;1"), "no identifier is invented by position any more")

        // The payload must be readable at a sector boundary, which is what makes
        // the image mountable rather than merely well-labelled.
        let start = 21 * 2048
        XCTAssertEqual(image.subdata(in: start..<(start + 16)), Data(repeating: 0xAB, count: 16))
    }
}
