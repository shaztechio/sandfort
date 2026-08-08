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

/// openSUSE's setup verifies that the udisks2 volume monitor exists, because
/// without that binary Files offers no removable media at all and a materials
/// disc is invisible. The first version of that check named three plausible
/// directories, and Leap 16 uses a fourth — `/usr/libexec/gvfs/`.
///
/// The result was worse than the gap it closed. Every package installed
/// correctly, the desktop was complete, and setup failed anyway after 143
/// seconds of work, leaving a baseline that could not be used. A verification
/// that can fail on a working guest destroys rebuilds for no reason.
///
/// So the check searches for the binary instead of asserting where it lives.
/// These tests run the generated command for real against temporary trees, in
/// each known layout — including the one that broke — and against a tree where
/// it is genuinely missing, so the check cannot quietly become one that always
/// passes.
final class OpenSUSEVolumeMonitorCheckTests: XCTestCase {
    private let binaryName = "gvfs-udisks2-volume-monitor"

    /// The check as the guest actually receives it: extracted from the base64
    /// finalizer embedded in the generated cloud-config, not retyped here.
    private func generatedCheck() throws -> String {
        let profile = LinuxGuestCatalog.opensuseLeap16ARM64
        let text = String(
            decoding: try profile.seedISO(
                credentials: profile.credentials(), tools: .recommended
            ),
            as: UTF8.self
        )
        let marker = try XCTUnwrap(text.range(of: "encoding: b64"))
        let afterMarker = text[marker.upperBound...]
        let contentKey = try XCTUnwrap(afterMarker.range(of: "content: "))
        let blob = afterMarker[contentKey.upperBound...]
            .prefix { !$0.isNewline }
        let decoded = try XCTUnwrap(Data(base64Encoded: String(blob)))
        let script = String(decoding: decoded, as: UTF8.self)

        let line = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains(binaryName) },
            "the generated setup script no longer checks for \(binaryName)"
        )
        return String(line)
    }

    /// Rewrites the three real search roots to temporary ones so the command can
    /// be executed on this Mac without touching `/usr`.
    private func run(_ check: String, roots: [URL]) throws -> Int32 {
        let redirected = check.replacingOccurrences(
            of: "/usr/lib /usr/lib64 /usr/libexec",
            with: roots.map { "'\($0.path)'" }.joined(separator: " ")
        )
        XCTAssertNotEqual(
            redirected, check,
            "the check no longer searches the three roots this test redirects"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", redirected]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func tree() throws -> [URL] {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return try ["lib", "lib64", "libexec"].map { name in
            let root = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            return root
        }
    }

    private func placeBinary(
        in root: URL, subdirectory: String?, executable: Bool = true
    ) throws -> URL {
        var directory = root
        if let subdirectory {
            directory = root.appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        let binary = directory.appendingPathComponent(binaryName)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: binary.path
        )
        return binary
    }

    /// Every layout the binary is known to ship in, each one on its own.
    func testTheCheckFindsTheBinaryInEveryKnownLayout() throws {
        let check = try generatedCheck()

        // (search root index, subdirectory) — index 2 is libexec.
        let layouts: [(Int, String?, String)] = [
            (2, "gvfs", "openSUSE Leap 16: /usr/libexec/gvfs/"),
            (2, nil, "/usr/libexec/"),
            (0, "gvfs", "/usr/lib/gvfs/"),
            (1, "gvfs", "/usr/lib64/gvfs/")
        ]

        for (index, subdirectory, description) in layouts {
            let roots = try tree()
            _ = try placeBinary(in: roots[index], subdirectory: subdirectory)
            XCTAssertEqual(
                try run(check, roots: roots), 0,
                "the check must locate the volume monitor at \(description)"
            )
        }
    }

    /// The check has to still fail when the binary is absent, or replacing three
    /// hardcoded paths with a search would have turned a real verification into
    /// one that always passes — which is how the missing file manager reached a
    /// user in the first place.
    func testTheCheckStillFailsWhenTheBinaryIsMissing() throws {
        let check = try generatedCheck()
        let roots = try tree()

        // Populated, but with the wrong thing: an empty tree could pass for a
        // check that failed to search at all.
        _ = try placeBinary(in: roots[2], subdirectory: "gvfs")
        try FileManager.default.moveItem(
            at: roots[2].appendingPathComponent("gvfs/\(binaryName)"),
            to: roots[2].appendingPathComponent("gvfs/gvfs-something-else")
        )

        XCTAssertNotEqual(
            try run(check, roots: roots), 0,
            "a guest without the volume monitor must fail verification"
        )
    }

    /// Present but not executable is the same failure: Files cannot spawn it.
    func testAFileThatCannotBeExecutedDoesNotSatisfyTheCheck() throws {
        let check = try generatedCheck()
        let roots = try tree()
        _ = try placeBinary(in: roots[2], subdirectory: "gvfs", executable: false)

        XCTAssertNotEqual(
            try run(check, roots: roots), 0,
            "a non-executable file is not a working volume monitor"
        )
    }
}
