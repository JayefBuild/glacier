// WindowConfigurator.swift
// Bridges SwiftUI into the NSWindow to control tab bar visibility and tab title.

import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    let title: String
    let onNewTerminal: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNewTerminal: onNewTerminal)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer until the view is in the window hierarchy
        DispatchQueue.main.async {
            configure(view: view, title: title, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onNewTerminal = onNewTerminal
        DispatchQueue.main.async {
            configure(view: nsView, title: title, coordinator: context.coordinator)
        }
    }

    @MainActor
    private func configure(view: NSView, title: String, coordinator: Coordinator) {
        guard let window = view.window else { return }

        // Set tab title to workspace name
        window.title = title
        window.tab.title = title

        // Always allow tabbing so addTabbedWindow works
        window.tabbingMode = .preferred

        // Show tab bar only when multiple tabs exist
        let tabCount = window.tabbedWindows?.count ?? 1
        let barVisible = window.tabGroup?.isTabBarVisible ?? false
        if tabCount > 1 && !barVisible {
            window.toggleTabBar(nil)
        } else if tabCount <= 1 && barVisible {
            window.toggleTabBar(nil)
        }

        guard let splitViewController = findSplitViewController(from: window.contentViewController),
              let sidebarItem = splitViewController.splitViewItems.first(where: { $0.behavior == .sidebar }) else {
            coordinator.uninstallAccessories()
            return
        }

        installAccessoriesIfNeeded(
            in: window,
            splitViewController: splitViewController,
            sidebarItem: sidebarItem,
            coordinator: coordinator
        )
    }

    @MainActor
    private func installAccessoriesIfNeeded(
        in window: NSWindow,
        splitViewController: NSSplitViewController,
        sidebarItem: NSSplitViewItem,
        coordinator: Coordinator
    ) {
        coordinator.installIfNeeded(
            in: window,
            splitViewController: splitViewController,
            sidebarItem: sidebarItem
        )
    }

    private func findSplitViewController(from viewController: NSViewController?) -> NSSplitViewController? {
        guard let viewController else { return nil }
        if let splitViewController = viewController as? NSSplitViewController {
            return splitViewController
        }

        for child in viewController.children {
            if let splitViewController = findSplitViewController(from: child) {
                return splitViewController
            }
        }

        return nil
    }
}

extension WindowConfigurator {
    @MainActor
    final class Coordinator: NSObject {
        var onNewTerminal: () -> Void

        weak var installedWindow: NSWindow?
        weak var installedSplitViewController: NSSplitViewController?
        weak var installedSidebarItem: NSSplitViewItem?
        weak var trackedSidebarView: NSView?

        var sidebarAccessoryController: NSSplitViewItemAccessoryViewController?
        var collapsedTitlebarAccessoryController: NSTitlebarAccessoryViewController?
        var sidebarWidthConstraint: NSLayoutConstraint?

        var collapseObservation: NSKeyValueObservation?
        var frameObservation: NSObjectProtocol?

        private let actionTarget = ControlStripActionTarget()

        init(onNewTerminal: @escaping () -> Void) {
            self.onNewTerminal = onNewTerminal
            super.init()
            actionTarget.onNewTerminal = { [weak self] in
                self?.onNewTerminal()
            }
        }

        deinit {
            Task { @MainActor [weak self] in
                self?.uninstallAccessories()
            }
        }

        func installIfNeeded(
            in window: NSWindow,
            splitViewController: NSSplitViewController,
            sidebarItem: NSSplitViewItem
        ) {
            actionTarget.onNewTerminal = { [weak self] in
                self?.onNewTerminal()
            }
            actionTarget.onToggleSidebar = { [weak splitViewController] in
                splitViewController?.toggleSidebar(nil)
            }

            let needsReinstall =
                installedWindow !== window ||
                installedSplitViewController !== splitViewController ||
                installedSidebarItem !== sidebarItem

            if needsReinstall {
                uninstallAccessories()

                installedWindow = window
                installedSplitViewController = splitViewController
                installedSidebarItem = sidebarItem

                let sidebarAccessory = makeSidebarAccessoryController()
                sidebarItem.addTopAlignedAccessoryViewController(sidebarAccessory)
                sidebarAccessoryController = sidebarAccessory

                let titlebarAccessory = makeCollapsedTitlebarAccessoryController()
                collapsedTitlebarAccessoryController = titlebarAccessory

                installSidebarObservers(splitViewController: splitViewController, sidebarItem: sidebarItem)
            }

            updateSidebarWidthIfNeeded()
            updateAccessoryVisibility()
        }

        func uninstallAccessories() {
            collapseObservation = nil

            if let frameObservation {
                NotificationCenter.default.removeObserver(frameObservation)
                self.frameObservation = nil
            }

            if let sidebarItem = installedSidebarItem,
               let accessory = sidebarAccessoryController,
               let index = sidebarItem.topAlignedAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                sidebarItem.removeTopAlignedAccessoryViewController(at: index)
            }

            if let window = installedWindow,
               let accessory = collapsedTitlebarAccessoryController,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }

            sidebarAccessoryController = nil
            collapsedTitlebarAccessoryController = nil
            sidebarWidthConstraint = nil
            trackedSidebarView = nil
            installedWindow = nil
            installedSplitViewController = nil
            installedSidebarItem = nil
        }

        private func installSidebarObservers(
            splitViewController: NSSplitViewController,
            sidebarItem: NSSplitViewItem
        ) {
            collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateAccessoryVisibility()
                    self?.updateSidebarWidthIfNeeded()
                }
            }

            guard let sidebarIndex = splitViewController.splitViewItems.firstIndex(where: { $0 === sidebarItem }),
                  splitViewController.splitView.subviews.indices.contains(sidebarIndex) else {
                return
            }

            let sidebarView = splitViewController.splitView.subviews[sidebarIndex]
            trackedSidebarView = sidebarView
            sidebarView.postsFrameChangedNotifications = true
            frameObservation = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: sidebarView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateSidebarWidthIfNeeded()
                }
            }
        }

        private func updateAccessoryVisibility() {
            guard let sidebarItem = installedSidebarItem,
                  let window = installedWindow,
                  let sidebarAccessoryController else { return }

            let isCollapsed = sidebarItem.isCollapsed
            sidebarAccessoryController.isHidden = isCollapsed

            guard let collapsedTitlebarAccessoryController else { return }

            let hasCollapsedAccessory = window.titlebarAccessoryViewControllers.contains { $0 === collapsedTitlebarAccessoryController }
            if isCollapsed {
                if !hasCollapsedAccessory {
                    window.addTitlebarAccessoryViewController(collapsedTitlebarAccessoryController)
                }
            } else if hasCollapsedAccessory,
                      let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === collapsedTitlebarAccessoryController }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }

        private func updateSidebarWidthIfNeeded() {
            guard let sidebarWidthConstraint else { return }

            let sidebarWidth = trackedSidebarView?.frame.width ?? 220
            sidebarWidthConstraint.constant = max(120, sidebarWidth - 8)
        }

        private func makeSidebarAccessoryController() -> NSSplitViewItemAccessoryViewController {
            let control = makeControlStrip()

            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            control.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(control)

            let widthConstraint = container.widthAnchor.constraint(equalToConstant: 220)
            sidebarWidthConstraint = widthConstraint

            NSLayoutConstraint.activate([
                widthConstraint,
                container.heightAnchor.constraint(equalToConstant: 38),
                control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                control.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor)
            ])

            let accessory = NSSplitViewItemAccessoryViewController()
            accessory.automaticallyAppliesContentInsets = false
            accessory.view = container
            return accessory
        }

        private func makeCollapsedTitlebarAccessoryController() -> NSTitlebarAccessoryViewController {
            let control = makeControlStrip()
            control.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 32))
            container.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(control)

            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                container.widthAnchor.constraint(equalToConstant: 96),
                container.heightAnchor.constraint(equalToConstant: 32)
            ])

            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = container
            accessory.layoutAttribute = .left
            accessory.fullScreenMinHeight = 32
            return accessory
        }

        private func makeControlStrip() -> NSView {
            let capsule = NSVisualEffectView()
            capsule.translatesAutoresizingMaskIntoConstraints = false
            capsule.material = .popover
            capsule.blendingMode = .withinWindow
            capsule.state = .active
            capsule.wantsLayer = true
            capsule.layer?.cornerRadius = 16
            capsule.layer?.masksToBounds = true

            let stack = NSStackView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.distribution = .fillEqually
            stack.spacing = 0

            let terminalButton = makeStripButton(
                symbolName: "terminal",
                tooltip: "New Terminal Tab",
                action: #selector(ControlStripActionTarget.didPressNewTerminal(_:))
            )
            let sidebarButton = makeStripButton(
                symbolName: "sidebar.left",
                tooltip: "Toggle Sidebar",
                action: #selector(ControlStripActionTarget.didPressToggleSidebar(_:))
            )

            let divider = NSBox()
            divider.boxType = .custom
            divider.borderType = .noBorder
            divider.fillColor = NSColor.separatorColor.withAlphaComponent(0.5)
            divider.translatesAutoresizingMaskIntoConstraints = false

            let terminalContainer = NSView()
            terminalContainer.translatesAutoresizingMaskIntoConstraints = false
            terminalContainer.addSubview(terminalButton)

            let sidebarContainer = NSView()
            sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
            sidebarContainer.addSubview(sidebarButton)

            NSLayoutConstraint.activate([
                terminalButton.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
                terminalButton.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor),
                terminalContainer.widthAnchor.constraint(equalToConstant: 46),
                terminalContainer.heightAnchor.constraint(equalToConstant: 30),

                sidebarButton.centerXAnchor.constraint(equalTo: sidebarContainer.centerXAnchor),
                sidebarButton.centerYAnchor.constraint(equalTo: sidebarContainer.centerYAnchor),
                sidebarContainer.widthAnchor.constraint(equalToConstant: 46),
                sidebarContainer.heightAnchor.constraint(equalToConstant: 30),

                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.heightAnchor.constraint(equalToConstant: 18)
            ])

            stack.addArrangedSubview(terminalContainer)
            stack.addArrangedSubview(divider)
            stack.addArrangedSubview(sidebarContainer)
            capsule.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 2),
                stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -2),
                stack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 1),
                stack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -1),
                capsule.widthAnchor.constraint(equalToConstant: 96),
                capsule.heightAnchor.constraint(equalToConstant: 32)
            ])

            return capsule
        }

        private func makeStripButton(
            symbolName: String,
            tooltip: String,
            action: Selector
        ) -> NSButton {
            let button = NSButton(
                image: NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) ?? NSImage(),
                target: actionTarget,
                action: action
            )
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .secondaryLabelColor
            button.imagePosition = .imageOnly
            button.setButtonType(.momentaryPushIn)
            button.toolTip = tooltip

            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28)
            ])

            return button
        }
    }

    @MainActor
    final class ControlStripActionTarget: NSObject {
        var onNewTerminal: (() -> Void)?
        var onToggleSidebar: (() -> Void)?

        @objc func didPressNewTerminal(_ sender: Any?) {
            onNewTerminal?()
        }

        @objc func didPressToggleSidebar(_ sender: Any?) {
            onToggleSidebar?()
        }
    }
}
