// TabBarView.swift
// Horizontal tab bar, only shown when tabs exist.

import SwiftUI

struct TabBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(appState.tabs) { tab in
                    TabItemView(tab: tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: theme.spacing.tabBarHeight)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - Tab Item View

struct TabItemView: View {
    let tab: Tab
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var renameText = ""

    private var isActive: Bool { appState.activeTabID == tab.id }

    private var isTerminal: Bool {
        if case .terminal = tab.kind { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .foregroundStyle(tab.iconColor)

            // Inline rename field (terminal tabs only)
            if isRenaming, case .terminal(let session) = tab.kind {
                TextField("", text: $renameText)
                    .font(theme.typography.tabFont)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 60, maxWidth: 140)
                    .onSubmit { commitRename(session: session) }
                    .onExitCommand { isRenaming = false }
                    // Clicking outside dismisses
                    .onChange(of: isActive) { _, active in
                        if !active { isRenaming = false }
                    }
            } else {
                Text(tab.title)
                    .font(theme.typography.tabFont)
                    .foregroundStyle(isActive ? theme.colors.primaryText : theme.colors.secondaryText)
                    .lineLimit(1)
                    // Double-click to rename terminal tabs
                    .onTapGesture(count: 2) {
                        if isTerminal { beginRename() }
                    }
                    .onTapGesture(count: 1) {
                        appState.activateTab(id: tab.id)
                    }
            }

            Button {
                withAnimation(theme.animation.fast) {
                    appState.closeTab(tab)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? theme.colors.primaryText : .clear)
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Group {
                if isActive {
                    RoundedRectangle(cornerRadius: theme.radius.small)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: theme.radius.small)
                        .fill(theme.colors.hoverBackground)
                }
            }
        )
        .onHover { isHovered = $0 }
        .onTapGesture {
            if !isRenaming { appState.activateTab(id: tab.id) }
        }
        .contextMenu {
            // Rename — terminal tabs only
            if isTerminal, case .terminal(let session) = tab.kind {
                Button("Rename…") { beginRename() }
                Divider()
            }

            Button("Close Tab") { appState.closeTab(tab) }
            Button("Close Other Tabs") {
                let others = appState.tabs.filter { $0.id != tab.id }
                others.forEach { appState.closeTab($0) }
            }
        }
    }

    // MARK: - Rename

    private func beginRename() {
        renameText = tab.title
        isRenaming = true
    }

    private func commitRename(session: TerminalSession) {
        appState.renameTerminal(session, to: renameText)
        isRenaming = false
    }
}
