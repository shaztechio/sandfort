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

enum ISO9660Writer {
    private static let blockSize = 2048

    /// Bounds are stated rather than emergent. Every one of them was previously
    /// a trap or a silent overwrite reachable from a caller's input, which was
    /// tolerable only while the sole inputs were cloud-init's two constants.
    static let maximumEntries = 8
    static let maximumNameBytes = 64
    static let maximumVolumeNameBytes = 32
    /// The size field is a `UInt32` in both endiannesses.
    static let maximumFileBytes = Int(UInt32.max)

    /// One file destined for the image.
    ///
    /// `isoIdentifier` is supplied rather than derived. It used to be assigned by
    /// position — entry 0 got `USER_DAT;1` and everything else got `META_DAT;1` —
    /// so a third file silently produced a duplicate identifier.
    struct File {
        let isoIdentifier: String
        let name: String
        let data: Data

        init(isoIdentifier: String, name: String, data: Data) {
            self.isoIdentifier = isoIdentifier
            self.name = name
            self.data = data
        }
    }

    /// What `validate` needs: sizes are declared rather than held, so a bound can
    /// be checked without allocating the payload it describes.
    struct Entry {
        let identifier: String
        let name: String
        let byteCount: Int

        init(identifier: String, name: String, byteCount: Int) {
            self.identifier = identifier
            self.name = name
            self.byteCount = byteCount
        }
    }

    /// Rejects anything `make` could not encode. Separate from `make` because the
    /// 4 GiB size bound is otherwise untestable: proving it through `make` would
    /// mean allocating four gigabytes.
    static func validate(volumeName: String, entries: [Entry]) throws {
        func fail(_ reason: String) throws -> Never {
            throw SandboxError.invalidISOImage(reason)
        }

        let volume = volumeName.uppercased()
        guard (1...maximumVolumeNameBytes).contains(volume.utf8.count),
              volume.allSatisfy(isDCharacter) else {
            try fail("the volume name must be 1 to \(maximumVolumeNameBytes) characters of A–Z, 0–9, or _")
        }
        guard !entries.isEmpty else { try fail("an image needs at least one file") }
        guard entries.count <= maximumEntries else {
            try fail("an image holds at most \(maximumEntries) files")
        }

        var seen = Set<String>()
        for entry in entries {
            guard isValidIdentifier(entry.identifier) else {
                try fail("\"\(entry.identifier)\" is not a valid ISO 9660 identifier")
            }
            guard seen.insert(entry.identifier).inserted else {
                try fail("two files share the identifier \"\(entry.identifier)\"")
            }
            let nameBytes = entry.name.utf8.count
            guard (1...maximumNameBytes).contains(nameBytes), isValidName(entry.name) else {
                try fail("\"\(entry.name)\" is not a usable file name")
            }
            guard (0...maximumFileBytes).contains(entry.byteCount) else {
                try fail("\"\(entry.name)\" is too large for an ISO 9660 image")
            }
        }

        // The root directory is declared as exactly one sector, and the writer
        // does not bounds-check against it — overflowing it used to overwrite the
        // first file's data with no trap and no error.
        //
        // The entry-count and name-length bounds above already make that
        // unreachable: the largest directory they permit is about half a sector.
        // This stays as the backstop for whoever raises one of those constants,
        // and `testTheBoundsMakeADirectoryOverflowUnreachable` is what tells them
        // the relationship existed.
        let directoryBytes = directoryRecordLength(identifierBytes: 1, includeSUSP: true)
            + directoryRecordLength(identifierBytes: 1)
            + entries.reduce(0) {
                $0 + directoryRecordLength(
                    identifierBytes: $1.identifier.utf8.count,
                    rockRidgeNameBytes: $1.name.utf8.count
                )
            }
        guard directoryBytes <= blockSize else {
            try fail("those file names do not fit in this image's directory")
        }

        let totalBlocks = entries.reduce(21) { $0 + max(1, blocks(for: $1.byteCount)) }
        guard totalBlocks <= Int(UInt32.max) else { try fail("the image is too large") }
    }

    static func make(volumeName: String, files: [File]) throws -> Data {
        try validate(
            volumeName: volumeName,
            entries: files.map {
                Entry(identifier: $0.isoIdentifier, name: $0.name, byteCount: $0.data.count)
            }
        )
        let rootBlock = 20
        var nextBlock = rootBlock + 1
        let entries = files.map { file -> (File, Int) in
            defer { nextBlock += max(1, blocks(for: file.data.count)) }
            return (file, nextBlock)
        }
        let totalBlocks = nextBlock
        var image = Data(repeating: 0, count: totalBlocks * blockSize)

        writePrimaryDescriptor(into: &image, volumeName: volumeName, blocks: totalBlocks, rootBlock: rootBlock)
        writeTerminator(into: &image)
        writePathTable(into: &image, block: 18, rootBlock: rootBlock, bigEndian: false)
        writePathTable(into: &image, block: 19, rootBlock: rootBlock, bigEndian: true)

        var directory = Data()
        directory.append(directoryRecord(identifier: Data([0]), extent: rootBlock, size: blockSize, isDirectory: true, includeSUSP: true))
        directory.append(directoryRecord(identifier: Data([1]), extent: rootBlock, size: blockSize, isDirectory: true))
        for (file, extent) in entries {
            directory.append(directoryRecord(
                identifier: Data(file.isoIdentifier.utf8),
                extent: extent,
                size: file.data.count,
                isDirectory: false,
                rockRidgeName: file.name
            ))
        }
        replace(&image, at: rootBlock * blockSize, with: directory)
        for (file, extent) in entries {
            replace(&image, at: extent * blockSize, with: file.data)
        }
        return image
    }

    /// The one place a record's length is computed, used by both `validate` and
    /// the writer so the bound and the bytes cannot drift apart.
    private static func directoryRecordLength(
        identifierBytes: Int,
        rockRidgeNameBytes: Int? = nil,
        includeSUSP: Bool = false
    ) -> Int {
        var systemUse = includeSUSP ? 7 : 0
        if let rockRidgeNameBytes { systemUse += 10 + rockRidgeNameBytes }
        let padding = identifierBytes.isMultiple(of: 2) ? 1 : 0
        return 33 + identifierBytes + padding + systemUse
    }

    /// ISO 9660 d-characters, the only ones valid in a volume identifier.
    private static func isDCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isUppercase || character.isNumber || character == "_")
    }

    /// `NAME;1`, or `NAME.EXT;1` — 8.3 with a version suffix.
    private static func isValidIdentifier(_ identifier: String) -> Bool {
        guard identifier.hasSuffix(";1") else { return false }
        let stem = identifier.dropLast(2)
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        guard (1...8).contains(parts[0].count), parts[0].allSatisfy(isDCharacter) else { return false }
        if parts.count == 2 {
            guard parts[1].count <= 3, parts[1].allSatisfy(isDCharacter) else { return false }
        }
        return true
    }

    /// The Rock Ridge NM value is parsed by the guest kernel and becomes a
    /// filename, so it is bounded hard rather than passed through. A separator or
    /// a relative path in it is not a filename.
    private static func isValidName(_ name: String) -> Bool {
        guard name != ".", name != ".." else { return false }
        return name.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "." || character == "_" || character == "-")
        }
    }

    private static func writePrimaryDescriptor(
        into image: inout Data,
        volumeName: String,
        blocks: Int,
        rootBlock: Int
    ) {
        var descriptor = Data(repeating: 0, count: blockSize)
        descriptor[0] = 1
        replace(&descriptor, at: 1, with: Data("CD001".utf8))
        descriptor[6] = 1
        writePadded("SWIFT", into: &descriptor, at: 8, length: 32)
        writePadded(volumeName.uppercased(), into: &descriptor, at: 40, length: 32)
        writeBothEndian(UInt32(blocks), into: &descriptor, at: 80)
        writeBothEndian(UInt16(1), into: &descriptor, at: 120)
        writeBothEndian(UInt16(1), into: &descriptor, at: 124)
        writeBothEndian(UInt16(blockSize), into: &descriptor, at: 128)
        writeBothEndian(UInt32(10), into: &descriptor, at: 132)
        writeLittle(UInt32(18), into: &descriptor, at: 140)
        writeBig(UInt32(19), into: &descriptor, at: 148)
        replace(&descriptor, at: 156, with: directoryRecord(
            identifier: Data([0]), extent: rootBlock, size: blockSize, isDirectory: true
        ))
        descriptor[881] = 1
        let timestamp = volumeTimestamp()
        for offset in [813, 830, 847, 864] {
            replace(&descriptor, at: offset, with: timestamp)
        }
        replace(&image, at: 16 * blockSize, with: descriptor)
    }

    private static func writeTerminator(into image: inout Data) {
        var terminator = Data(repeating: 0, count: blockSize)
        terminator[0] = 255
        replace(&terminator, at: 1, with: Data("CD001".utf8))
        terminator[6] = 1
        replace(&image, at: 17 * blockSize, with: terminator)
    }

    private static func writePathTable(into image: inout Data, block: Int, rootBlock: Int, bigEndian: Bool) {
        var table = Data(repeating: 0, count: 10)
        table[0] = 1
        if bigEndian {
            writeBig(UInt32(rootBlock), into: &table, at: 2)
            writeBig(UInt16(1), into: &table, at: 6)
        } else {
            writeLittle(UInt32(rootBlock), into: &table, at: 2)
            writeLittle(UInt16(1), into: &table, at: 6)
        }
        table[8] = 0
        replace(&image, at: block * blockSize, with: table)
    }

    private static func directoryRecord(
        identifier: Data,
        extent: Int,
        size: Int,
        isDirectory: Bool,
        rockRidgeName: String? = nil,
        includeSUSP: Bool = false
    ) -> Data {
        var systemUse = Data()
        if includeSUSP {
            systemUse.append(contentsOf: [0x53, 0x50, 7, 1, 0xbe, 0xef, 0]) // SUSP SP
        }
        if let rockRidgeName {
            let name = Data(rockRidgeName.utf8)
            systemUse.append(contentsOf: [0x52, 0x52, 5, 1, 0x08]) // RR: NM is present
            systemUse.append(contentsOf: [0x4e, 0x4d, UInt8(5 + name.count), 1, 0]) // NM
            systemUse.append(name)
        }
        let identifierPadding = identifier.count.isMultiple(of: 2) ? 1 : 0
        let length = 33 + identifier.count + identifierPadding + systemUse.count
        var record = Data(repeating: 0, count: length)
        record[0] = UInt8(length)
        writeBothEndian(UInt32(extent), into: &record, at: 2)
        writeBothEndian(UInt32(size), into: &record, at: 10)
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: Date())
        record[18] = UInt8(max(0, (components.year ?? 2000) - 1900))
        record[19] = UInt8(components.month ?? 1)
        record[20] = UInt8(components.day ?? 1)
        record[21] = UInt8(components.hour ?? 0)
        record[22] = UInt8(components.minute ?? 0)
        record[23] = UInt8(components.second ?? 0)
        record[24] = 0
        record[25] = isDirectory ? 2 : 0
        writeBothEndian(UInt16(1), into: &record, at: 28)
        record[32] = UInt8(identifier.count)
        replace(&record, at: 33, with: identifier)
        replace(&record, at: 33 + identifier.count + identifierPadding, with: systemUse)
        return record
    }

    private static func volumeTimestamp() -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return Data((formatter.string(from: Date()) + "00").utf8) + Data([0])
    }

    private static func blocks(for count: Int) -> Int {
        (count + blockSize - 1) / blockSize
    }

    private static func writePadded(_ value: String, into data: inout Data, at offset: Int, length: Int) {
        let bytes = Data(value.utf8.prefix(length))
        data.replaceSubrange(offset..<(offset + length), with: Data(repeating: 0x20, count: length))
        replace(&data, at: offset, with: bytes)
    }

    private static func replace(_ target: inout Data, at offset: Int, with source: Data) {
        target.replaceSubrange(offset..<(offset + source.count), with: source)
    }

    private static func writeBothEndian(_ value: UInt16, into data: inout Data, at offset: Int) {
        writeLittle(value, into: &data, at: offset)
        writeBig(value, into: &data, at: offset + 2)
    }

    private static func writeBothEndian(_ value: UInt32, into data: inout Data, at offset: Int) {
        writeLittle(value, into: &data, at: offset)
        writeBig(value, into: &data, at: offset + 4)
    }

    private static func writeLittle<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { replace(&data, at: offset, with: Data($0)) }
    }

    private static func writeBig<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { replace(&data, at: offset, with: Data($0)) }
    }
}
