// WindowConfigurator.swift
// Bridges SwiftUI into the NSWindow to control tab bar visibility and tab title.

import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view: view, title: title)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
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

        let tabCount = window.tabbedWindows?.count ?? 1
        let barVisible = window.tabGroup?.isTabBarVisible ?? false
        if tabCount > 1 && !barVisible {
            window.toggleTabBar(nil)
        } else if tabCount <= 1 && barVisible {
            window.toggleTabBar(nil)
        }
    }
}
