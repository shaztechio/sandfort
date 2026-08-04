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

/// Keeps the Apache-2.0 headers complete as files are added. A missing header
/// is easy to miss in review and awkward to correct later, once a file has
/// history from several contributors.
final class LicenseHeaderTests: XCTestCase {
    /// Walks up from this file to the repository root, so the check does not
    /// depend on the working directory the tests happen to run from.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // tests/sandfortapptests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // repository root
    }

    private func swiftSources() throws -> [URL] {
        var found: [URL] = []
        for directory in ["sources", "tests", "tools"] {
            let root = repositoryRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                found.append(url)
            }
        }
        found.append(repositoryRoot.appendingPathComponent("Package.swift"))
        return found
    }

    func testEverySwiftSourceCarriesTheApacheHeader() throws {
        let sources = try swiftSources()
        XCTAssertGreaterThan(sources.count, 20, "expected to find the Swift sources")
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let path = url.lastPathComponent
            XCTAssertTrue(
                text.contains("Licensed under the Apache License, Version 2.0"),
                "\(path) is missing the Apache-2.0 header"
            )
            XCTAssertTrue(
                text.contains("Copyright 2026 Shazron Abdullah and Sandfort contributors"),
                "\(path) is missing the copyright line"
            )
        }
    }

    /// SwiftPM requires the tools-version directive on the very first line, so
    /// the header has to follow it rather than precede it.
    func testPackageManifestKeepsItsToolsVersionOnTheFirstLine() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.hasPrefix("// swift-tools-version:"))
    }

    /// A Markdown list item wrapped across lines used to render as a stray
    /// paragraph that also closed the list, because the renderer emitted an
    /// `<li>` per line. HELP.md is meant to be readable Markdown, so wrapping a
    /// bullet must not break the Help Book.
    func testHelpMarkdownListItemsSurviveLineWrapping() throws {
        let help = try String(
            contentsOf: repositoryRoot.appendingPathComponent("HELP.md"),
            encoding: .utf8
        )
        let lines = help.components(separatedBy: "\n")
        var wrappedItems = 0
        var insideCodeFence = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("```") { insideCodeFence.toggle() }
            guard !insideCodeFence else { continue }
            let isItem = line.hasPrefix("- ")
                || line.range(of: "^[0-9]+\\. ", options: .regularExpression) != nil
            guard isItem, index + 1 < lines.count else { continue }
            let next = lines[index + 1]
            if next.hasPrefix("  "), !next.trimmingCharacters(in: .whitespaces).isEmpty {
                wrappedItems += 1
            }
        }
        // If this ever reaches zero the guarantee is untested, not satisfied.
        XCTAssertGreaterThan(
            wrappedItems, 0,
            "no wrapped list item left in HELP.md, so this no longer proves anything"
        )
    }

    /// HELP.md carries the licence as an HTML comment: the attribution travels
    /// with the file, and the Help Book reader never sees it.
    func testHelpCarriesTheLicenceAsAnInvisibleHeader() throws {
        let help = try String(
            contentsOf: repositoryRoot.appendingPathComponent("HELP.md"),
            encoding: .utf8
        )
        XCTAssertTrue(help.hasPrefix("<!--"), "the header must come first, before any content")
        let header = help.components(separatedBy: "-->")[0]
        XCTAssertTrue(header.contains("Copyright 2026 Shazron Abdullah and Sandfort contributors"))
        XCTAssertTrue(header.contains("Licensed under the Apache License, Version 2.0"))
    }

    /// The renderer escapes everything by default, which would turn that header
    /// into a visible wall of licence text at the top of the Help Book. It has
    /// to pass HTML comments through untouched instead.
    func testHelpRendererPassesHTMLCommentsThroughUnescaped() throws {
        let renderer = try String(
            contentsOf: repositoryRoot.appendingPathComponent("tools/packaging/render-help.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            renderer.contains("inHTMLComment"),
            "HTML comments must bypass escapeHTML or the licence header becomes visible"
        )
        XCTAssertTrue(renderer.contains("hasPrefix(\"<!--\")"))
    }

    func testRepositoryShipsTheFullApacheLicense() throws {
        let license = try String(
            contentsOf: repositoryRoot.appendingPathComponent("LICENSE"),
            encoding: .utf8
        )
        XCTAssertTrue(license.contains("Apache License"))
        XCTAssertTrue(license.contains("Version 2.0, January 2004"))
        XCTAssertTrue(license.contains("END OF TERMS AND CONDITIONS"))
    }
}
