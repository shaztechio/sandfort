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

import XCTest
@testable import SandfortApp

/// Instance actions used to read a picker's selection made elsewhere in the
/// window. Now each row acts on its own instance, and the risk is the opposite
/// mistake: a row acting on whatever was selected last. Reset destroys a
/// sandbox's work, so it has to target the row the user clicked.
@MainActor
final class InstanceActionTests: XCTestCase {
    func testEachActionRetargetsTheSelectionBeforeRunning() {
        let model = SandfortViewModel()
        model.selectedInstanceNumber = 1

        model.beginRename(instance: 3)
        XCTAssertEqual(model.selectedInstanceNumber, 3, "rename must act on its own row")
        XCTAssertTrue(model.showRenamePrompt)

        model.requestDelete(instance: 2)
        XCTAssertEqual(model.selectedInstanceNumber, 2, "delete must act on its own row")
        XCTAssertTrue(model.showDeleteConfirmation)
    }

    /// Deleting is confirmed, never immediate.
    func testDeleteOnlyRequestsConfirmation() {
        let model = SandfortViewModel()
        model.requestDelete(instance: 4)
        XCTAssertTrue(model.showDeleteConfirmation)
        XCTAssertEqual(model.selectedInstanceNumber, 4)
    }

    /// The guest password is on screen in an app that gets demoed and
    /// screenshotted, so it starts hidden.
    func testGuestPasswordStartsHidden() {
        XCTAssertFalse(SandfortViewModel().revealGuestPassword)
    }

    /// Baseline tool configuration is a sheet now, not a permanent pane.
    func testBaselineToolsSheetStartsClosed() {
        XCTAssertFalse(SandfortViewModel().showBaselineTools)
    }

    /// The default script the editor offers must stay runnable: a shebang,
    /// because it is executed by path, and strict mode.
    func testDefaultSetupScriptIsSafeToRun() {
        let script = BaselineToolsSheet.defaultSetupScript
        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(script.contains("set -euo pipefail"))
    }
}
