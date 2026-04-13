// WorkspaceStore.swift
// Persists recently opened folder workspaces to UserDefaults.

import Foundation
import Combine

struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var recents: [Workspace] = []

    /// Set before opening a new window tab so the new window can pick it up on appear.
    var pendingOpenURL: URL? = nil

    private let key = "glacier.recentWorkspaces"
    private let maxRecents = 10

    private init() {
        load()
    }

    // MARK: - Add

    func add(_ url: URL) {
        // Remove existing entry for same URL, then prepend
        recents.removeAll { $0.url == url }
        recents.insert(Workspace(url: url), at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        save()
    }

    // MARK: - Remove

    func remove(_ workspace: Workspace) {
        recents.removeAll { $0.id == workspace.id }
        save()
    }

    // MARK: - Persistence

    private func save() {
        let paths = recents.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: key)
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        recents = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Workspace(url: $0) }
    }
}
