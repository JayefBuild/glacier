// SidebarHost.swift
// Adapter bridging Glacier's AppState/FileService to the ported CodeEdit
// NSOutlineView-based project navigator. The ported views only need access to
// a CEWorkspaceFileManager + a small set of settings + a callback to open a
// file. This class provides exactly that surface.

import Foundation
import Combine
import AppKit

final class SidebarHost: ObservableObject {
    /// The currently-opened workspace's file manager. `nil` when no folder is open.
    @Published var fileManager: CEWorkspaceFileManager?

    /// Filter text for the navigator. Empty = no filter. Throttled consumers (the
    /// outline controller's coordinator) subscribe to this publisher via `$navigatorFilter`.
    @Published var navigatorFilter: String = ""

    /// Whether folders should sort on top of files. Glacier default = true.
    @Published var sortFoldersOnTop: Bool = true

    /// Called by the outline view when the user selects a non-folder file (single-click).
    /// Glacier wires this to `AppState.openFile(...)`.
    var onOpenFile: ((URL) -> Void)?

    /// Called by the outline view when the user activates a file for tab opening (e.g. via
    /// the "Open in Tab" context menu). Glacier wires this to `AppState.openFile(...)`.
    var onOpenFileInTab: ((URL) -> Void)?

    /// Called by the outline view BEFORE a file/folder is trashed or deleted. Glacier
    /// wires this to (a) mark the URL as "discarding" in FileService so any pending
    /// auto-save is dropped, and (b) close the open tab immediately so the editor's
    /// onDisappear fires BEFORE the disk mutation. This prevents the "auto-save
    /// recreates the deleted file" race.
    var onFilesWillBeRemoved: (([URL]) -> Void)?

    /// Called by the outline view after files/folders are trashed or deleted. Glacier
    /// wires this to clear the "discarding" flag once the disk mutation is complete.
    var onFilesRemoved: (([URL]) -> Void)?

    /// Called by the outline view BEFORE a file/folder is renamed/moved. Glacier wires
    /// this to mark the OLD URL as discarding and close its tab so the editor's pending
    /// save doesn't fire against the old URL (recreating it after the move).
    var onFileWillBeRenamed: ((URL) -> Void)?

    /// Called by the outline view after a file/folder is renamed (moved on disk).
    /// Glacier wires this so open tabs retarget from the old URL to the new one.
    /// First arg is old URL, second is new URL.
    var onFileRenamed: ((URL, URL) -> Void)?

    /// Published hint that the outline view should reveal + select the given URL. A nil
    /// value means "no pending reveal". Consumers reset to nil after handling.
    @Published var revealRequest: URL?

    init() {}

    /// Swap in a new file manager (typically when the user opens a different folder).
    func setFileManager(_ manager: CEWorkspaceFileManager?) {
        fileManager = manager
    }

    /// Request the outline view to reveal and select the given URL.
    func reveal(_ url: URL) {
        revealRequest = url
    }
}
