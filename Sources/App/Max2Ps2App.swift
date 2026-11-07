// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ThecangShengdance
import SwiftUI

@main
struct Max2Ps2App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1040, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
