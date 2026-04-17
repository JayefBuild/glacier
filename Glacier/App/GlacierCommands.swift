// GlacierCommands.swift
// Menu bar commands — always operate on the focused window's AppState.

import SwiftUI
import Bonsplit

struct GlacierCommands: Commands {
    @FocusedValue(\.appState) private var focusedAppState: AppState?

    private var appState: AppState? {
        focusedAppState ?? ActiveAppStateStore.shared.appState
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("New Terminal Tab") {
                appState?.openNewTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command])

            Button("Close Tab") {
                if let appState, appState.hasFocusedPreview {
                    appState.clearFocusedPreview()
                } else if let tab = appState?.activeTab {
                    appState?.closeTab(tab)
                }
            }
            .keyboardShortcut("w", modifiers: [.command])

            Button("Move Selected Item to Trash") {
                appState?.moveSelectedExplorerItemToTrash()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!(appState?.canTrashSelectedExplorerItem ?? false))
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                appState?.requestSaveForFocusedPane()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!(appState?.canSaveFocusedDocument ?? false))
        }

        CommandGroup(after: .windowArrangement) {
            Button("Toggle Sidebar") {
                withAnimation(GlacierTheme().animation.standard) {
                    appState?.isSidebarVisible.toggle()
                }
            }
            .keyboardShortcut("\\", modifiers: .command)
        }

        CommandMenu("View") {
            Button("Increase Font Size") {
                appState?.adjustFontSize(by: 1)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Decrease Font Size") {
                appState?.adjustFontSize(by: -1)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Font Size") {
                appState?.resetFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button("Split Right") {
                appState?.bonsplitController.splitPane(orientation: .horizontal)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(appState?.tabs.isEmpty ?? true)

            Button("Split Down") {
                appState?.bonsplitController.splitPane(orientation: .vertical)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(appState?.tabs.isEmpty ?? true)

            Button("Close Split") {
                if let paneID = appState?.bonsplitController.focusedPaneId {
                    appState?.bonsplitController.closePane(paneID)
                }
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            .disabled((appState?.bonsplitController.allPaneIds.count ?? 0) <= 1)
        }
    }

    private func openFolder() {
        openFolderPanel { url in
            appState?.fileService.openFolder(at: url)
        }
    }
}
