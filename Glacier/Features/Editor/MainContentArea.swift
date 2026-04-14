// MainContentArea.swift
// The main content area: tab bar + active file viewer.

import SwiftUI
import UniformTypeIdentifiers

struct MainContentArea: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme
    @State private var activeSplitEdge: EditorSplitDropEdge?

    var body: some View {
        VStack(spacing: 0) {
            if !appState.tabs.isEmpty {
                TabBarView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            GeometryReader { proxy in
                ZStack {
                    if let primaryTab = appState.primaryTab {
                        editorContent(primaryTab: primaryTab)
                            .transition(.opacity)
                    } else {
                        WelcomeView()
                    }

                    // Drop target sits on top of all editor content (including AppKit-backed
                    // HSplitView/VSplitView which would otherwise swallow the drag).
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [
                                UTType.glacierTabReference.identifier,
                                UTType.glacierFileURL.identifier
                            ],
                            delegate: EditorSplitDropDelegate(
                                appState: appState,
                                activeSplitEdge: $activeSplitEdge,
                                dropSize: proxy.size
                            )
                        )

                    if let activeSplitEdge {
                        SplitPreviewOverlay(edge: activeSplitEdge)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(theme.animation.standard, value: appState.activeTabID)
                .animation(theme.animation.standard, value: appState.secondaryTabID)
                .animation(theme.animation.fast, value: activeSplitEdge)
                .onChange(of: appState.primaryTabID) { activeSplitEdge = nil }
                .onChange(of: appState.secondaryTabID) { activeSplitEdge = nil }
            }
        }
        .background(theme.colors.editorBackground)
    }

    @ViewBuilder
    private func editorContent(primaryTab: Tab) -> some View {
        if let secondaryTab = appState.secondaryTab {
            switch appState.splitOrientation {
            case .sideBySide:
                HSplitView {
                    EditorPaneView(pane: .primary, tab: primaryTab)
                    EditorPaneView(pane: .secondary, tab: secondaryTab)
                }
            case .topBottom:
                VSplitView {
                    EditorPaneView(pane: .primary, tab: primaryTab)
                    EditorPaneView(pane: .secondary, tab: secondaryTab)
                }
            }
        } else {
            EditorPaneView(pane: .primary, tab: primaryTab)
        }
    }
}

private struct EditorPaneView: View {
    let pane: EditorPane
    let tab: Tab

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    private var isFocused: Bool {
        appState.focusedPane == pane
    }

    var body: some View {
        FileViewerRouter(tab: tab)
            .id("\(pane.rawValue)-\(tab.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.editorBackground)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    appState.focusPane(pane)
                }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(
                        isFocused ? theme.colors.accent.opacity(0.45) : theme.colors.borderSubtle,
                        lineWidth: isFocused ? 2 : 1
                    )
            }
            .accessibilityIdentifier("editor-pane-\(pane.rawValue)")
    }
}

private struct SplitPreviewOverlay: View {
    let edge: EditorSplitDropEdge

    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let previewWidth = min(max(proxy.size.width * 0.34, 240), 420)
            let previewHeight = min(max(proxy.size.height * 0.34, 180), 320)

            ZStack {
                switch edge {
                case .left:
                    HStack(spacing: 0) {
                        previewPanel
                            .frame(width: previewWidth)
                        Spacer(minLength: 0)
                    }

                case .right:
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        previewPanel
                            .frame(width: previewWidth)
                    }

                case .top:
                    VStack(spacing: 0) {
                        previewPanel
                            .frame(height: previewHeight)
                        Spacer(minLength: 0)
                    }

                case .bottom:
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        previewPanel
                            .frame(height: previewHeight)
                    }
                }
            }
            .padding(6)
        }
    }

    private var previewPanel: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium)
            .fill(theme.colors.accent.opacity(0.24))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .strokeBorder(theme.colors.accent.opacity(0.55), lineWidth: 1.5)
            }
    }
}

private struct EditorSplitDropDelegate: DropDelegate {
    @ObservedObject var appState: AppState
    @Binding var activeSplitEdge: EditorSplitDropEdge?
    let dropSize: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        supportsTabDrag(info) || supportsFileDrag(info)
    }

    func dropEntered(info: DropInfo) {
        updateDropEdge(with: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropEdge(with: info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        activeSplitEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let edge = splitPreviewEdge(for: info.location, in: dropSize) else {
            activeSplitEdge = nil
            return false
        }

        activeSplitEdge = nil

        if let provider = info.itemProviders(for: [UTType.glacierTabReference.identifier]).first {
            loadDraggedTab(from: provider, edge: edge)
            return true
        }

        if let provider = info.itemProviders(for: [UTType.glacierFileURL.identifier]).first {
            loadDraggedFile(from: provider, edge: edge)
            return true
        }

        return false
    }

    private func updateDropEdge(with info: DropInfo) {
        activeSplitEdge = splitPreviewEdge(for: info.location, in: dropSize)
    }

    private func supportsTabDrag(_ info: DropInfo) -> Bool {
        !info.itemProviders(for: [UTType.glacierTabReference.identifier]).isEmpty
    }

    private func supportsFileDrag(_ info: DropInfo) -> Bool {
        !info.itemProviders(for: [UTType.glacierFileURL.identifier]).isEmpty
    }

    private func loadDraggedTab(from provider: NSItemProvider, edge: EditorSplitDropEdge) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.glacierTabReference.identifier) { data, _ in
            guard
                let data,
                let reference = try? JSONDecoder().decode(DraggedTabReference.self, from: data)
            else {
                return
            }

            Task { @MainActor in
                appState.splitPane(with: reference.id, edge: edge)
            }
        }
    }

    private func loadDraggedFile(from provider: NSItemProvider, edge: EditorSplitDropEdge) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.glacierFileURL.identifier) { data, _ in
            guard
                let data,
                let reference = try? JSONDecoder().decode(DraggedFileURL.self, from: data)
            else {
                return
            }

            Task { @MainActor in
                appState.splitFile(at: reference.url, edge: edge)
            }
        }
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
