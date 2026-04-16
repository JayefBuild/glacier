// WindowConfigurator.swift
// Bridges SwiftUI into the NSWindow to control tab bar visibility and tab title.

import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    let title: String
    let appState: AppState

    func makeNSView(context: Context) -> WindowObservationView {
        let view = WindowObservationView()
        view.appState = appState
        DispatchQueue.main.async {
            configure(view: view, title: title)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservationView, context: Context) {
        nsView.appState = appState
        DispatchQueue.main.async {
            configure(view: nsView, title: title)
        }
    }

    @MainActor
    private func configure(view: NSView, title: String) {
        guard let window = view.window else { return }

        window.title = title
        window.tab.title = title
        window.tabbingMode = .preferred
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        // Keep drag-and-drop working inside the app; the titlebar/toolbar remains draggable.
        window.isMovableByWindowBackground = false
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        normalizeWindowFrameIfNeeded(window)

        let tabCount = window.tabbedWindows?.count ?? 1
        let barVisible = window.tabGroup?.isTabBarVisible ?? false
        if tabCount > 1 && !barVisible {
            window.toggleTabBar(nil)
        } else if tabCount <= 1 && barVisible {
            window.toggleTabBar(nil)
        }
    }

    @MainActor
    private func normalizeWindowFrameIfNeeded(_ window: NSWindow) {
        let frame = window.frame
        let minimumVisibleSize = CGSize(width: 800, height: 600)
        let isTooSmall = frame.width < minimumVisibleSize.width || frame.height < minimumVisibleSize.height

        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        let isOffscreen = !screenFrames.contains { $0.intersects(frame) }

        guard isTooSmall || isOffscreen else {
            return
        }

        guard let targetScreen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let targetVisibleFrame = targetScreen.visibleFrame
        let targetSize = CGSize(
            width: min(1200, targetVisibleFrame.width * 0.82),
            height: min(800, targetVisibleFrame.height * 0.82)
        )

        let targetOrigin = CGPoint(
            x: targetVisibleFrame.midX - (targetSize.width / 2),
            y: targetVisibleFrame.midY - (targetSize.height / 2)
        )

        let normalizedFrame = NSRect(origin: targetOrigin, size: targetSize).integral
        window.setFrame(normalizedFrame, display: true, animate: false)
    }
}

final class WindowObservationView: NSView {
    weak var appState: AppState? {
        didSet {
            activateIfNeeded()
        }
    }

    private let shouldForceActivationForSelfTest =
        ProcessInfo.processInfo.environment["GLACIER_SELF_TEST_SIDEBAR_KEYS"] == "1"
    private weak var observedWindow: NSWindow?
    private var keyMonitor: EventMonitor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installKeyMonitorIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus viewDidMoveToWindow hasWindow=\(window != nil)")
        }
        updateWindowObservation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func updateWindowObservation() {
        guard observedWindow !== window else {
            activateIfNeeded()
            return
        }

        removeObservers()
        observedWindow = window

        guard let window else { return }

        if shouldForceActivationForSelfTest {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            if let appState {
                SidebarKeySelfTestCoordinator.shared.scheduleIfNeeded(window: window, appState: appState)
            }
        }

        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(windowDidBecomeActive),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(windowDidBecomeActive),
            name: NSWindow.didBecomeMainNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )

        activateIfNeeded()
    }

    @objc
    private func windowDidBecomeActive(_ notification: Notification) {
        activateIfNeeded()
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        deactivateIfNeeded()
        removeObservers()
        observedWindow = nil
    }

    private func activateIfNeeded() {
        if focusDebugLoggingEnabled {
            focusDebugLog(
                "GlacierFocus activateIfNeeded appState=\(appState != nil) hasWindow=\(window != nil) key=\(window?.isKeyWindow == true) main=\(window?.isMainWindow == true)"
            )
        }
        guard let appState,
              let window,
              window.isKeyWindow || window.isMainWindow else {
            return
        }

        ActiveAppStateStore.shared.activate(appState)
        SidebarKeySelfTestCoordinator.shared.scheduleIfNeeded(window: window, appState: appState)
    }

    private func deactivateIfNeeded() {
        guard let appState else { return }
        ActiveAppStateStore.shared.deactivate(appState)
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }

        let token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleWindowShortcut(event)
        }

        if let token {
            keyMonitor = EventMonitor(token: token)
        }
    }

    private func handleWindowShortcut(_ event: NSEvent) -> NSEvent? {
        guard let window,
              window.isKeyWindow || window.isMainWindow,
              window.attachedSheet == nil,
              let appState else {
            return event
        }

        if focusDebugLoggingEnabled, [123, 124, 125, 126].contains(event.keyCode) {
            let responderName = window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            focusDebugLog(
                "GlacierFocus windowKeyDown keyCode=\(event.keyCode) modifiers=\(event.modifierFlags.rawValue) explorerFocused=\(appState.isExplorerFocused) responder=\(responderName)"
            )
        }

        if let explorerCommand = explorerNavigationCommand(for: event, appState: appState) {
            if focusDebugLoggingEnabled {
                focusDebugLog("GlacierFocus windowExplorerCommand command=\(explorerCommand)")
            }
            switch explorerCommand {
            case .moveUp:
                _ = appState.moveExplorerSelection(by: -1)
            case .moveDown:
                _ = appState.moveExplorerSelection(by: 1)
            case .collapse:
                _ = appState.collapseSelectedExplorerItem()
            case .expand:
                _ = appState.expandSelectedExplorerItem()
            }
            return nil
        }

        guard let shortcut = shortcutCommand(for: event) else {
            return event
        }

        switch shortcut {
        case .trashSelection:
            guard shouldHandleTrashShortcut(in: window, appState: appState) else {
                return event
            }
            appState.moveSelectedExplorerItemToTrash()
            return nil

        case .saveDocument:
            guard shouldHandleSaveShortcut(in: window, appState: appState) else {
                return event
            }
            appState.requestSaveForFocusedPane()
            return nil
        }
    }

    private func shortcutCommand(for event: NSEvent) -> WindowShortcutCommand? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command] else {
            return nil
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            return .trashSelection
        }

        if event.charactersIgnoringModifiers?.lowercased() == "s" {
            return .saveDocument
        }

        return nil
    }

    private func explorerNavigationCommand(for event: NSEvent, appState: AppState) -> ExplorerNavigationCommand? {
        guard appState.isExplorerFocused else {
            return nil
        }

        let modifiers = normalizedArrowModifiers(for: event)
        guard modifiers.isEmpty else {
            return nil
        }

        switch event.keyCode {
        case 123:
            return .collapse
        case 124:
            return .expand
        case 125:
            return .moveDown
        case 126:
            return .moveUp
        default:
            return nil
        }
    }

    private func normalizedArrowModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
    }

    private func shouldHandleTrashShortcut(in window: NSWindow, appState: AppState) -> Bool {
        guard appState.canTrashSelectedExplorerItem else {
            return false
        }

        guard !isTerminalFirstResponder(window.firstResponder) else {
            return false
        }

        guard let selectedURL = appState.selectedFileItem?.url ?? appState.selectedFileURLs.first else {
            return false
        }

        if appState.focusedVisibleFileURL == selectedURL,
           isTextEditingResponder(window.firstResponder) {
            return false
        }

        return true
    }

    private func shouldHandleSaveShortcut(in window: NSWindow, appState: AppState) -> Bool {
        appState.canSaveFocusedDocument && !isTerminalFirstResponder(window.firstResponder)
    }

    private func isTerminalFirstResponder(_ responder: NSResponder?) -> Bool {
        responder is GuardedTerminalView
    }

    private func isTextEditingResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let textView = responder as? NSTextView, textView.isEditable {
            return true
        }

        let className = NSStringFromClass(type(of: responder))
        return className.contains("WK")
    }
}

private enum WindowShortcutCommand {
    case trashSelection
    case saveDocument
}

private enum ExplorerNavigationCommand {
    case moveUp
    case moveDown
    case collapse
    case expand
}

@MainActor
private final class SidebarKeySelfTestCoordinator {
    static let shared = SidebarKeySelfTestCoordinator()

    private let isEnabled = ProcessInfo.processInfo.environment["GLACIER_SELF_TEST_SIDEBAR_KEYS"] == "1"
    private var hasScheduled = false

    private init() {}

    func scheduleIfNeeded(window: NSWindow, appState: AppState) {
        guard isEnabled, !hasScheduled else {
            return
        }

        hasScheduled = true
        focusDebugLog("GlacierFocus selfTest schedule")
        runWhenExplorerIsReady(window: window, appState: appState, attempt: 0)
    }

    private func runWhenExplorerIsReady(window: NSWindow, appState: AppState, attempt: Int) {
        let visibleItems = appState.fileService.visibleItems()
        guard !visibleItems.isEmpty else {
            guard attempt < 20 else {
                focusDebugLog("GlacierFocus selfTest aborted reason=no_visible_items")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.runWhenExplorerIsReady(window: window, appState: appState, attempt: attempt + 1)
            }
            return
        }

        let startingItem = visibleItems[0]
        appState.selectExplorerItem(startingItem)
        focusDebugLog("GlacierFocus selfTest startSelection=\(startingItem.url.path)")

        appState.focusExplorer()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.sendArrow(.down, to: window)
            self.logSelection(appState, label: "afterDown")

            self.sendArrow(.right, to: window)
            self.logSelection(appState, label: "afterRight")

            self.sendArrow(.left, to: window)
            self.logSelection(appState, label: "afterLeft")
        }
    }

    private func logSelection(_ appState: AppState, label: String) {
        let selectedPath = appState.selectedFileItem?.url.path
            ?? appState.selectedFileURLs.first?.path
            ?? "nil"
        focusDebugLog("GlacierFocus selfTest \(label)=\(selectedPath)")
    }

    private func sendArrow(_ direction: ArrowDirection, to window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: direction.characters,
            charactersIgnoringModifiers: direction.characters,
            isARepeat: false,
            keyCode: direction.keyCode
        ) else {
            focusDebugLog("GlacierFocus selfTest failedToCreateEvent keyCode=\(direction.keyCode)")
            return
        }

        let responderName = window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        focusDebugLog("GlacierFocus selfTest send keyCode=\(direction.keyCode) responder=\(responderName)")
        if let responder = window.firstResponder {
            responder.keyDown(with: event)
        } else {
            window.sendEvent(event)
        }
    }
}

private enum ArrowDirection {
    case left
    case right
    case down

    var keyCode: UInt16 {
        switch self {
        case .left:
            return 123
        case .right:
            return 124
        case .down:
            return 125
        }
    }

    var characters: String {
        let scalar: UnicodeScalar
        switch self {
        case .left:
            scalar = UnicodeScalar(NSLeftArrowFunctionKey)!
        case .right:
            scalar = UnicodeScalar(NSRightArrowFunctionKey)!
        case .down:
            scalar = UnicodeScalar(NSDownArrowFunctionKey)!
        }
        return String(Character(scalar))
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
