// GlacierApp.swift
// App entry point. Each WindowGroup window gets its own AppState via ContentView.

import SwiftUI

@main
struct GlacierApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appTheme, GlacierTheme())
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            GlacierCommands()
        }
    }
}
