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

/// The launch summary answers "what is in this sandbox" immediately before
/// untrusted code runs in it.
final class InstanceLaunchSummaryTests: XCTestCase {
    private let profile = LinuxGuestCatalog.defaultProfile

    private func instance(
        number: Int = 1,
        label: String? = nil,
        materials: String? = nil,
        bytes: Int? = nil,
        isArchive: Bool? = nil
    ) -> SandboxInstance {
        var instance = SandboxInstance(
            number: number,
            bundlePath: "/tmp/Instance\(number).utm",
            vmName: "Sandfort — Instance \(number)",
            label: label
        )
        instance.materialsDisplayName = materials
        instance.materialsByteCount = materials == nil ? nil : (bytes ?? 6144)
        instance.materialsPackedAt = materials == nil ? nil : Date()
        instance.materialsIsArchive = isArchive
        return instance
    }

    private func lines(
        _ instance: SandboxInstance,
        tools: SandboxToolSelection? = .recommended,
        network: InstanceLaunchSummary.Network = .chosen(.offline)
    ) -> [String] {
        InstanceLaunchSummary.lines(
            instance: instance, profile: profile, tools: tools, network: network
        )
    }

    // MARK: - The security constraint

    /// The formatter is handed a `SandboxToolSelection` that *contains* the
    /// custom setup script, and the activity log has a copy button. Neither the
    /// script's contents nor the guest password may ever reach it.
    func testNoLineEverCarriesTheScriptContentsOrTheGuestPassword() {
        let secret = "correct-horse-battery-staple"
        var tools = SandboxToolSelection.recommended
        tools.customSetupScript = """
        #!/bin/sh
        export API_TOKEN=\(secret)
        echo "\(secret)" > /root/.netrc
        """

        let credentials = profile.credentials()
        let produced = lines(instance(materials: "materials.zip"), tools: tools).joined(separator: "\n")

        XCTAssertFalse(produced.contains(secret), "the script's contents reached the log: \(produced)")
        XCTAssertFalse(produced.contains("API_TOKEN"), produced)
        XCTAssertFalse(produced.contains("#!/bin/sh"), produced)
        XCTAssertFalse(
            produced.contains(credentials.password),
            "the guest password reached the log"
        )
    }

    /// A host path is not needed to answer what is in the sandbox, and the log
    /// gets pasted into issues.
    func testTheSourcePathOnTheUsersMacIsNotLogged() {
        var withSource = instance(materials: "challenge.zip")
        withSource.materialsSourcePath = "/Users/someone/Documents/Private/challenge"

        let produced = lines(withSource).joined(separator: "\n")

        XCTAssertFalse(produced.contains("/Users/someone"), produced)
        XCTAssertTrue(produced.contains("challenge.zip"), "the name is still said: \(produced)")
    }

    // MARK: - Materials

    func testMaterialsAreNamedWithTheirSizeAndReadOnlyNature() {
        let produced = lines(instance(materials: "materials-probe.txt", bytes: 6144))

        let line = try? XCTUnwrap(produced.first { $0.hasPrefix("Materials:") })
        XCTAssertEqual(
            line, "Materials: materials-probe.txt (6 KB), read-only."
        )
    }

    /// None attached is a normal state, and testing showed the per-instance
    /// scoping is not obvious — so silence would read as an unanswered question.
    func testAnInstanceWithoutMaterialsSaysSoRatherThanSayingNothing() {
        let produced = lines(instance())

        XCTAssertTrue(
            produced.contains("Materials: none attached."),
            "an instance with none must still get a materials line: \(produced)"
        )
    }

    func testAFolderIsDescribedAsAnArchive() {
        let produced = lines(instance(materials: "project.zip", isArchive: true)).joined(separator: "\n")

        XCTAssertTrue(produced.contains("a folder sent as one .zip archive"), produced)
    }

    // MARK: - Tools and the custom script

    func testSelectedToolsAreListedEvenThoughTheyDoNotVaryBetweenInstances() {
        let produced = lines(instance()).joined(separator: "\n")

        XCTAssertTrue(produced.contains("Baseline tools: Git, curl, jq, Python 3, Node.js LTS, Visual Studio Code."), produced)
    }

    func testUnselectedToolsAreNotClaimed() {
        var tools = SandboxToolSelection.recommended
        tools.python = false
        tools.nodeJS = false
        tools.vsCode = false

        let produced = lines(instance(), tools: tools).joined(separator: "\n")

        XCTAssertTrue(produced.contains("Baseline tools: Git, curl, jq."), produced)
        XCTAssertFalse(produced.contains("Python"), produced)
        XCTAssertFalse(produced.contains("Visual Studio Code"), produced)
    }

    /// A custom script is arbitrary root-level change to the guest, which is a
    /// materially different statement from "it has Python".
    func testACustomSetupScriptGetsItsOwnLine() {
        var tools = SandboxToolSelection.recommended
        tools.customSetupScript = "apt-get install -y cowsay"

        let produced = lines(instance(), tools: tools)

        XCTAssertTrue(
            produced.contains { $0.contains("custom setup script") && $0.contains("as root") },
            "\(produced)"
        )
        XCTAssertFalse(
            produced.contains { $0.hasPrefix("Baseline tools:") && $0.contains("custom") },
            "the script must not be folded into the tool list: \(produced)"
        )
    }

    func testNoCustomScriptLineWhenThereIsNoScript() {
        for script in [nil, "", "   \n  "] as [String?] {
            var tools = SandboxToolSelection.recommended
            tools.customSetupScript = script
            XCTAssertFalse(
                lines(instance(), tools: tools).contains { $0.contains("custom setup script") },
                "script \(String(describing: script)) must not produce a line"
            )
        }
    }

    /// State written before tool selections were persisted has none. Defaulting
    /// to `.recommended` would state as fact that Python, Node and VS Code are
    /// in a guest nobody recorded anything about.
    func testAnUnrecordedToolSelectionIsNotInvented() {
        let produced = lines(instance(), tools: nil).joined(separator: "\n")

        XCTAssertTrue(produced.contains("Baseline tools: not recorded"), produced)
        XCTAssertFalse(produced.contains("Python"), produced)
        XCTAssertFalse(produced.contains("Visual Studio Code"), produced)
        XCTAssertTrue(produced.contains("Materials:"), "the rest is still described: \(produced)")
    }

    // MARK: - Identity and network

    func testTheFirstLineNamesTheInstanceAndDistribution() {
        let produced = lines(instance(number: 2, label: "coding challenge"))

        XCTAssertTrue(produced[0].contains("Instance 2"), produced[0])
        XCTAssertTrue(produced[0].contains("coding challenge"), "the label is part of the title: \(produced[0])")
        XCTAssertTrue(produced[0].contains(profile.displayName), produced[0])
    }

    func testAChosenNetworkModeIsStated() {
        XCTAssertTrue(lines(instance(), network: .chosen(.offline))[0].contains("offline"))
        XCTAssertTrue(
            lines(instance(), network: .chosen(.internet))[0].contains("Internet-enabled")
        )
    }

    /// Resume preserves whatever the instance last ran with, and the workflow
    /// never reads it back. Printing a mode there would be a guess stated as
    /// fact — and "offline" is exactly the guess a user would most regret
    /// trusting.
    func testResumeDoesNotClaimANetworkModeItDoesNotKnow() {
        let produced = lines(instance(), network: .preserved)[0]

        XCTAssertFalse(produced.contains("offline"), produced)
        XCTAssertFalse(produced.contains("Internet-enabled"), produced)
        XCTAssertTrue(produced.contains("last ran with"), produced)
    }
}
