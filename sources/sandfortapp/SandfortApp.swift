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
import SwiftUI

@main
struct SandfortApp: App {
    /// Supplies the single-window quit behavior and the in-progress guard.
    @NSApplicationDelegateAdaptor(SandfortAppDelegate.self) private var appDelegate

    var body: some Scene {
        // `Window` rather than `WindowGroup`: Sandfort is a single-window
        // utility, and a second window would be a second view model racing the
        // first over the same baselines, instances, and UTM bundles. This also
        // removes the File > New Window command that WindowGroup adds.
        Window(SandfortRuntimeConfiguration.current.displayName, id: "sandfort-main") {
            ContentView()
        }
            .defaultSize(width: 1000, height: 720)
            // The window sizes itself no longer: a split view has to be
            // resizable for its divider to be useful.
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .help) {
                    Button("Sandfort Help") {
                        NSApplication.shared.showHelp(nil)
                    }
                    .keyboardShortcut("?", modifiers: .command)
                }
            }
        Settings {
            SandfortSettingsView(runtime: .current)
        }
    }
}
