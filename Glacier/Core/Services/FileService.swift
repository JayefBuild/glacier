// FileService.swift
// Handles all file system operations: loading, reading, watching.

import Foundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class FileService: ObservableObject {

    // MARK: - State

    @Published var rootItems: [FileItem] = []
    @Published var rootURL: URL?
    @Published var isLoading: Bool = false
    @Published private(set) var treeChangeToken = UUID()

    private var expandedDirectoryURLs: Set<URL> = []
    private var rootEventStream: DirectoryEventStream?
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var pendingRefreshURLs: Set<URL> = []

    // MARK: - CEWorkspaceFileManager bridge
    //
    // Phase 2: FileService still maintains the legacy `rootItems: [FileItem]` tree that
    // its existing SwiftUI/AppState callers rely on, but also owns a CEWorkspaceFileManager
    // which is the single source of truth for the new NSOutlineView sidebar. Both trees
    // refresh from disk on the same event stream, so they stay in sync.
    private(set) var manager: CEWorkspaceFileManager?

    // MARK: - Open Folder

    func openFolder(at url: URL) {
        let normalizedURL = url.standardizedFileURL
        let isSameRoot = rootURL?.standardizedFileURL == normalizedURL

        rootURL = normalizedURL
        if !isSameRoot {
            rootItems = []
            expandedDirectoryURLs = []
            pendingRefreshWorkItem?.cancel()
            pendingRefreshWorkItem = nil
            pendingRefreshURLs.removeAll()
            rootEventStream = nil
            manager?.cleanUp()
            manager = CEWorkspaceFileManager(
                folderUrl: normalizedURL,
                ignoredFilesAndFolders: Self.defaultIgnoredFilesAndFolders
            )
        }
        isLoading = true
        WorkspaceStore.shared.add(normalizedURL)

        let expandedDirectories = Set(expandedDirectoryURLs.filter { directoryExists(at: $0) })
        Task.detached(priority: .userInitiated) {
            let items = self.loadChildren(of: normalizedURL, expandedDirectories: expandedDirectories)
            await MainActor.run {
                self.rootItems = items
                self.expandedDirectoryURLs = expandedDirectories
                self.isLoading = false
                self.ensureDirectoryEventStream()
                self.markTreeDidChange()
            }
        }
    }

    func closeFolder() {
        rootURL = nil
        rootItems = []
        expandedDirectoryURLs = []
        pendingRefreshWorkItem?.cancel()
        pendingRefreshWorkItem = nil
        pendingRefreshURLs.removeAll()
        rootEventStream = nil
        manager?.cleanUp()
        manager = nil
        markTreeDidChange()
    }

    /// Default ignore list for the CE file manager. Keep minimal — we don't want to
    /// silently drop files. .DS_Store is the obvious noise candidate.
    static let defaultIgnoredFilesAndFolders: Set<String> = [".DS_Store"]

    // MARK: - Load Children

    nonisolated func loadChildren(of url: URL) -> [FileItem] {
        loadChildren(of: url, expandedDirectories: [])
    }

    nonisolated private func loadChildren(of url: URL, expandedDirectories: Set<URL>) -> [FileItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .nameKey],
            options: []
        ) else { return [] }

        return contents
            .compactMap { childURL -> FileItem? in
                let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let normalizedChildURL = childURL.standardizedFileURL
                let item = FileItem(url: normalizedChildURL, isDirectory: isDirectory)
                if isDirectory, expandedDirectories.contains(normalizedChildURL) {
                    item.children = loadChildren(of: normalizedChildURL, expandedDirectories: expandedDirectories)
                    item.isLoaded = true
                    item.isExpanded = true
                }
                return item
            }
            .sorted { lhs, rhs in
                // Folders first, then alphabetical
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Expand / Collapse

    func toggleExpansion(of item: FileItem) {
        if item.isExpanded {
            item.isExpanded = false
            expandedDirectoryURLs.remove(item.url)
            ensureDirectoryEventStream()
            return
        }

        expandedDirectoryURLs.insert(item.url)
        if item.isLoaded {
            item.isExpanded = true
            if let children = item.children {
                restoreExpandedDirectories(in: children)
            }
            ensureDirectoryEventStream()
            return
        }

        let expandedDirectories = expandedDirectoryURLs
        // Load off the main thread, then update on main
        Task.detached(priority: .userInitiated) {
            let children = self.loadChildren(of: item.url, expandedDirectories: expandedDirectories)
            await MainActor.run {
                item.children = children
                item.isLoaded = true
                item.isExpanded = true
                self.ensureDirectoryEventStream()
            }
        }
    }

    // MARK: - Create File

    func createFile(
        named name: String,
        in directory: URL,
        defaultExtension: String? = nil
    ) throws -> URL {
        let normalizedName = normalizedCreatedFileName(name, defaultExtension: defaultExtension)
        let dest = directory.appendingPathComponent(normalizedName)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        refreshDirectoriesAfterMutation([directory])
        return dest
    }

    private func normalizedCreatedFileName(_ name: String, defaultExtension: String?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let defaultExtension,
            !defaultExtension.isEmpty,
            !trimmed.isEmpty
        else {
            return trimmed
        }

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        if lastPathComponent.hasPrefix(".") {
            return trimmed
        }

        if URL(fileURLWithPath: trimmed).pathExtension.isEmpty {
            return "\(trimmed).\(defaultExtension)"
        }

        return trimmed
    }

    // MARK: - Create Folder

    func createFolder(named name: String, in directory: URL) throws -> URL {
        let dest = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        refreshDirectoriesAfterMutation([directory])
        return dest
    }

    // MARK: - Rename

    func rename(item: FileItem, to newName: String) throws {
        let sourceURL = item.url.standardizedFileURL
        let dest = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .standardizedFileURL
        try FileManager.default.moveItem(at: item.url, to: dest)
        if item.isDirectory {
            rewriteExpandedDirectoryURLs(movingFrom: sourceURL, to: dest)
        }
        refreshDirectoriesAfterMutation([sourceURL.deletingLastPathComponent()])
    }

    // MARK: - Trash

    func trash(item: FileItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        if item.isDirectory {
            removeExpandedDirectoryURLs(inSubtreeOf: item.url)
        }
        refreshDirectoriesAfterMutation([item.url.deletingLastPathComponent()])
    }

    // MARK: - Collapse All

    func collapseAll() {
        func collapse(_ items: [FileItem]) {
            for item in items {
                item.isExpanded = false
                if let children = item.children { collapse(children) }
            }
        }
        collapse(rootItems)
        expandedDirectoryURLs.removeAll()
        ensureDirectoryEventStream()
    }

    // MARK: - Move

    func move(from sourceURL: URL, into destinationDirectory: URL) throws {
        let normalizedSourceURL = sourceURL.standardizedFileURL
        let normalizedDestinationDirectory = destinationDirectory.standardizedFileURL
        // Don't move into itself or a child of itself
        guard !normalizedDestinationDirectory.path.hasPrefix(normalizedSourceURL.path + "/"),
              normalizedSourceURL != normalizedDestinationDirectory else { return }

        let dest = normalizedDestinationDirectory
            .appendingPathComponent(normalizedSourceURL.lastPathComponent)
            .standardizedFileURL
        guard dest != normalizedSourceURL else { return }

        let sourceIsDirectory = directoryExists(at: normalizedSourceURL)
        try FileManager.default.moveItem(at: normalizedSourceURL, to: dest)
        if sourceIsDirectory {
            rewriteExpandedDirectoryURLs(movingFrom: normalizedSourceURL, to: dest)
        }
        refreshDirectoriesAfterMutation([
            normalizedSourceURL.deletingLastPathComponent(),
            normalizedDestinationDirectory
        ])
    }

    // MARK: - Reload

    func reload() {
        guard let rootURL else { return }
        openFolder(at: rootURL)
    }

    // MARK: - Visible Items

    func visibleItems() -> [FileItem] {
        var items: [FileItem] = []

        func appendVisibleItems(from nodes: [FileItem]) {
            for node in nodes {
                items.append(node)
                if node.isExpanded, let children = node.children {
                    appendVisibleItems(from: children)
                }
            }
        }

        appendVisibleItems(from: rootItems)
        return items
    }

    // MARK: - Write File

    func writeFile(text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Read File

    func readFile(at url: URL) async throws -> FileContent {
        let pathExtension = url.pathExtension.lowercased()
        let kind = resolvedFileKind(for: url, pathExtension: pathExtension)

        switch kind {
        case .image:
            return .image(url)

        case .video:
            return .video(url)

        case .audio:
            return .audio(url)

        case .pdf:
            return .pdf(url)

        case .binary:
            return .binary(url)

        case .markwhen:
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return .markwhen(text, url)
            }
            return .binary(url)

        case .excalidraw:
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return .excalidraw(text, url)
            }
            return .binary(url)

        default:
            guard sampleLooksLikeText(at: url) else {
                return .binary(url)
            }

            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return .text(text, pathExtension)
            } else if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
                return .text(text, pathExtension)
            } else {
                return .binary(url)
            }
        }
    }

    private func resolvedFileKind(for url: URL, pathExtension: String) -> FileKind {
        let extensionKind = FileTypeRegistry.kind(for: pathExtension)
        guard extensionKind == .unknown else {
            return extensionKind
        }

        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return .unknown
        }

        if contentType.conforms(to: .image) {
            return .image
        }
        if contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) {
            return .video
        }
        if contentType.conforms(to: .audio) {
            return .audio
        }
        if contentType.conforms(to: .pdf) {
            return .pdf
        }
        if contentType.conforms(to: .json) {
            return .json
        }
        if contentType.conforms(to: .plainText)
            || contentType.conforms(to: .text)
            || contentType.conforms(to: .sourceCode)
            || contentType.conforms(to: .xml)
            || contentType.conforms(to: .html) {
            return .text
        }

        return .unknown
    }

    private func sampleLooksLikeText(at url: URL, sampleSize: Int = 8192) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return true
        }
        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: sampleSize), !data.isEmpty else {
            return true
        }

        if data.contains(0) {
            return false
        }

        let suspiciousByteCount = data.reduce(into: 0) { count, byte in
            switch byte {
            case 9, 10, 13, 32...126:
                break
            case 0x80...0xFF:
                break
            default:
                count += 1
            }
        }

        return Double(suspiciousByteCount) / Double(data.count) < 0.02
    }

    private func restoreExpandedDirectories(in items: [FileItem]) {
        for item in items where item.isDirectory && expandedDirectoryURLs.contains(item.url) {
            item.isExpanded = true
            item.isLoaded = true
            if let children = item.children {
                restoreExpandedDirectories(in: children)
            }
        }
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - Directory Watching (Phase 2: single root FSEvents stream)
    //
    // We intentionally watch the entire tree below rootURL with ONE FSEvents stream
    // instead of per-folder watchers. This eliminates the "new subfolder doesn't get
    // watched" bug class: FSEvents covers newly-created descendants automatically.
    // On any event, we re-diff the affected parent against the filesystem — advisory
    // events, authoritative diffs. Also resilient to missed/reordered/mislabeled events.

    private func ensureDirectoryEventStream() {
        guard let rootURL else {
            rootEventStream = nil
            return
        }

        // Rebuild the stream only when the root changes; otherwise keep the existing one.
        if rootEventStream == nil {
            rootEventStream = DirectoryEventStream(rootURL: rootURL) { [weak self] events in
                // FSEvents delivers on our background queue. Hop to main to touch state.
                Task { @MainActor in
                    self?.handleDirectoryEvents(events)
                }
            }
        }
    }

    private func handleDirectoryEvents(_ events: [DirectoryEvent]) {
        guard let rootURL else { return }

        for event in events {
            switch event.kind {
            case .rootDeleted:
                // Workspace folder was deleted — treat as close.
                closeFolder()
                return

            case .rootRenamed:
                // Root was renamed/moved by something outside our control.
                // FSEvents doesn't reliably report the new path, so reload what we have.
                scheduleRefresh(for: rootURL)

            case .changeInDirectory:
                // The event path is the file or directory that changed. We re-diff
                // its parent folder (which is what actually matters for the tree).
                let parent = event.url.deletingLastPathComponent().standardizedFileURL
                scheduleRefresh(for: parent)
            }
        }
    }

    private func scheduleRefresh(for directoryURL: URL) {
        pendingRefreshURLs.insert(directoryURL.standardizedFileURL)
        pendingRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingRefreshes()
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func flushPendingRefreshes() {
        let urls = Array(pendingRefreshURLs)
        pendingRefreshURLs.removeAll()
        pendingRefreshWorkItem = nil
        refreshDirectoriesAfterMutation(urls)
    }

    private func refreshDirectoriesAfterMutation(_ urls: [URL]) {
        guard let rootURL else { return }

        let normalizedURLs = Set(urls.map(\.standardizedFileURL))
        guard !normalizedURLs.isEmpty else { return }

        expandedDirectoryURLs = Set(expandedDirectoryURLs.filter { directoryExists(at: $0) })
        let expandedDirectories = expandedDirectoryURLs
        var didChangeTree = false

        if normalizedURLs.contains(rootURL) {
            rootItems = loadChildren(of: rootURL, expandedDirectories: expandedDirectories)
            didChangeTree = true
        }

        for directoryURL in normalizedURLs where directoryURL != rootURL {
            didChangeTree = refreshDirectoryAfterMutation(
                at: directoryURL,
                expandedDirectories: expandedDirectories
            ) || didChangeTree
        }

        ensureDirectoryEventStream()
        if didChangeTree {
            markTreeDidChange()
        }
    }

    private func refreshDirectoryAfterMutation(
        at directoryURL: URL,
        expandedDirectories: Set<URL>
    ) -> Bool {
        let normalizedDirectoryURL = directoryURL.standardizedFileURL
        guard let rootURL else { return false }

        if normalizedDirectoryURL == rootURL {
            rootItems = loadChildren(of: rootURL, expandedDirectories: expandedDirectories)
            return true
        }

        if !directoryExists(at: normalizedDirectoryURL) {
            let parentURL = normalizedDirectoryURL.deletingLastPathComponent().standardizedFileURL
            guard parentURL != normalizedDirectoryURL,
                  parentURL.path.hasPrefix(rootURL.path),
                  parentURL != rootURL else {
                rootItems = loadChildren(of: rootURL, expandedDirectories: expandedDirectories)
                return true
            }

            return refreshDirectoryAfterMutation(
                at: parentURL,
                expandedDirectories: expandedDirectories
            )
        }

        guard let directoryItem = fileItem(at: normalizedDirectoryURL),
              directoryItem.isDirectory else {
            return false
        }

        // Always re-diff the affected directory, even if it wasn't previously loaded.
        // Without this, moving a file INTO a collapsed folder silently drops the event,
        // and the user sees stale contents when they later expand that folder. This is
        // the "files don't show up until I close/reopen the sidebar" bug.
        directoryItem.children = loadChildren(
            of: normalizedDirectoryURL,
            expandedDirectories: expandedDirectories
        )
        directoryItem.isLoaded = true
        return true
    }

    func fileItem(at url: URL) -> FileItem? {
        let normalizedURL = url.standardizedFileURL

        func search(_ items: [FileItem]) -> FileItem? {
            for item in items {
                if item.url == normalizedURL {
                    return item
                }

                if let children = item.children,
                   let match = search(children) {
                    return match
                }
            }

            return nil
        }

        return search(rootItems)
    }

    // MARK: - Tree Accessors (stable public API — Phase 1 boundary seal)
    //
    // These are the only way callers outside FileService should read the tree.
    // Phase 2 swaps the nested-node backing store; these signatures stay stable,
    // so the sidebar view and AppState don't need to change again.

    /// Returns the children of a directory item, or nil if not a directory / not loaded.
    func children(of item: FileItem) -> [FileItem]? {
        item.children
    }

    /// Whether a directory item is currently expanded in the sidebar.
    func isExpanded(_ item: FileItem) -> Bool {
        item.isExpanded
    }

    private func removeExpandedDirectoryURLs(inSubtreeOf url: URL) {
        let normalizedURL = url.standardizedFileURL
        let pathPrefix = normalizedURL.path + "/"
        expandedDirectoryURLs = expandedDirectoryURLs.filter { existingURL in
            let normalizedExistingURL = existingURL.standardizedFileURL
            return normalizedExistingURL != normalizedURL
                && !normalizedExistingURL.path.hasPrefix(pathPrefix)
        }
    }

    private func rewriteExpandedDirectoryURLs(movingFrom sourceURL: URL, to destinationURL: URL) {
        let normalizedSourceURL = sourceURL.standardizedFileURL
        let normalizedDestinationURL = destinationURL.standardizedFileURL
        let sourcePath = normalizedSourceURL.path
        let sourcePrefix = sourcePath + "/"

        expandedDirectoryURLs = Set(expandedDirectoryURLs.map { existingURL in
            let normalizedExistingURL = existingURL.standardizedFileURL
            let existingPath = normalizedExistingURL.path

            if normalizedExistingURL == normalizedSourceURL {
                return normalizedDestinationURL
            }

            guard existingPath.hasPrefix(sourcePrefix) else {
                return normalizedExistingURL
            }

            let suffix = String(existingPath.dropFirst(sourcePath.count))
            return URL(fileURLWithPath: normalizedDestinationURL.path + suffix).standardizedFileURL
        })
    }

    private func markTreeDidChange() {
        treeChangeToken = UUID()
    }
}

// MARK: - File Content

enum FileContent {
    case text(String, String)       // content, extension
    case markwhen(String, URL)      // content, url
    case excalidraw(String, URL)    // content, url
    case image(URL)
    case video(URL)
    case audio(URL)
    case pdf(URL)
    case binary(URL)
    case empty
}
