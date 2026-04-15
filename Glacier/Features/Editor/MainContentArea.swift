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
            if !appState.tabs.isEmpty && !appState.isSplitViewVisible {
                TabBarView()
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            GeometryReader { _ in
                ZStack {
                    if let primaryTab = appState.primaryTab {
                        editorContent(primaryTab: primaryTab)
                            .transition(.opacity)
                    } else {
                        WelcomeView()
                    }

                    // Drop target sits on top of all editor content (including AppKit-backed
                    // HSplitView/VSplitView which would otherwise swallow the drag).
                    EditorSplitDropOverlay(
                        appState: appState,
                        activeSplitEdge: $activeSplitEdge
                    )

                    if let activeSplitEdge {
                        SplitPreviewOverlay(edge: activeSplitEdge)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, appState.tabs.isEmpty || appState.isSplitViewVisible ? 10 : 0)
                .animation(theme.animation.standard, value: appState.activeTabID)
                .animation(theme.animation.standard, value: appState.secondaryTabID)
                .animation(theme.animation.fast, value: activeSplitEdge)
                .onChange(of: appState.primaryTabID) { activeSplitEdge = nil }
                .onChange(of: appState.secondaryTabID) { activeSplitEdge = nil }
            }
        }
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
        let panelShape = RoundedRectangle(cornerRadius: theme.radius.panel + 2, style: .continuous)

        VStack(spacing: 0) {
            if appState.isSplitViewVisible {
                TabBarView(pane: pane)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            FileViewerRouter(tab: tab, pane: pane, isFocused: isFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(tab.id)
        }
        .background {
            panelShape
                .fill(.ultraThinMaterial)
                .overlay {
                    panelShape.fill(
                        LinearGradient(
                            colors: [
                                theme.colors.editorBackground.opacity(isFocused ? 0.96 : 0.82),
                                theme.colors.windowBackground.opacity(0.74)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
        }
        .background(
            PaneInteractionMonitor {
                appState.focusPane(pane)
            }
        )
        .clipShape(panelShape)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                appState.focusPane(pane)
            }
        )
        .overlay {
            panelShape
                .strokeBorder(
                    isFocused ? theme.colors.accent.opacity(0.55) : theme.colors.glassBorder.opacity(0.42),
                    lineWidth: isFocused ? 2 : 1
                )
        }
        .shadow(
            color: theme.colors.glassShadow.opacity(isFocused ? 0.9 : 0.55),
            radius: isFocused ? 24 : 18,
            y: isFocused ? 14 : 10
        )
        .accessibilityIdentifier("editor-pane-\(pane.rawValue)")
    }
}

private struct PaneInteractionMonitor: NSViewRepresentable {
    let onInteraction: () -> Void

    func makeNSView(context: Context) -> PaneInteractionHostingView {
        let view = PaneInteractionHostingView()
        view.onInteraction = onInteraction
        return view
    }

    func updateNSView(_ nsView: PaneInteractionHostingView, context: Context) {
        nsView.onInteraction = onInteraction
    }
}

private final class PaneInteractionHostingView: NSView {
    var onInteraction: (() -> Void)?
    private var eventMonitor: EventMonitor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }

        let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else {
                return event
            }

            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            self.onInteraction?()
            return event
        }

        guard let token else {
            return
        }

        eventMonitor = EventMonitor(token: token)
    }
}

private final class EventMonitor {
    private let token: Any

    init(token: Any) {
        self.token = token
    }

    deinit {
        NSEvent.removeMonitor(token)
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

private struct EditorSplitDropOverlay: NSViewRepresentable {
    @ObservedObject var appState: AppState
    @Binding var activeSplitEdge: EditorSplitDropEdge?

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, activeSplitEdge: $activeSplitEdge)
    }

    func makeNSView(context: Context) -> EditorSplitDropHostingView {
        let view = EditorSplitDropHostingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: EditorSplitDropHostingView, context: Context) {
        context.coordinator.appState = appState
        context.coordinator.activeSplitEdge = $activeSplitEdge
        nsView.coordinator = context.coordinator
    }

    @MainActor
    final class Coordinator: NSObject {
        var appState: AppState
        var activeSplitEdge: Binding<EditorSplitDropEdge?>

        init(appState: AppState, activeSplitEdge: Binding<EditorSplitDropEdge?>) {
            self.appState = appState
            self.activeSplitEdge = activeSplitEdge
        }

        func draggingEntered(_ sender: NSDraggingInfo, in size: CGSize, hostView: NSView) -> NSDragOperation {
            guard hasSupportedPayload(sender.draggingPasteboard) else { return [] }
            updateDropEdge(for: sender, in: size, hostView: hostView)
            return .copy
        }

        func draggingUpdated(_ sender: NSDraggingInfo, in size: CGSize, hostView: NSView) -> NSDragOperation {
            guard hasSupportedPayload(sender.draggingPasteboard) else { return [] }
            updateDropEdge(for: sender, in: size, hostView: hostView)
            return .copy
        }

        func draggingExited() {
            activeSplitEdge.wrappedValue = nil
        }

        func performDragOperation(_ sender: NSDraggingInfo, in size: CGSize, hostView: NSView) -> Bool {
            let location = hostView.convert(sender.draggingLocation, from: nil)
            guard let edge = splitPreviewEdge(for: location, in: size) else {
                activeSplitEdge.wrappedValue = nil
                return false
            }

            activeSplitEdge.wrappedValue = nil

            let pasteboard = sender.draggingPasteboard
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.glacierTabReference.identifier)),
               let reference = try? JSONDecoder().decode(DraggedTabReference.self, from: data) {
                appState.splitPane(with: reference.id, edge: edge)
                return true
            }

            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.glacierFileURL.identifier)),
               let reference = try? JSONDecoder().decode(DraggedFileURL.self, from: data) {
                appState.splitFile(at: reference.url, edge: edge)
                return true
            }

            return false
        }

        private func updateDropEdge(for sender: NSDraggingInfo, in size: CGSize, hostView: NSView) {
            let location = hostView.convert(sender.draggingLocation, from: nil)
            let nextEdge = splitPreviewEdge(for: location, in: size)
            guard activeSplitEdge.wrappedValue != nextEdge else { return }
            activeSplitEdge.wrappedValue = nextEdge
        }

        private func hasSupportedPayload(_ pasteboard: NSPasteboard) -> Bool {
            pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.glacierTabReference.identifier)) != nil ||
            pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.glacierFileURL.identifier)) != nil
        }
    }
}

private final class EditorSplitDropHostingView: NSView {
    weak var coordinator: EditorSplitDropOverlay.Coordinator?

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.glacierTabReference.identifier),
            NSPasteboard.PasteboardType(UTType.glacierFileURL.identifier)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        coordinator?.draggingEntered(sender, in: bounds.size, hostView: self) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        coordinator?.draggingUpdated(sender, in: bounds.size, hostView: self) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        coordinator?.draggingExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        coordinator?.performDragOperation(sender, in: bounds.size, hostView: self) ?? false
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
