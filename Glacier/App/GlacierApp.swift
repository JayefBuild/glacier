// GlacierApp.swift
// App entry point.

import SwiftUI

@main
struct GlacierApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environment(\.appTheme, GlacierTheme())
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            GlacierCommands(appState: appState)
        }
    }

}
