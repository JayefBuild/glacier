// FileService.swift
// Handles all file system operations: loading, reading, watching.

import Foundation
import Combine
import Darwin

@MainActor
final class FileService: ObservableObject {

    // MARK: - State

    @Published var rootItems: [FileItem] = []
    @Published var rootURL: URL?
    @Published var isLoading: Bool = false

    private var expandedDirectoryURLs: Set<URL> = []
    private var directoryMonitors: [URL: DirectoryMonitor] = [:]
    private var pendingReloadWorkItem: DispatchWorkItem?

    // MARK: - Open Folder

    func openFolder(at url: URL) {
        let normalizedURL = url.standardizedFileURL
        let isSameRoot = rootURL?.standardizedFileURL == normalizedURL

        rootURL = normalizedURL
        if !isSameRoot {
            rootItems = []
            expandedDirectoryURLs = []
            replaceDirectoryMonitors(with: [])
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
                self.synchronizeDirectoryMonitors()
            }
        }
    }

    func closeFolder() {
        rootURL = nil
        rootItems = []
        expandedDirectoryURLs = []
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        replaceDirectoryMonitors(with: [])
    }

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
            synchronizeDirectoryMonitors()
            return
        }

        expandedDirectoryURLs.insert(item.url)
        if item.isLoaded {
            item.isExpanded = true
            if let children = item.children {
                restoreExpandedDirectories(in: children)
            }
            synchronizeDirectoryMonitors()
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
                self.synchronizeDirectoryMonitors()
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
        return dest
    }

    // MARK: - Rename

    func rename(item: FileItem, to newName: String) throws {
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: item.url, to: dest)
        // Reload the parent directory
        reload()
    }

    // MARK: - Trash

    func trash(item: FileItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        // Reload
        expandedDirectoryURLs.remove(item.url)
        reload()
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
        synchronizeDirectoryMonitors()
    }

    // MARK: - Move

    func move(from sourceURL: URL, into destinationDirectory: URL) throws {
        // Don't move into itself or a child of itself
        guard !destinationDirectory.path.hasPrefix(sourceURL.path + "/"),
              sourceURL != destinationDirectory else { return }

        let dest = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        guard dest != sourceURL else { return }

        try FileManager.default.moveItem(at: sourceURL, to: dest)
        reload()
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
        let kind = FileTypeRegistry.kind(for: url.pathExtension.lowercased())

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
            // Attempt to read as text
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return .text(text, url.pathExtension.lowercased())
            } else if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
                return .text(text, url.pathExtension.lowercased())
            } else {
                return .binary(url)
            }
        }
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

    private func synchronizeDirectoryMonitors() {
        guard let rootURL else {
            replaceDirectoryMonitors(with: [])
            return
        }

        var urls = Set(expandedDirectoryURLs.filter { directoryExists(at: $0) })
        urls.insert(rootURL)
        replaceDirectoryMonitors(with: Array(urls))
    }

    private func replaceDirectoryMonitors(with urls: [URL]) {
        let normalizedURLs = Set(urls.map(\.standardizedFileURL))
        directoryMonitors = directoryMonitors.filter { normalizedURLs.contains($0.key) }

        for url in normalizedURLs where directoryMonitors[url] == nil {
            if let monitor = DirectoryMonitor(url: url, onChange: { [weak self] in
                Task { @MainActor in
                    self?.scheduleReload()
                }
            }) {
                directoryMonitors[url] = monitor
            }
        }
    }

    private func scheduleReload() {
        pendingReloadWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        pendingReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }
}

private final class DirectoryMonitor {
    private let fileDescriptor: CInt
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        fileDescriptor = Darwin.open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return nil
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [fileDescriptor] in
            Darwin.close(fileDescriptor)
        }
        source.resume()
    }

    deinit {
        source.cancel()
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
