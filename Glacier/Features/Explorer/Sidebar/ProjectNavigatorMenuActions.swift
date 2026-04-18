// Ported from CodeEdit (https://github.com/CodeEditApp/CodeEdit) — MIT License.
// See LICENSES/CodeEdit-LICENSE.md for full license text.
//
//  ProjectNavigatorMenuActions.swift
//  CodeEdit
//
//  Created by Leonardo Larrañaga on 10/11/24.
//

import AppKit
import SwiftUI

@MainActor
extension ProjectNavigatorMenu {
    /// Default name for newly created files/folders: today's date in `YYYY-MM-DD-` format.
    static var defaultNewItemName: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-"
        return formatter.string(from: Date())
    }

    /// - Returns: the currently selected `CEWorkspaceFile` items in the outline view.
    func selectedItems() -> Set<CEWorkspaceFile> {
        guard let sender else { return [] }
        let selectedItems = Set(sender.outlineView.selectedRowIndexes.compactMap {
            sender.outlineView.item(atRow: $0) as? CEWorkspaceFile
        })

        /// Item that the user brought up the menu with...
        if let menuItem = sender.outlineView.item(atRow: sender.outlineView.clickedRow) as? CEWorkspaceFile {
            /// If the item is not in the set, just like in Xcode, only modify that item.
            if !selectedItems.contains(menuItem) {
                return Set([menuItem])
            }
        }

        return selectedItems
    }

    /// Verify if a folder can be made from selection by getting the amount of parents found in the selected items.
    func canCreateFolderFromSelection() -> Bool {
        var uniqueParents: Set<CEWorkspaceFile> = []
        for file in selectedItems() {
            if let parent = file.parent {
                uniqueParents.insert(parent)
            }
        }

        return uniqueParents.count == 1
    }

    /// Action that opens **Finder** at the items location.
    @objc
    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedItems().map { $0.url })
    }

    /// Action that opens the item, identical to clicking it.
    @objc
    func openInTab() {
        guard let sender else { return }
        /// Sort the selected items first by their parent and then by name.
        let sortedItems = selectedItems().sorted { (item1, item2) -> Bool in
            let parent1 = sender.outlineView.parent(forItem: item1) as? CEWorkspaceFile
            let parent2 = sender.outlineView.parent(forItem: item2) as? CEWorkspaceFile

            if parent1 != parent2 {
                return sender.outlineView.row(forItem: parent1) < sender.outlineView.row(forItem: parent2)
            } else {
                return item1.name < item2.name
            }
        }

        /// Open the items in order.
        sortedItems.forEach { item in
            host?.onOpenFileInTab?(item.url)
        }
    }

    /// Action that opens in an external editor
    @objc
    func openWithExternalEditor() {
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = selectedItems().map { $0.url.absoluteString }
        try? process.run()
    }

    // TODO: allow custom file names
    /// Action that creates a new untitled file
    @objc
    func newFile() {
        guard let item else { return }
        do {
            if let newFile = try host?.fileManager?.addFile(fileName: Self.defaultNewItemName, toFile: item) {
                host?.onOpenFileInTab?(newFile.url)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }

    /// Opens the rename file dialogue on the cell this was presented from.
    @objc
    func renameFile() {
        guard let sender, let item else { return }
        let row = sender.outlineView.row(forItem: item)
        guard row >= 0,
              let cell = sender.outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
              ) as? ProjectNavigatorTableViewCell else {
            return
        }
        sender.outlineView.window?.makeFirstResponder(cell.textField)
    }

    /// Action that creates a new file with clipboard content
    @objc
    func newFileFromClipboard() {
        guard let item else { return }
        do {
            let clipBoardContent = NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
            if let clipBoardContent,
               !clipBoardContent.isEmpty,
               let newFile = try host?.fileManager?.addFile(
                    fileName: Self.defaultNewItemName,
                    toFile: item,
                    contents: clipBoardContent
               ) {
                host?.onOpenFileInTab?(newFile.url)
                renameFile()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }

    /// Action that creates a new untitled folder
    @objc
    func newFolder() {
        guard let item else { return }
        do {
            _ = try host?.fileManager?.addFolder(folderName: Self.defaultNewItemName, toFile: item)
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }

    /// Creates a new folder with the items selected.
    @objc
    func newFolderFromSelection() {
        guard let host, let workspaceFileManager = host.fileManager else { return }

        let selectedItems = selectedItems()
        guard let parent = selectedItems.first?.parent else { return }

        var newFolderURL = parent.url.appendingPathComponent("New Folder With Items", conformingTo: .folder)
        var folderNumber = 0
        while workspaceFileManager.fileManager.fileExists(atPath: newFolderURL.path) {
            folderNumber += 1
            newFolderURL = parent.url.appending(path: "New Folder With Items \(folderNumber)")
        }

        do {
            for selectedItem in selectedItems where selectedItem.url != newFolderURL {
                try workspaceFileManager.move(file: selectedItem, to: newFolderURL.appending(path: selectedItem.name))
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }

        reloadData()
    }

    /// Action that moves the item to trash.
    @objc
    func trash() {
        do {
            let items = selectedItems()
            let removedURLs = items.map(\.url)
            // Close tabs + mark URLs as discarding BEFORE touching disk, so the editor's
            // onDisappear→saveNow race cannot recreate the file we're about to trash.
            host?.onFilesWillBeRemoved?(removedURLs)
            var affectedParents: Set<CEWorkspaceFile> = []
            try items.forEach { item in
                guard FileManager.default.fileExists(atPath: item.url.path) else {
                    return
                }
                try host?.fileManager?.trash(file: item)
                if let parent = item.parent {
                    affectedParents.insert(parent)
                }
            }
            // CEWorkspaceFileManager.trash only touches disk — it does NOT rebuild the
            // in-memory childrenMap. FSEvents will eventually fire and reconcile, but
            // until then the sidebar shows the trashed item. Force a rebuild now so the
            // row disappears immediately.
            for parent in affectedParents {
                try? host?.fileManager?.rebuildFiles(fromItem: parent)
            }
            host?.onFilesRemoved?(removedURLs)
            reloadData()
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }

    /// Action that deletes the item immediately.
    @objc
    func delete() {
        do {
            let selectedItems = selectedItems()
            let removedURLs = selectedItems.map(\.url)
            // See trash() — close + mark discarding before disk mutation.
            host?.onFilesWillBeRemoved?(removedURLs)
            let affectedParents: Set<CEWorkspaceFile> = Set(selectedItems.compactMap { $0.parent })
            if selectedItems.count == 1 {
                try selectedItems.forEach { item in
                    try host?.fileManager?.delete(file: item)
                }
            } else {
                try host?.fileManager?.batchDelete(files: selectedItems)
            }
            // Force-rebuild children for every parent of a deleted item — see trash()
            // for why this is necessary (disk write doesn't update the cache).
            for parent in affectedParents {
                try? host?.fileManager?.rebuildFiles(fromItem: parent)
            }
            host?.onFilesRemoved?(removedURLs)
            reloadData()
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }

    /// Action that duplicates the item
    @objc
    func duplicate() {
        do {
            try selectedItems().forEach { item in
                try host?.fileManager?.duplicate(file: item)
            }
            reloadData()
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }

    /// Copies the absolute path of the selected files
    @objc
    func copyPath() {
        let paths = selectedItems().map {
            $0.url.standardizedFileURL.path
        }.sorted().joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    /// Copies the relative path of the selected files
    @objc
    func copyRelativePath() {
        guard let rootPath = host?.fileManager?.folderUrl else {
            return
        }
        let paths = selectedItems().map {
            let destinationComponents = $0.url.standardizedFileURL.pathComponents
            let baseComponents = rootPath.standardizedFileURL.pathComponents

            var prefixCount = 0
            while prefixCount < min(destinationComponents.count, baseComponents.count)
                    && destinationComponents[prefixCount] == baseComponents[prefixCount] {
                prefixCount += 1
            }
            let upPath = String(repeating: "../", count: baseComponents.count - prefixCount)
            let downPath = destinationComponents[prefixCount...].joined(separator: "/")
            return upPath + downPath
        }.sorted().joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    private func reloadData() {
        sender?.outlineView.reloadData()
        sender?.filteredContentChildren.removeAll()
    }
}
