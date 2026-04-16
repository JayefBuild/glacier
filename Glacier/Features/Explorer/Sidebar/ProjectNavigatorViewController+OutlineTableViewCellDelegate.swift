// Ported from CodeEdit (https://github.com/CodeEditApp/CodeEdit) — MIT License.
// See LICENSES/CodeEdit-LICENSE.md for full license text.
//
//  ProjectNavigatorViewController+OutlineTableViewCellDelegate.swift
//  CodeEdit
//
//  Created by Ziyuan Zhao on 2023/2/5.
//

import Foundation
import AppKit

// MARK: - OutlineTableViewCellDelegate

extension ProjectNavigatorViewController: OutlineTableViewCellDelegate {
    func moveFile(file: CEWorkspaceFile, to destination: URL) {
        do {
            guard let newFile = try host?.fileManager?.move(file: file, to: destination),
                  !newFile.isFolder else {
                return
            }
            outlineView.reloadItem(file.parent, reloadChildren: true)
            if !file.isFolder {
                host?.onOpenFileInTab?(newFile.url)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }

    func copyFile(file: CEWorkspaceFile, to destination: URL) {
        do {
            try host?.fileManager?.copy(file: file, to: destination)
        } catch {
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Dismiss")
            alert.runModal()
        }
    }

    func cellDidFinishEditing() {
        guard shouldReloadAfterDoneEditing else { return }
        outlineView.reloadData()
    }
}
