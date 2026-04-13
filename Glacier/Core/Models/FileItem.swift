// FileItem.swift
// Domain model representing a file or folder in the explorer.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Item

final class FileItem: Identifiable, ObservableObject, Hashable, @unchecked Sendable {
    let id: UUID
    let url: URL
    let isDirectory: Bool
    let name: String
    let fileExtension: String?

    @Published var isExpanded: Bool = false
    @Published var children: [FileItem]?

    var isLoaded: Bool = false

    init(url: URL, isDirectory: Bool) {
        self.id = UUID()
        self.url = url
        self.isDirectory = isDirectory
        self.name = url.lastPathComponent
        self.fileExtension = isDirectory ? nil : url.pathExtension.lowercased().nonEmpty
    }

    var icon: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        return FileTypeRegistry.icon(for: fileExtension)
    }

    var iconColor: Color {
        if isDirectory { return .accentColor }
        return FileTypeRegistry.color(for: fileExtension)
    }

    var displayKind: FileKind {
        if isDirectory { return .folder }
        return FileTypeRegistry.kind(for: fileExtension)
    }

    // MARK: - Hashable / Equatable

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - File Kind

enum FileKind: String, CaseIterable {
    case folder
    case text
    case markdown
    case code
    case json
    case image
    case video
    case audio
    case pdf
    case binary
    case unknown
}

// MARK: - String Helper

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
