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

        let tabCount = window.tabbedWindows?.count ?? 1
        let barVisible = window.tabGroup?.isTabBarVisible ?? false
        if tabCount > 1 && !barVisible {
            window.toggleTabBar(nil)
        } else if tabCount <= 1 && barVisible {
            window.toggleTabBar(nil)
        }
    }
}

final class WindowObservationView: NSView {
    weak var appState: AppState? {
        didSet {
            activateIfNeeded()
        }
    }

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
        guard let appState,
              let window,
              window.isKeyWindow || window.isMainWindow else {
            return
        }

        ActiveAppStateStore.shared.activate(appState)
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
              event.window === window,
              window.attachedSheet == nil,
              let appState,
              let shortcut = shortcutCommand(for: event) else {
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

private final class EventMonitor {
    private let token: Any

    init(token: Any) {
        self.token = token
    }

    deinit {
        NSEvent.removeMonitor(token)
    }
}
