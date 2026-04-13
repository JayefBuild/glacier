// MainContentArea.swift
// The main content area: tab bar + active file viewer.

import SwiftUI

struct MainContentArea: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — only when tabs exist
            if !appState.tabs.isEmpty {
                TabBarView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Content
            ZStack {
                if let activeTab = appState.activeTab {
                    FileViewerRouter(tab: activeTab)
                        .id(activeTab.id)
                        .transition(.opacity)
                } else {
                    WelcomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(theme.animation.standard, value: appState.activeTabID)
        }
        .background(theme.colors.editorBackground)
    }
}

// MARK: - Welcome View

private struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mountain.2")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("Glacier")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.primary)

                Text("Open a folder or file to get started")
                    .font(theme.typography.labelFont)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Open Folder…") {
                    openFolder()
                }
                .buttonStyle(.glass)

                Button("New Terminal") {
                    appState.openNewTerminal()
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.editorBackground)
    }

    private func openFolder() {
        openFolderPanel { url in
            appState.fileService.openFolder(at: url)
        }
    }
}
