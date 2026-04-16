// Ported from CodeEdit (https://github.com/CodeEditApp/CodeEdit) — MIT License.
// See LICENSES/CodeEdit-LICENSE.md for full license text.
//
//  ProjectNavigatorMenu.swift
//  CodeEdit
//
//  Created by Lukas Pistrol on 07.04.22.
//

import SwiftUI
import UniformTypeIdentifiers

/// A subclass of `NSMenu` implementing the contextual menu for the project navigator.
///
/// The menu itself + its action methods all run on the main thread (context menus fire in
/// response to main-thread events and are never called from background work).
@MainActor
final class ProjectNavigatorMenu: NSMenu {

    /// The item to show the contextual menu for
    var item: CEWorkspaceFile?

    /// The sidebar host, for opening / mutating files
    weak var host: SidebarHost?

    /// The  `ProjectNavigatorViewController` is being called from.
    weak var sender: ProjectNavigatorViewController?

    init(_ sender: ProjectNavigatorViewController) {
        self.sender = sender
        super.init(title: "Options")
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Creates a `NSMenuItem` depending on the given arguments
    private func menuItem(_ title: String, action: Selector?, key: String = "") -> NSMenuItem {
        let mItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mItem.target = self

        return mItem
    }

    /// Configures the menu based on the current selection in the outline view.
    private func setupMenu() { // swiftlint:disable:this function_body_length
        guard let item else { return }
        let showInFinder = menuItem("Show in Finder", action: #selector(showInFinder))

        let openInTab = menuItem("Open in Tab", action: #selector(openInTab))
        let openExternalEditor = menuItem("Open with External Editor", action: #selector(openWithExternalEditor))

        let copyPath = menuItem("Copy Path", action: #selector(copyPath))
        let copyRelativePath = menuItem("Copy Relative Path", action: #selector(copyRelativePath))

        let newFile = menuItem("New File...", action: #selector(newFile))
        let newFileFromClipboard = menuItem(
            "New File from Clipboard",
            action: #selector(newFileFromClipboard),
            key: "v"
        )
        newFileFromClipboard.keyEquivalentModifierMask = [.command]
        let newFolder = menuItem("New Folder", action: #selector(newFolder))

        let rename = menuItem("Rename", action: #selector(renameFile))

        let trash = menuItem(
            "Move to Trash",
            action: item.url != host?.fileManager?.folderUrl ? #selector(trash) : nil
        )

        // trash has to be the previous menu item for delete.isAlternate to work correctly
        let delete = menuItem(
            "Delete Immediately...",
            action: item.url != host?.fileManager?.folderUrl ? #selector(delete) : nil
        )
        delete.keyEquivalentModifierMask = .option
        delete.isAlternate = true

        let duplicate = menuItem("Duplicate \(item.isFolder ? "Folder" : "File")", action: #selector(duplicate))

        items = [
            showInFinder,
            NSMenuItem.separator(),
            openInTab,
            openExternalEditor,
            NSMenuItem.separator(),
            copyPath,
            copyRelativePath,
            NSMenuItem.separator(),
            newFile,
            newFileFromClipboard,
            newFolder
        ]

        if canCreateFolderFromSelection() {
            items.append(menuItem("New Folder from Selection", action: #selector(newFolderFromSelection)))
        }
        items.append(NSMenuItem.separator())
        if selectedItems().count == 1 {
            items.append(rename)
        }

        items.append(
            contentsOf: [
                trash,
                delete,
                duplicate
            ]
        )
    }

    /// Updates the menu for the selected item and hides it if no item is provided.
    nonisolated override func update() {
        // NSMenu.update() is declared nonisolated by AppKit but only ever fires on the
        // main thread (menu presentation is a main-thread event). Safe to hop.
        let address = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        MainActor.assumeIsolated {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let menu = Unmanaged<ProjectNavigatorMenu>
                .fromOpaque(raw)
                .takeUnretainedValue()
            menu.removeAllItems()
            menu.setupMenu()
        }
    }
}
