// TabBarView.swift
// Horizontal tab bar, only shown when tabs exist.

import SwiftUI

struct TabBarView: View {
    let pane: EditorPane?

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    init(pane: EditorPane? = nil) {
        self.pane = pane
    }

    private var displayedTabs: [Tab] {
        if let pane {
            return appState.tabs(for: pane)
        }
        return appState.tabs
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(displayedTabs) { tab in
                    TabItemView(tab: tab, pane: pane)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: theme.spacing.tabBarHeight)
        .glacierGlassSurface(
            theme: theme,
            cornerRadius: theme.radius.large,
            shadowRadius: 12,
            shadowY: 6
        )
    }
}

// MARK: - Tab Item View

struct TabItemView: View {
    let tab: Tab
    let pane: EditorPane?

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var renameText = ""

    private var isActive: Bool {
        if let pane {
            return appState.visibleTabID(for: pane) == tab.id
        }
        return appState.activeTabID == tab.id
    }

    private var belongsToPane: Bool {
        if let pane {
            return appState.paneAssignment(for: tab.id) == pane
        }
        return appState.isTabVisible(tab.id)
    }

    private var isTerminal: Bool {
        if case .terminal = tab.kind { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .foregroundStyle(tab.iconColor)

            if isRenaming, case .terminal(let terminal) = tab.kind {
                TextField("", text: $renameText)
                    .font(theme.typography.tabFont)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 60, maxWidth: 140)
                    .onSubmit { commitRename(terminal: terminal) }
                    .onExitCommand { isRenaming = false }
                    .onChange(of: isActive) { _, active in
                        if !active { isRenaming = false }
                    }
            } else {
                Text(tab.title)
                    .font(theme.typography.tabFont)
                    .foregroundStyle(isActive ? theme.colors.primaryText : theme.colors.secondaryText)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        if isTerminal { beginRename() }
                    }
                    .onTapGesture(count: 1) {
                        activateTab()
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
        .contentShape(Rectangle())
        .background(
            Group {
                if isActive {
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                                .fill(theme.colors.selectionBackground.opacity(0.78))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                                .strokeBorder(theme.colors.glassBorder.opacity(0.72), lineWidth: 1)
                        }
                        .shadow(color: theme.colors.glassShadow.opacity(0.4), radius: 8, y: 4)
                } else if belongsToPane {
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .fill(theme.colors.hoverBackground.opacity(0.92))
                } else if isHovered {
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .fill(theme.colors.hoverBackground.opacity(0.8))
                }
            }
        )
        .draggable(DraggedTabReference(id: tab.id)) {
            TabDragPreview(tab: tab)
        }
        .onHover { isHovered = $0 }
        .onTapGesture {
            if !isRenaming { activateTab() }
        }
        .accessibilityIdentifier("tab-\(tab.title)")
        .contextMenu {
            if isTerminal, case .terminal = tab.kind {
                Button("Rename…") { beginRename() }
                Divider()
            }

            Button("Close Tab") { appState.closeTab(tab) }
            Button("Close Other Tabs") {
                appState.closeOtherTabs(keeping: tab.id, in: pane)
            }
        }
    }

    private func activateTab() {
        if let pane {
            appState.activateTab(id: tab.id, in: pane)
        } else {
            appState.activateTab(id: tab.id)
        }
    }

    private func beginRename() {
        renameText = tab.title
        isRenaming = true
    }

    private func commitRename(terminal: TerminalTabState) {
        appState.renameTerminal(terminal, to: renameText)
        isRenaming = false
    }
}

private struct TabDragPreview: View {
    let tab: Tab

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .foregroundStyle(tab.iconColor)

            Text(tab.title)
                .font(theme.typography.tabFont)
                .lineLimit(1)
                .foregroundStyle(theme.colors.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glacierGlassSurface(
            theme: theme,
            cornerRadius: theme.radius.medium,
            shadowRadius: 10,
            shadowY: 5
        )
    }
}
