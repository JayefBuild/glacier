// Ported from CodeEdit (https://github.com/CodeEditApp/CodeEdit) — MIT License.
// See LICENSES/CodeEdit-LICENSE.md for full license text.
//
//  ProjectNavigatorViewController.swift
//  CodeEdit
//
//  Created by Lukas Pistrol on 07.04.22.
//

import AppKit
import SwiftUI
import OSLog

/// A `NSViewController` that handles the **ProjectNavigatorView** in the **NavigatorArea**.
final class ProjectNavigatorViewController: NSViewController {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Glacier",
        category: "ProjectNavigatorViewController"
    )

    var scrollView: NSScrollView!
    var outlineView: NSOutlineView!
    var noResultsLabel: NSTextField!

    /// Gets the folder structure
    var content: [CEWorkspaceFile] {
        guard let folderURL = host?.fileManager?.folderUrl else { return [] }
        guard let root = host?.fileManager?.getFile(folderURL.path) else { return [] }
        return [root]
    }

    var filteredContentChildren: [CEWorkspaceFile: [CEWorkspaceFile]] = [:]
    var expandedItems: Set<CEWorkspaceFile> = []

    weak var host: SidebarHost?

    // Glacier: hardcoded defaults (icons always colored, extensions always visible, row = 22pt).
    var rowHeight: Double = 22 {
        willSet {
            if newValue != rowHeight {
                outlineView.rowHeight = newValue
                outlineView.reloadData()
            }
        }
    }

    /// This helps determine whether or not to send an `openTab` when the selection changes.
    var shouldSendSelectionUpdate: Bool = true

    var shouldReloadAfterDoneEditing: Bool = false

    var filterIsEmpty: Bool {
        host?.navigatorFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }

    /// Setup the ``scrollView`` and ``outlineView``
    override func loadView() {
        self.scrollView = NSScrollView()
        self.scrollView.hasVerticalScroller = true
        self.view = scrollView

        self.outlineView = ProjectNavigatorNSOutlineView()
        self.outlineView.dataSource = self
        self.outlineView.delegate = self
        self.outlineView.autosaveExpandedItems = true
        self.outlineView.autosaveName = host?.fileManager?.folderUrl.path ?? ""
        self.outlineView.headerView = nil
        self.outlineView.menu = ProjectNavigatorMenu(self)
        self.outlineView.menu?.delegate = self
        self.outlineView.doubleAction = #selector(onItemDoubleClicked)
        self.outlineView.allowsMultipleSelection = true

        self.outlineView.setAccessibilityIdentifier("ProjectNavigator")
        self.outlineView.setAccessibilityLabel("Project Navigator")

        let column = NSTableColumn(identifier: .init(rawValue: "Cell"))
        column.title = "Cell"
        outlineView.addTableColumn(column)

        outlineView.setDraggingSourceOperationMask(.move, forLocal: false)
        outlineView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = outlineView
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = .init(top: 10, left: 0, bottom: 0, right: 0)
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        outlineView.expandItem(outlineView.item(atRow: 0))

        /// Get autosave expanded items.
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? CEWorkspaceFile {
                if outlineView.isItemExpanded(item) {
                    expandedItems.insert(item)
                }
            }
        }

        /// "No Filter Results" label.
        noResultsLabel = NSTextField(labelWithString: "No Filter Results")
        noResultsLabel.isHidden = true
        noResultsLabel.font = NSFont.systemFont(ofSize: 16)
        noResultsLabel.textColor = NSColor.secondaryLabelColor
        outlineView.addSubview(noResultsLabel)
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noResultsLabel.centerXAnchor.constraint(equalTo: outlineView.centerXAnchor),
            noResultsLabel.centerYAnchor.constraint(equalTo: outlineView.centerYAnchor)
        ])
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        outlineView?.removeFromSuperview()
        scrollView?.removeFromSuperview()
        noResultsLabel?.removeFromSuperview()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Forces to reveal the selected file through the command regardless of the auto reveal setting
    @objc
    func revealFile(_ sender: Any) {
        // Glacier: no editor tab concept here — nothing to reveal "by selected tab".
    }

    /// Updates the selection of the ``outlineView`` whenever it changes.
    /// - Parameter itemID: The id of the file or folder (a file path).
    /// - Parameter forcesReveal: Force-reveal by expanding parents.
    func updateSelection(itemID: String?, forcesReveal: Bool = false) {
        guard let itemID else {
            outlineView.deselectRow(outlineView.selectedRow)
            return
        }
        self.select(byPath: itemID, forcesReveal: forcesReveal)
    }

    /// Expand or collapse the folder on double click
    @objc
    private func onItemDoubleClicked() {
        /// If there are multiples items selected, don't do anything, just like in Xcode.
        guard outlineView.selectedRowIndexes.count == 1 else { return }

        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? CEWorkspaceFile else { return }

        if item.isFolder {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        } else {
            // Glacier: open the file in a tab (permanent).
            host?.onOpenFileInTab?(item.url) ?? host?.onOpenFile?(item.url)
        }
    }

    func handleFilterChange() {
        filteredContentChildren.removeAll()
        outlineView.reloadData()

        /// If the filter is empty, show all items and restore the expanded state.
        if !filterIsEmpty {
            outlineView.autosaveExpandedItems = false
            /// Expand all items for search.
            outlineView.expandItem(outlineView.item(atRow: 0), expandChildren: true)
        } else {
            restoreExpandedState()
            outlineView.autosaveExpandedItems = true
        }

        if let root = content.first(where: { $0.isRoot }), let children = filteredContentChildren[root] {
            if children.isEmpty {
                noResultsLabel.isHidden = false
                outlineView.hideRows(at: IndexSet(integer: 0))
            } else {
                noResultsLabel.isHidden = true
            }
        }
    }

    /// Checks if the given filter matches the name of the item or any of its children.
    func fileSearchMatches(_ filter: String, for item: CEWorkspaceFile) -> Bool {
        guard !filterIsEmpty else {
            return true
        }

        if item.name.localizedCaseInsensitiveContains(filter) {
            saveAllContentChildren(for: item)
            return true
        }

        if let children = host?.fileManager?.childrenOfFile(item) {
            return children.contains { fileSearchMatches(filter, for: $0) }
        }

        return false
    }

    /// Saves all children of a given folder item to the filtered content cache.
    private func saveAllContentChildren(for item: CEWorkspaceFile) {
        guard item.isFolder, filteredContentChildren[item] == nil else { return }

        if let children = host?.fileManager?.childrenOfFile(item) {
            filteredContentChildren[item] = children
            for child in children.filter({ $0.isFolder }) {
                saveAllContentChildren(for: child)
            }
        }
    }

    /// Restores the expanded state of items when finish searching.
    private func restoreExpandedState() {
        let copy = expandedItems
        outlineView.collapseItem(outlineView.item(atRow: 0), collapseChildren: true)

        for item in copy {
            expandParentsRecursively(of: item)
            outlineView.expandItem(item)
        }

        expandedItems = copy
    }

    /// Recursively expands all parent items of a given item in the outline view.
    private func expandParentsRecursively(of item: CEWorkspaceFile) {
        if let parent = item.parent {
            expandParentsRecursively(of: parent)
            outlineView.expandItem(parent)
        }
    }
}
