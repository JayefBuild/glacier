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
