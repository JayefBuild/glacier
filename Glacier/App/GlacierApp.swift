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

        AppStateRegistry.shared.allAppStates.forEach { appState in
            appState.saveOpenDocumentsBeforeClose()
        }
        WorkspaceStore.shared.markApplicationTerminating()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            GlacierFileOpener.open(urls: urls)
        }
    }
}

@MainActor
enum GlacierFileOpener {
    static func open(urls: [URL]) {
        guard !urls.isEmpty else { return }

        let fileManager = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                openFolderInWindow(url.standardizedFileURL)
            } else {
                openFileInActiveWindow(url)
            }
        }

        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func openFileInActiveWindow(_ fileURL: URL) {
        let appState = resolveAppState()
        if appState.fileService.rootURL == nil {
            appState.fileService.openFolder(at: fileURL.deletingLastPathComponent())
        }
        appState.openFile(FileItem(url: fileURL, isDirectory: false))
    }

    private static func openFolderInWindow(_ folderURL: URL) {
        // If an existing window already owns this folder, focus it.
        if let existing = AppStateRegistry.shared.allAppStates.first(where: {
            $0.fileService.rootURL?.standardizedFileURL == folderURL
        }) {
            ActiveAppStateStore.shared.activate(existing)
            return
        }

        // If there's no visible window yet (cold launch), use the pending AppState.
        let active = resolveAppState()
        if active.fileService.rootURL == nil {
            active.fileService.openFolder(at: folderURL)
            return
        }

        // Otherwise spawn a new window and let it pick up the folder on appear.
        WorkspaceStore.shared.queuePendingOpenURL(folderURL)
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: NSApp)
    }

    private static func resolveAppState() -> AppState {
        if let active = ActiveAppStateStore.shared.appState {
            return active
        }
        if let first = AppStateRegistry.shared.allAppStates.first {
            return first
        }
        // No window yet — SwiftUI will create one via WindowGroup; wait a tick and retry.
        // In practice, applicationDidFinishLaunching has fired by the time Launch Services
        // delivers URLs, so the registry is populated. Fall back to creating a transient state
        // as a safety net.
        return AppState()
    }
}
