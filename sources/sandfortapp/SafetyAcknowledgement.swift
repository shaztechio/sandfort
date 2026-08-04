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

/// First-run disclosure shown before any virtual machine can be created.
///
/// The wording below is the entire user-facing text, kept in one place so it can
/// be reviewed or replaced without touching behavior.
///
/// This is a safety disclosure first and a liability notice second. Sandfort is
/// used to run malware, and the honest limits of what it protects belong in
/// front of the user before they build a sandbox, not only in `docs/`. Keep it
/// accurate: it must never imply the sandbox makes the user safe. Every claim
/// here has to stay consistent with `docs/security-model.md` and
/// `docs/password-strength.md`.
enum SafetyAcknowledgement {
    /// Raise this when the disclosure changes in a way a user should see again.
    /// A user who accepted an older version is prompted once more; cosmetic
    /// edits should not raise it, because needless re-prompting teaches people
    /// to dismiss the screen without reading it.
    static let currentVersion = 1

    static let title = "Before you begin"

    static let summary = """
    Sandfort creates disposable virtual machines for running software you do \
    not trust. It reduces risk. It is not a guarantee of safety, and it is \
    provided with no warranty.
    """

    /// Each entry is a limit the user is agreeing they understand. These mirror
    /// the residual risks documented in `docs/security-model.md`.
    static let points = [
        "A virtual machine is not a perfect boundary. A flaw in the guest system, QEMU, UTM, or macOS can let code escape it.",
        "The virtual disk is not encrypted, and the generated guest password does not protect it. Anyone with the disk file can read everything inside.",
        "Never put personal accounts, passwords, keys, wallets, work files, or anything else valuable into a sandbox.",
        "Clean instances start offline by default. An instance you launch with Internet access really can reach the Internet, including anything running inside it.",
        "You are responsible for what you choose to run and for complying with the law where you are."
    ]

    static let licenseNotice = """
    Sandfort is free and open source under the Apache License 2.0. It is \
    provided "as is", without warranties or conditions of any kind, and its \
    contributors are not liable for any damages arising from its use. See the \
    LICENSE file for the full terms.
    """

    static let confirmationLabel = "I understand these limits and accept the risk"

    /// What was accepted, so a later change to the disclosure can re-prompt.
    struct Record: Codable, Equatable {
        var version: Int
        var acknowledgedAt: Date
        var appVersion: String?

        var isCurrent: Bool { version >= SafetyAcknowledgement.currentVersion }
    }

    /// Stores the record in the app-owned support directory rather than in
    /// shared preferences, so each app identity keeps its own answer and a
    /// qualification build never inherits the production one.
    struct Store {
        let fileURL: URL

        init(supportRootURL: URL) {
            fileURL = supportRootURL.appendingPathComponent("acknowledgement.plist")
        }

        func load() -> Record? {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? PropertyListDecoder().decode(Record.self, from: data)
        }

        /// A user who has accepted the current version is not asked again.
        var needsAcknowledgement: Bool {
            load()?.isCurrent != true
        }

        @discardableResult
        func record(appVersion: String? = nil, now: Date = Date()) throws -> Record {
            let record = Record(
                version: SafetyAcknowledgement.currentVersion,
                acknowledgedAt: now,
                appVersion: appVersion
            )
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try PropertyListEncoder().encode(record).write(to: fileURL, options: .atomic)
            return record
        }
    }
}
