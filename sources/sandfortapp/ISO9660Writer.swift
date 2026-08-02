// Copyright 2026 Sandfort contributors
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

    static func make(volumeName: String, files: [(name: String, data: Data)]) throws -> Data {
        precondition(!files.isEmpty)
        let rootBlock = 20
        var nextBlock = rootBlock + 1
        let entries = files.map { file -> (String, Data, Int) in
            defer { nextBlock += max(1, blocks(for: file.data.count)) }
            return (file.name, file.data, nextBlock)
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
        for (index, entry) in entries.enumerated() {
            directory.append(directoryRecord(
                identifier: Data((index == 0 ? "USER_DAT;1" : "META_DAT;1").utf8),
                extent: entry.2,
                size: entry.1.count,
                isDirectory: false,
                rockRidgeName: entry.0
            ))
        }
        replace(&image, at: rootBlock * blockSize, with: directory)
        for entry in entries {
            replace(&image, at: entry.2 * blockSize, with: entry.1)
        }
        return image
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
