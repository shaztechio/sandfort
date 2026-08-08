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

/// A read-only disc image built from something the user chose, ready to attach
/// to one clean instance.
///
/// The guest is handed **this**, never the user's file. That is the whole
/// security argument for the feature: guest-to-host is impossible by
/// construction rather than by configuration, so it does not depend on a plist
/// key, a QEMU flag, or any promise UTM makes.
struct MaterialsImage: Sendable {
    /// The ISO 9660 image.
    let data: Data
    /// What the guest will see the file called, after sanitisation.
    let displayName: String
    /// Where it came from, kept for display only. Never re-read to rebuild an
    /// image — see `SandfortWorkflow`'s materials store for why.
    let sourcePath: String
    /// The payload's size, not the image's.
    let byteCount: Int
    /// True when a folder was archived to get here, so the UI can say the guest
    /// will find one `.zip` rather than the folder itself.
    let payloadIsArchive: Bool

    /// The payload is deliberately **not** retained beside the image. Holding
    /// both would double peak memory for a 512 MiB pick, which is the exact cost
    /// the limit in `MaterialsPackager` exists to bound. Anything that needs the
    /// payload reads it back out of `data`, where it already is.
    fileprivate init(
        data: Data, displayName: String, sourcePath: String,
        byteCount: Int, payloadIsArchive: Bool
    ) {
        self.data = data
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.byteCount = byteCount
        self.payloadIsArchive = payloadIsArchive
    }

    /// Where the single entry's bytes start in the image. The writer lays the
    /// root directory at block 20 and the first file at 21.
    static let payloadBlock = 21
}

/// Turns a file or folder on the host into a `MaterialsImage`.
///
/// Deliberately free of UI and UTM: everything here is testable without a
/// hypervisor, and nothing here decides whether an image may be attached — that
/// is `UTMBundleBuilder`'s job, so the "clean instances only" rule has one
/// enforcement point rather than two.
enum MaterialsPackager {
    /// The guest finds the image by this label, and `HELP.md` prints the mount
    /// command literally, so it must not vary with what the user picked.
    static let volumeName = "SANDFORT_MATERIALS"
    static let isoIdentifier = "MATERIAL;1"

    /// The binding constraint is memory, not disk. `ISO9660Writer.make` builds
    /// the whole image at once while the caller still holds the payload, so peak
    /// use is roughly twice this — on a Mac that is simultaneously running a
    /// 4 GiB guest.
    ///
    /// **Raising this means streaming the writer to a `FileHandle` first**, with
    /// its own test. Anything much larger is also a sign the user wants an
    /// Internet-enabled launch and a `git clone`, which this feature does not
    /// replace.
    static let maximumPayloadBytes = 512 * 1024 * 1024

    /// A folder is measured before it is archived. Compression means the archive
    /// may come in far under the real limit, so this only rejects the
    /// pathological case — zipping tens of gigabytes to discover the answer is
    /// minutes of work and a full disk.
    static let maximumUnarchivedBytes = 4 * 1024 * 1024 * 1024

    static func pack(contentsOf url: URL) throws -> MaterialsImage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SandboxError.materialsUnreadable("\(url.lastPathComponent) could not be found.")
        }

        let payload: Data
        let archived: Bool
        if isDirectory.boolValue {
            try refuseUnarchivedFolderThatIsFarTooLarge(url)
            payload = try archive(url)
            archived = true
        } else {
            try refuseFileTooLargeToPack(url)
            payload = try read(url)
            archived = false
        }

        guard !payload.isEmpty else {
            throw SandboxError.materialsUnreadable(
                "\(url.lastPathComponent) is empty, so there is nothing to send in."
            )
        }
        guard payload.count <= maximumPayloadBytes else {
            throw SandboxError.materialsTooLarge(
                byteCount: payload.count, limit: maximumPayloadBytes
            )
        }

        let name = sanitized(url.lastPathComponent, addingExtension: archived ? "zip" : nil)
        let image = try ISO9660Writer.make(volumeName: volumeName, files: [
            ISO9660Writer.File(isoIdentifier: isoIdentifier, name: name, data: payload)
        ])
        return MaterialsImage(
            data: image,
            displayName: name,
            sourcePath: url.path,
            byteCount: payload.count,
            payloadIsArchive: archived
        )
    }

    // MARK: - Reading

    /// Checked from the file's reported size, before a byte is read. Reading
    /// first would mean paging in gigabytes only to throw them away.
    private static func refuseFileTooLargeToPack(_ url: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard let size else {
            throw SandboxError.materialsUnreadable("\(url.lastPathComponent) could not be read.")
        }
        guard size <= maximumPayloadBytes else {
            throw SandboxError.materialsTooLarge(byteCount: size, limit: maximumPayloadBytes)
        }
    }

    private static func refuseUnarchivedFolderThatIsFarTooLarge(_ url: URL) throws {
        var total = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            throw SandboxError.materialsUnreadable("\(url.lastPathComponent) could not be read.")
        }
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += size
            if total > maximumUnarchivedBytes {
                throw SandboxError.materialsTooLarge(
                    byteCount: total, limit: maximumPayloadBytes
                )
            }
        }
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SandboxError.materialsUnreadable(
                "\(url.lastPathComponent) could not be read: \(error.localizedDescription)"
            )
        }
    }

    /// Archives a folder using the same system facility the share sheet uses.
    ///
    /// Deliberately not a hand-written archive writer. This app has already paid
    /// for byte-level format code once; a tar writer looks like a hundred lines
    /// until it meets long names, symlinks, permissions, and extended attributes,
    /// and every one of those is a directory-walk edge case.
    private static func archive(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var archived: Result<Data, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: [.forUploading], error: &coordinationError
        ) { readable in
            archived = Result { try Data(contentsOf: readable, options: .mappedIfSafe) }
        }
        if let coordinationError {
            throw SandboxError.materialsUnreadable(
                "\(url.lastPathComponent) could not be archived: \(coordinationError.localizedDescription)"
            )
        }
        switch archived {
        case let .success(data): return data
        case let .failure(error):
            throw SandboxError.materialsUnreadable(
                "\(url.lastPathComponent) could not be archived: \(error.localizedDescription)"
            )
        case nil:
            throw SandboxError.materialsUnreadable("\(url.lastPathComponent) could not be archived.")
        }
    }

    // MARK: - Naming

    /// The Rock Ridge name is parsed by the guest kernel and becomes a filename,
    /// so it is reduced to a conservative set rather than passed through.
    ///
    /// Truncating rather than refusing is deliberate: the user picked a
    /// legitimate file, and the length of its name is not a problem they should
    /// have to solve to use the feature.
    static func sanitized(_ rawName: String, addingExtension extra: String?) -> String {
        var name = rawName
        if let extra { name += ".\(extra)" }
        let allowed = name.map { character -> Character in
            let usable = character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "." || character == "_" || character == "-")
            return usable ? character : "_"
        }
        var sanitized = String(allowed)
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            sanitized = "materials"
        }
        // Keep the extension, which is what tells the user what they are looking
        // at, and trim the stem instead.
        if sanitized.utf8.count > ISO9660Writer.maximumNameBytes {
            let suffix = sanitized.contains(".")
                ? "." + (sanitized.split(separator: ".").last.map(String.init) ?? "")
                : ""
            let room = max(1, ISO9660Writer.maximumNameBytes - suffix.utf8.count)
            sanitized = String(sanitized.prefix(room)) + suffix
        }
        return sanitized
    }
}
