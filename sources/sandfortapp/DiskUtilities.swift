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
import Darwin
import Foundation

enum DiskUtilities {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func resizeQCOW2(at url: URL, toGiB sizeGiB: UInt64) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 48), header.count == 48 else {
            throw SandboxError.invalidCloudDisk("the QCOW2 header is incomplete")
        }
        guard Array(header.prefix(4)) == [0x51, 0x46, 0x49, 0xfb] else {
            throw SandboxError.invalidCloudDisk("the QCOW2 signature is missing")
        }
        let version = UInt32(bigEndianBytes: header[4..<8])
        guard version == 2 || version == 3 else {
            throw SandboxError.invalidCloudDisk("unsupported QCOW2 version \(version)")
        }
        let oldSize = UInt64(bigEndianBytes: header[24..<32])
        let newSize = sizeGiB * 1024 * 1024 * 1024
        guard newSize >= oldSize else {
            throw SandboxError.invalidCloudDisk("the requested disk size is smaller than the image")
        }

        let clusterBits = UInt32(bigEndianBytes: header[20..<24])
        guard (9...21).contains(clusterBits) else {
            throw SandboxError.invalidCloudDisk("unsupported QCOW2 cluster size")
        }
        let clusterSize = UInt64(1) << clusterBits
        let l2Entries = clusterSize / 8
        let bytesPerL1Entry = clusterSize * l2Entries
        let oldL1Size = UInt64(UInt32(bigEndianBytes: header[36..<40]))
        let newL1Size = (newSize + bytesPerL1Entry - 1) / bytesPerL1Entry
        let l1Offset = UInt64(bigEndianBytes: header[40..<48])
        let allocatedL1Bytes = ((oldL1Size * 8 + clusterSize - 1) / clusterSize) * clusterSize
        guard oldL1Size > 0, l1Offset.isMultiple(of: clusterSize), newL1Size * 8 <= allocatedL1Bytes else {
            throw SandboxError.invalidCloudDisk("the requested size exceeds the QCOW2 L1 table allocation")
        }

        if oldSize == newSize, oldL1Size >= newL1Size { return }

        if newL1Size > oldL1Size {
            try handle.seek(toOffset: l1Offset + oldL1Size * 8)
            try handle.write(contentsOf: Data(repeating: 0, count: Int((newL1Size - oldL1Size) * 8)))
            var encodedL1Size = UInt32(newL1Size).bigEndian
            try handle.seek(toOffset: 36)
            try withUnsafeBytes(of: &encodedL1Size) { try handle.write(contentsOf: Data($0)) }
        }
        var encoded = newSize.bigEndian
        try handle.seek(toOffset: 24)
        try withUnsafeBytes(of: &encoded) { bytes in
            try handle.write(contentsOf: Data(bytes))
        }
        try handle.synchronize()
        try validateQCOW2Geometry(at: url)
    }

    static func validateQCOW2Geometry(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 48), header.count == 48,
              Array(header.prefix(4)) == [0x51, 0x46, 0x49, 0xfb] else {
            throw SandboxError.invalidCloudDisk("the QCOW2 header is incomplete")
        }
        let clusterBits = UInt32(bigEndianBytes: header[20..<24])
        guard (9...21).contains(clusterBits) else {
            throw SandboxError.invalidCloudDisk("unsupported QCOW2 cluster size")
        }
        let clusterSize = UInt64(1) << clusterBits
        let bytesPerL1Entry = clusterSize * clusterSize / 8
        let virtualSize = UInt64(bigEndianBytes: header[24..<32])
        let l1Size = UInt64(UInt32(bigEndianBytes: header[36..<40]))
        let requiredL1Size = (virtualSize + bytesPerL1Entry - 1) / bytesPerL1Entry
        guard l1Size >= requiredL1Size else {
            throw SandboxError.invalidCloudDisk("L1 table is too small (has \(l1Size) entries, needs \(requiredL1Size))")
        }
    }

    static func ensureNotInUse(_ url: URL) throws {
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        var fileLock = flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        if fcntl(descriptor, F_SETLK, &fileLock) == -1 {
            if errno == EACCES || errno == EAGAIN { throw SandboxError.virtualMachineRunning }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        fileLock.l_type = Int16(F_UNLCK)
        _ = fcntl(descriptor, F_SETLK, &fileLock)
    }
}

private extension UInt32 {
    init(bigEndianBytes bytes: Data.SubSequence) {
        self = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

private extension UInt64 {
    init(bigEndianBytes bytes: Data.SubSequence) {
        self = bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
