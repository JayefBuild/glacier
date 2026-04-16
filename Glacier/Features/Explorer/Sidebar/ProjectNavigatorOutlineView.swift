// Ported from CodeEdit (https://github.com/CodeEditApp/CodeEdit) — MIT License.
// See LICENSES/CodeEdit-LICENSE.md for full license text.
//
//  ProjectNavigatorOutlineView.swift
//  CodeEdit
//
//  Created by Lukas Pistrol on 05.04.22.
//

import SwiftUI
import Combine

/// Non-isolated shim that conforms to `CEWorkspaceFileManagerObserver` and forwards updates
/// to a callback. Lets a MainActor-isolated coordinator receive events without violating
/// the protocol's nonisolated conformance requirements.
final class ObserverAdapter: NSObject, CEWorkspaceFileManagerObserver, @unchecked Sendable {
    private let onUpdate: (Set<CEWorkspaceFile>) -> Void
    init(onUpdate: @escaping (Set<CEWorkspaceFile>) -> Void) {
        self.onUpdate = onUpdate
    }
    func fileManagerUpdated(updatedItems: Set<CEWorkspaceFile>) {
        onUpdate(updatedItems)
    }
}

/// Wraps an ``ProjectNavigatorViewController`` inside a `NSViewControllerRepresentable`
struct ProjectNavigatorOutlineView: NSViewControllerRepresentable {

    @ObservedObject var host: SidebarHost

    typealias NSViewControllerType = ProjectNavigatorViewController

    func makeNSViewController(context: Context) -> ProjectNavigatorViewController {
        let controller = ProjectNavigatorViewController()
        controller.host = host
        if let observer = context.coordinator.observer {
            host.fileManager?.addObserver(observer)
        }
        context.coordinator.lastFileManager = host.fileManager
        context.coordinator.controller = controller
        context.coordinator.bind(to: host)
        return controller
    }

    func updateNSViewController(_ nsViewController: ProjectNavigatorViewController, context: Context) {
        // Host may not have changed but fileManager might have been swapped.
        if context.coordinator.lastFileManager !== host.fileManager {
            // Remove from old, add to new.
            if let old = context.coordinator.lastFileManager,
               let observer = context.coordinator.observer {
                old.removeObserver(observer)
            }
            if let observer = context.coordinator.observer {
                host.fileManager?.addObserver(observer)
            }
            context.coordinator.lastFileManager = host.fileManager
            nsViewController.outlineView?.reloadData()
            // Expand the root so the tree isn't a single collapsed row.
            if let outlineView = nsViewController.outlineView,
               let rootItem = outlineView.item(atRow: 0) {
                outlineView.expandItem(rootItem)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(host)
    }

    @MainActor
    final class Coordinator: NSObject {
        init(_ host: SidebarHost) {
            self.host = host
            super.init()
            self.observerAdapter = ObserverAdapter { [weak self] items in
                // Observer calls us through CEWorkspaceFileManager's main-queue hop,
                // so `self` is already on the main thread. Hop to MainActor formally.
                let urls = Set(items.map(\.url))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.applyUpdate(urls: urls)
                    }
                }
            }
        }

        var cancellables: Set<AnyCancellable> = []
        weak var host: SidebarHost?
        weak var controller: ProjectNavigatorViewController?
        weak var lastFileManager: CEWorkspaceFileManager?
        var observerAdapter: ObserverAdapter?

        /// Returns the observer adapter as a non-optional `CEWorkspaceFileManagerObserver` ready
        /// for registration with the file manager. The adapter is non-isolated; it hops to the
        /// MainActor before touching any coordinator state.
        var observer: CEWorkspaceFileManagerObserver? {
            observerAdapter
        }

        func bind(to host: SidebarHost) {
            self.host = host
            self.lastFileManager = host.fileManager

            host.$navigatorFilter
                .throttle(for: 0.1, scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in
                    self?.controller?.handleFilterChange()
                }
                .store(in: &cancellables)

            host.$sortFoldersOnTop
                .throttle(for: 0.1, scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in
                    self?.controller?.handleFilterChange()
                }
                .store(in: &cancellables)

            host.$revealRequest
                .compactMap { $0 }
                .sink { [weak self] url in
                    guard let controller = self?.controller else { return }
                    controller.updateSelection(itemID: url.path, forcesReveal: true)
                    DispatchQueue.main.async {
                        self?.host?.revealRequest = nil
                    }
                }
                .store(in: &cancellables)
        }

        private func applyUpdate(urls: Set<URL>) {
            guard let outlineView = controller?.outlineView,
                  let manager = host?.fileManager else { return }
            let updatedItems = Set(urls.compactMap { manager.getFile($0.path) })
            let selectedItems: [CEWorkspaceFile] = outlineView.selectedRowIndexes
                .compactMap { outlineView.item(atRow: $0) as? CEWorkspaceFile }

            if outlineView.window?.firstResponder !== outlineView
                && outlineView.window?.firstResponder is NSTextView
                && (outlineView.window?.firstResponder as? NSView)?.isDescendant(of: outlineView) == true {
                controller?.shouldReloadAfterDoneEditing = true
            } else {
                for item in updatedItems {
                    outlineView.reloadItem(item, reloadChildren: true)
                }
            }

            let selectedIndexes = selectedItems.compactMap({ outlineView.row(forItem: $0) }).filter({ $0 >= 0 })
            controller?.shouldSendSelectionUpdate = false
            outlineView.selectRowIndexes(IndexSet(selectedIndexes), byExtendingSelection: false)
            controller?.shouldSendSelectionUpdate = true
        }

        deinit {
            // lastFileManager holds a weak reference; observer cleanup happens via removeObserver
            // on the `updateNSViewController` swap. `NSHashTable.weakObjects` also cleans up on its own.
        }
    }
}
