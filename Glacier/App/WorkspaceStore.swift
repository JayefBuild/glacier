// WorkspaceStore.swift
// Persists recent and active workspaces to UserDefaults.

import Foundation
import Combine
import AppKit

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

    private var pendingOpenURLs: [URL] = []
    private var activeWorkspaceURLsByWindowID: [UUID: URL] = [:]
    private var activeWorkspaceWindowOrder: [UUID] = []
    private var didRestoreOpenWorkspacesOnLaunch = false
    private var isApplicationTerminating = false
    private var willTerminateObserver: NSObjectProtocol?

    private let recentsKey = "glacier.recentWorkspaces"
    private let activeWorkspacesKey = "glacier.activeWorkspaces"
    private let restoreOpenWorkspacesEnabledKey = "glacier.restoreOpenWorkspacesOnLaunch"
    private let maxRecents = 10

    private init() {
        load()
        observeApplicationTermination()
    }

    // MARK: - Add

    func add(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        // Remove existing entry for same URL, then prepend
        recents.removeAll { $0.url == normalizedURL }
        recents.insert(Workspace(url: normalizedURL), at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        save()
    }

    // MARK: - Active Workspaces

    func setActiveWorkspace(_ url: URL?, for windowID: UUID) {
        let normalizedURL = url?.standardizedFileURL

        if activeWorkspaceURLsByWindowID[windowID] == normalizedURL {
            return
        }

        if let normalizedURL {
            activeWorkspaceURLsByWindowID[windowID] = normalizedURL
            if !activeWorkspaceWindowOrder.contains(windowID) {
                activeWorkspaceWindowOrder.append(windowID)
            }
        } else {
            activeWorkspaceURLsByWindowID.removeValue(forKey: windowID)
            activeWorkspaceWindowOrder.removeAll { $0 == windowID }
        }

        saveActiveWorkspaces()
    }

    func unregisterWindow(_ windowID: UUID) {
        guard !isApplicationTerminating else { return }
        setActiveWorkspace(nil, for: windowID)
    }

    var applicationTerminationInProgress: Bool {
        isApplicationTerminating
    }

    func markApplicationTerminating() {
        isApplicationTerminating = true
    }

    func restoreOpenWorkspacesIfNeeded(using appState: AppState) {
        guard !didRestoreOpenWorkspacesOnLaunch else { return }
        didRestoreOpenWorkspacesOnLaunch = true
        guard shouldRestoreOpenWorkspacesOnLaunch else { return }

        let environment = ProcessInfo.processInfo.environment
        guard environment["GLACIER_OPEN_FILE"] == nil,
              environment["GLACIER_OPEN_FOLDER"] == nil,
              appState.fileService.rootURL == nil,
              pendingOpenURLs.isEmpty else {
            return
        }

        let urls = loadActiveWorkspaces()
        guard let firstURL = urls.first else { return }

        appState.fileService.openFolder(at: firstURL)

        let remainingURLs = Array(urls.dropFirst())
        guard !remainingURLs.isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.restoreRemainingWorkspacesAsTabs(remainingURLs)
        }
    }

    // MARK: - Window Queue

    func queuePendingOpenURL(_ url: URL) {
        pendingOpenURLs.append(url.standardizedFileURL)
    }

    func consumePendingOpenURL() -> URL? {
        guard !pendingOpenURLs.isEmpty else { return nil }
        return pendingOpenURLs.removeFirst()
    }

    // MARK: - Remove

    func remove(_ workspace: Workspace) {
        recents.removeAll { $0.id == workspace.id }
        save()
    }

    // MARK: - Persistence

    private func save() {
        let paths = recents.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: recentsKey)
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recents = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Workspace(url: $0) }
    }

    private func saveActiveWorkspaces() {
        var seenPaths = Set<String>()
        let paths = activeWorkspaceWindowOrder.compactMap { windowID -> String? in
            guard let url = activeWorkspaceURLsByWindowID[windowID] else { return nil }
            let path = url.path
            guard seenPaths.insert(path).inserted else { return nil }
            return path
        }
        UserDefaults.standard.set(paths, forKey: activeWorkspacesKey)
    }

    private func loadActiveWorkspaces() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: activeWorkspacesKey) ?? []
        return paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var shouldRestoreOpenWorkspacesOnLaunch: Bool {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["GLACIER_RESTORE_OPEN_WORKSPACES"] {
            switch override {
            case "1", "true", "TRUE", "yes", "YES":
                return true
            case "0", "false", "FALSE", "no", "NO":
                return false
            default:
                break
            }
        }

        return UserDefaults.standard.bool(forKey: restoreOpenWorkspacesEnabledKey)
    }

    private func restoreRemainingWorkspacesAsTabs(_ urls: [URL], attempt: Int = 0) {
        guard !urls.isEmpty else { return }

        guard let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            guard attempt < 5 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.restoreRemainingWorkspacesAsTabs(urls, attempt: attempt + 1)
            }
            return
        }

        for (index, url) in urls.enumerated() {
            let delay = 0.2 * Double(index + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak anchorWindow] in
                self?.openWorkspaceInNewTab(url, relativeTo: anchorWindow)
            }
        }
    }

    private func openWorkspaceInNewTab(_ url: URL, relativeTo anchorWindow: NSWindow?) {
        queuePendingOpenURL(url)
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: NSApp)

        guard let anchorWindow else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak anchorWindow] in
            guard let anchorWindow,
                  let newWindow = NSApp.windows.filter({ $0 !== anchorWindow && $0.isVisible }).last else {
                return
            }

            anchorWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func observeApplicationTermination() {
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isApplicationTerminating = true
            }
        }
    }
}
