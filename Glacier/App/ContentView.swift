// ContentView.swift
// Root layout: each window instance owns its own AppState — fully independent workspace.

import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    @Environment(\.appTheme) private var theme

    private var windowTitle: String {
        appState.fileService.rootURL?.lastPathComponent ?? "Glacier"
    }

    var body: some View {
        NavigationSplitView {
            ExplorerView()
                .navigationSplitViewColumnWidth(
                    min: theme.spacing.sidebarMinWidth,
                    ideal: theme.spacing.sidebarWidth,
                    max: theme.spacing.sidebarMaxWidth
                )
        } detail: {
            MainContentArea()
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(appState)
        .focusedValue(\.appState, appState)
        .toolbar(removing: .sidebarToggle)
        .background(
            WindowConfigurator(
                title: windowTitle,
                onNewTerminal: {
                    appState.openNewTerminal(workingDirectory: appState.fileService.rootURL)
                }
            )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
        .onAppear {
            // If a workspace was queued for a new tab, open it now
            if let url = WorkspaceStore.shared.pendingOpenURL {
                WorkspaceStore.shared.pendingOpenURL = nil
                appState.fileService.openFolder(at: url)
            }
        }
    }
}
