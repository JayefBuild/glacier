// ContentView.swift
// Root layout: NavigationSplitView with sidebar + main content area.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

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
    }
}
