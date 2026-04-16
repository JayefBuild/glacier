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
            // Close any open tab for the old URL + mark it as discarding BEFORE the
            // disk move. Otherwise the editor's debounced save fires against the old
            // URL after the move completes, recreating the original file.
            host?.onFileWillBeRenamed?(file.url)
            // move(...) returns nil when the destination parent isn't currently indexed —
            // the move STILL happened on disk. The original bug: bailing on nil here left
            // the sidebar showing a stale node for the pre-move file while the post-move
            // file appeared via FSEvents reconciliation, producing the "rename creates a
            // copy" symptom. Always reload the parent regardless of the return value.
            let newFile = try host?.fileManager?.move(file: file, to: destination)
            outlineView.reloadItem(file.parent, reloadChildren: true)
            if let newFile, !newFile.isFolder {
                host?.onOpenFileInTab?(newFile.url)
            }
            // Notify AppState so any open tab for the old URL retargets to the new one.
            host?.onFileRenamed?(file.url, destination)
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
