// MainContentArea.swift
// Hosts the Bonsplit tab/split system for the editor area. Drag-to-split,
// cross-pane tab moves, resizable dividers — all provided by Bonsplit.

import SwiftUI
import Bonsplit

struct MainContentArea: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            if appState.tabs.isEmpty {
                WelcomeView()
            } else {
                BonsplitView(
                    controller: appState.bonsplitController,
                    content: { bonsplitTab, paneID in
                        editorContent(for: bonsplitTab, inPane: paneID)
                    },
                    emptyPane: { paneID in
                        EmptyPaneView(appState: appState, paneID: paneID)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(.thinMaterial)
                .overlay {
                    LinearGradient(
                        colors: [
                            theme.colors.windowBackground.opacity(0.9),
                            theme.colors.editorBackground.opacity(0.84)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
    }

    @ViewBuilder
    private func editorContent(for bonsplitTab: Bonsplit.Tab, inPane paneID: PaneID) -> some View {
        if let glacierID = appState.bridge.glacierTabID(for: bonsplitTab.id),
           let glacierTab = appState.tab(with: glacierID) {
            FileViewerRouter(
                tab: glacierTab,
                previewItem: appState.bridge.preview(inPane: paneID),
                paneID: paneID
            )
        } else {
            Color.clear
        }
    }
}

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
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .frame(maxWidth: 360)
        .glacierGlassSurface(
            theme: theme,
            cornerRadius: theme.radius.panel + 8,
            shadowRadius: 24,
            shadowY: 14
        )
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private func openFolder() {
        openFolderPanel { url in
            appState.fileService.openFolder(at: url)
        }
    }
}

private struct EmptyPaneView: View {
    @ObservedObject var appState: AppState
    let paneID: PaneID

    @Environment(\.appTheme) private var theme

    var body: some View {
        if let previewItem = appState.bridge.preview(inPane: paneID) {
            FileViewerRouter(
                tab: nil,
                previewItem: previewItem,
                paneID: paneID
            )
        } else {
            VStack(spacing: 16) {
                Image(systemName: "doc.text")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("No Open Tabs")
                    .font(theme.typography.labelFont)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
