// ContentView.swift
// Root layout: each window instance owns its own AppState — fully independent workspace.

import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    @Environment(\.appTheme) private var theme

    private var windowTitle: String {
        appState.fileService.rootURL?.lastPathComponent ?? "Glacier"
    }

    private var trashConfirmationTitle: String {
        guard let item = appState.pendingTrashItem else {
            return "Move to Trash?"
        }
        return "Move \"\(item.name)\" to Trash?"
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
        .confirmationDialog(
            trashConfirmationTitle,
            isPresented: Binding(
                get: { appState.pendingTrashItem != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.cancelTrashConfirmation()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                appState.confirmPendingTrash()
            }
            Button("Cancel", role: .cancel) {
                appState.cancelTrashConfirmation()
            }
        }
        .background {
            ZStack {
                Rectangle()
                    .fill(.thinMaterial)

                LinearGradient(
                    colors: [
                        theme.colors.windowBackground.opacity(0.96),
                        theme.colors.editorBackground.opacity(0.88),
                        theme.colors.windowBackground.opacity(0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                WindowConfigurator(title: windowTitle, appState: appState)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            if let url = WorkspaceStore.shared.consumePendingOpenURL() {
                appState.fileService.openFolder(at: url)
            } else {
                WorkspaceStore.shared.restoreOpenWorkspacesIfNeeded(using: appState)
            }
        }
    }
}
