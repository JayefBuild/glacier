// GlacierApp.swift
// App entry point. Each WindowGroup window gets its own AppState via ContentView.

import SwiftUI
import AppKit

@main
struct GlacierApp: App {
    @NSApplicationDelegateAdaptor(GlacierApplicationDelegate.self) private var appDelegate

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

final class GlacierApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let processCount = AppStateRegistry.shared.allAppStates.reduce(into: 0) { count, appState in
            count += appState.openTerminalSessionCount
        }

        guard processCount == 0 || confirmProtectedClose(.application, processCount: processCount) else {
            return .terminateCancel
        }

        WorkspaceStore.shared.markApplicationTerminating()
        return .terminateNow
    }
}
