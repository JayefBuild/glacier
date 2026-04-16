// Ported from CodeEdit (https://github.com/CodeEditApp/CodeEdit) — MIT License.
// See LICENSES/CodeEdit-LICENSE.md for full license text.
//
//  ProjectNavigatorViewController+NSOutlineViewDelegate.swift
//  CodeEdit
//
//  Created by Khan Winter on 7/13/24.
//

import AppKit

extension ProjectNavigatorViewController: NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView,
        shouldShowCellExpansionFor tableColumn: NSTableColumn?,
        item: Any
    ) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn else { return nil }

        let frameRect = NSRect(x: 0, y: 0, width: tableColumn.width, height: rowHeight)
        let cell = ProjectNavigatorTableViewCell(
            frame: frameRect,
            item: item as? CEWorkspaceFile,
            delegate: self,
            navigatorFilter: host?.navigatorFilter
        )
        cell.host = host
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }

        /// If multiple rows are selected, do not open any file.
        guard outlineView.selectedRowIndexes.count == 1 else { return }

        /// If only one row is selected, proceed as before
        let selectedIndex = outlineView.selectedRow

        guard let item = outlineView.item(atRow: selectedIndex) as? CEWorkspaceFile else { return }

        if !item.isFolder && shouldSendSelectionUpdate {
            shouldSendSelectionUpdate = false
            // Glacier: single-click on a file previews it (opens in a temporary tab).
            host?.onOpenFile?(item.url)
            shouldSendSelectionUpdate = true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        rowHeight
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        /// Save expanded items' state to restore when finish filtering.
        guard let host else { return }
        if host.navigatorFilter.isEmpty, let item = notification.userInfo?["NSObject"] as? CEWorkspaceFile {
            expandedItems.insert(item)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        /// Save expanded items' state to restore when finish filtering.
        guard let host else { return }
        if host.navigatorFilter.isEmpty, let item = notification.userInfo?["NSObject"] as? CEWorkspaceFile {
            expandedItems.remove(item)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        guard let id = object as? CEWorkspaceFile.ID,
              let item = host?.fileManager?.getFile(id, createIfNotFound: true) else { return nil }
        return item
    }

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        guard let item = item as? CEWorkspaceFile else { return nil }
        return item.id
    }

    /// Select a file by its path.
    func select(byPath path: String, forcesReveal: Bool) {
        guard let item = host?.fileManager?.getFile(path, createIfNotFound: true) else {
            return
        }
        // Always reveal when asked (Glacier has no "reveal on focus change" preference).
        if forcesReveal {
            reveal(item)
        }
        let row = outlineView.row(forItem: item)
        if row == -1 {
            outlineView.deselectRow(outlineView.selectedRow)
        }
        shouldSendSelectionUpdate = false
        outlineView.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
        shouldSendSelectionUpdate = true
    }

    /// Reveals the given `fileItem` in the outline view by expanding all the parent directories of the file.
    public func reveal(_ fileItem: CEWorkspaceFile) {
        if let parent = fileItem.parent {
            expandParent(item: parent)
        }
        let row = outlineView.row(forItem: fileItem)
        shouldSendSelectionUpdate = false
        outlineView.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
        shouldSendSelectionUpdate = true

        if row < 0 {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Could not find file",
                comment: "Could not find file"
            )
            alert.runModal()
            return
        } else {
            let visibleRect = scrollView.contentView.visibleRect
            let visibleRows = outlineView.rows(in: visibleRect)
            guard !visibleRows.contains(row) else {
                outlineView.scrollRowToVisible(row)
                return
            }
            let rowRect = outlineView.rect(ofRow: row)
            let centerY = rowRect.midY - (visibleRect.height / 2)
            let center = NSPoint(x: 0, y: centerY)
            outlineView.scrollRowToVisible(row)
            outlineView.scroll(center)
        }
    }

    /// Method for recursively expanding a file's parent directories.
    private func expandParent(item: CEWorkspaceFile) {
        if let parent = item.parent as CEWorkspaceFile? {
            expandParent(item: parent)
        }
        outlineView.expandItem(item)
    }

    /// Adds a tooltip to the file row.
    func outlineView( // swiftlint:disable:this function_parameter_count
        _ outlineView: NSOutlineView,
        toolTipFor cell: NSCell,
        rect: NSRectPointer,
        tableColumn: NSTableColumn?,
        item: Any,
        mouseLocation: NSPoint
    ) -> String {
        if let file = item as? CEWorkspaceFile {
            return file.name
        }
        return ""
    }
}
