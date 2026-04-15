// FileService.swift
// Handles all file system operations: loading, reading, watching.

import Foundation
import Combine

@MainActor
final class FileService: ObservableObject {

    // MARK: - State

    @Published var rootItems: [FileItem] = []
    @Published var rootURL: URL?
    @Published var isLoading: Bool = false

    // MARK: - Open Folder

    func openFolder(at url: URL) {
        rootURL = url
        rootItems = []
        isLoading = true
        WorkspaceStore.shared.add(url)
        Task.detached(priority: .userInitiated) {
            let items = self.loadChildren(of: url)
            await MainActor.run {
                self.rootItems = items
                self.isLoading = false
            }
        }
    }

    // MARK: - Load Children

    nonisolated func loadChildren(of url: URL) -> [FileItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .nameKey],
            options: []
        ) else { return [] }

        return contents
            .compactMap { childURL -> FileItem? in
                let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileItem(url: childURL, isDirectory: isDirectory)
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
            return
        }
        if item.isLoaded {
            item.isExpanded = true
            return
        }
        // Load off the main thread, then update on main
        Task.detached(priority: .userInitiated) {
            let children = self.loadChildren(of: item.url)
            await MainActor.run {
                item.children = children
                item.isLoaded = true
                item.isExpanded = true
            }
        }
    }

    // MARK: - Create File

    func createFile(named name: String, in directory: URL) throws -> URL {
        let dest = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        return dest
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
        if let rootURL { openFolder(at: rootURL) }
    }

    // MARK: - Trash

    func trash(item: FileItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        // Reload
        if let rootURL { openFolder(at: rootURL) }
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
    }

    // MARK: - Move

    func move(from sourceURL: URL, into destinationDirectory: URL) throws {
        // Don't move into itself or a child of itself
        guard !destinationDirectory.path.hasPrefix(sourceURL.path + "/"),
              sourceURL != destinationDirectory else { return }

        let dest = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        guard dest != sourceURL else { return }

        try FileManager.default.moveItem(at: sourceURL, to: dest)
        if let rootURL { openFolder(at: rootURL) }
    }

    // MARK: - Reload

    func reload() {
        if let rootURL { openFolder(at: rootURL) }
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
