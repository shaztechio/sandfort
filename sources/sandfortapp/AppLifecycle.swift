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

import AppKit
import Foundation

/// Records whether Sandfort is in the middle of work that quitting would throw
/// away: a verified image download, a disk resize, or seed-media generation.
///
/// The app delegate cannot reach the window's view model, so the model reports
/// here instead. Once a setup VM has been handed to UTM the guest runs in UTM's
/// own process and is unaffected by Sandfort quitting, so only Sandfort's own
/// work is tracked.
final class SandfortActivityMonitor: @unchecked Sendable {
    static let shared = SandfortActivityMonitor()

    private let lock = NSLock()
    private var depth = 0

    /// True while at least one operation is in flight. Counted rather than a
    /// flag so an early return or a future nested call cannot clear it while
    /// other work is still running.
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    func begin() {
        lock.lock()
        depth += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        depth = max(0, depth - 1)
        lock.unlock()
    }

    /// Test seam: restores the monitor to its idle state.
    func reset() {
        lock.lock()
        depth = 0
        lock.unlock()
    }
}

/// Sandfort is a single-window utility, so closing its window quits, the way
/// System Settings does. macOS only keeps an app running after its last window
/// closes when there is something to reopen into, and here there is not: a
/// second window would be a second view model racing the first over the same
/// baselines and instances.
final class SandfortAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Confirms before discarding work in progress. Closing the window during a
    /// several-hundred-megabyte verified download should not silently throw it
    /// away.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard SandfortActivityMonitor.shared.isBusy else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sandfort is still working."
        alert.informativeText = """
        Quitting now stops the current step and discards anything downloaded or \
        prepared so far. A sandbox that is already running in UTM is not affected.
        """
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Working")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
