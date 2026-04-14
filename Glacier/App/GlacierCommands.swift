// GlacierCommands.swift
// Menu bar commands — always operate on the focused window's AppState.

import SwiftUI

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
                if let tab = appState?.activeTab {
                    appState?.closeTab(tab)
                }
            }
            .keyboardShortcut("w", modifiers: [.command])
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
                appState?.splitFocusedPaneRight()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!(appState?.canSplitFocusedPane ?? false))

            Button("Split Down") {
                appState?.splitFocusedPaneDown()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!(appState?.canSplitFocusedPane ?? false))

            Button("Close Split") {
                appState?.closeSplit()
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            .disabled(!(appState?.isSplitViewVisible ?? false))
        }
    }

    private func openFolder() {
        openFolderPanel { url in
            appState?.fileService.openFolder(at: url)
        }
    }
}
