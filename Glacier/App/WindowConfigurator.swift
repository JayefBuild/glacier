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
}
