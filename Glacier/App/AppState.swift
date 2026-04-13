// AppState.swift
// Central observable state for the entire application.

import SwiftUI
import Combine

// MARK: - Tab Kind

enum TabKind: Equatable {
    case file(FileItem)
    case terminal(TerminalSession)

    static func == (lhs: TabKind, rhs: TabKind) -> Bool {
        switch (lhs, rhs) {
        case (.file(let a), .file(let b)): return a.id == b.id
        case (.terminal(let a), .terminal(let b)): return a.id == b.id
        default: return false
        }
    }
}

// MARK: - Tab

struct Tab: Identifiable, Equatable {
    let id: UUID
    let kind: TabKind
    var isModified: Bool = false

    init(file: FileItem) {
        self.id = UUID()
        self.kind = .file(file)
    }

    init(terminal: TerminalSession) {
        self.id = UUID()
        self.kind = .terminal(terminal)
    }

    var title: String {
        switch kind {
        case .file(let item): return item.name
        case .terminal(let session): return session.title
        }
    }

    var icon: String {
        switch kind {
        case .file(let item): return item.icon
        case .terminal: return "terminal"
        }
    }

    var iconColor: Color {
        switch kind {
        case .file(let item): return item.iconColor
        case .terminal: return .green
        }
    }

    static func == (lhs: Tab, rhs: Tab) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class AppState: ObservableObject {

    // MARK: - Services

    let fileService = FileService()

    // MARK: - Init

    init() {
        // Test hook: open a folder passed via environment variable at launch
        if let path = ProcessInfo.processInfo.environment["GLACIER_OPEN_FOLDER"] {
            Task { @MainActor in
                self.fileService.openFolder(at: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Explorer State

    @Published var isSidebarVisible: Bool = true
    @Published var selectedFileItem: FileItem?

    // MARK: - Font Size

    @Published var editorFontSize: CGFloat = 13

    // MARK: - Tabs

    @Published var tabs: [Tab] = []
    @Published var activeTabID: UUID?

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    // MARK: - Open File

    func openFile(_ item: FileItem) {
        // If already open, just activate
        if let existing = tabs.first(where: {
            if case .file(let f) = $0.kind { return f.url == item.url }
            return false
        }) {
            activeTabID = existing.id
            return
        }
        let tab = Tab(file: item)
        tabs.append(tab)
        activeTabID = tab.id
    }

    // MARK: - Open Terminal

    func openNewTerminal(workingDirectory: URL? = nil) {
        let dir = workingDirectory ?? fileService.rootURL ?? URL(fileURLWithPath: NSHomeDirectory())
        let session = TerminalSession(workingDirectory: dir)
        let tab = Tab(terminal: session)
        tabs.append(tab)
        activeTabID = tab.id
    }

    // MARK: - Close Tab

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: idx)
        if !tabs.isEmpty {
            let newIdx = min(idx, tabs.count - 1)
            activeTabID = tabs[newIdx].id
        } else {
            activeTabID = nil
        }
    }

    func activateTab(id: UUID) {
        activeTabID = id
    }

    // MARK: - Terminal Font Size

    private let defaultFontSize: CGFloat = 13

    func adjustFontSize(by delta: CGFloat) {
        guard let tab = activeTab else { return }
        switch tab.kind {
        case .terminal(let session):
            session.fontSize = max(8, min(36, session.fontSize + delta))
        case .file:
            editorFontSize = max(8, min(36, editorFontSize + delta))
        }
    }

    func resetFontSize() {
        guard let tab = activeTab else { return }
        switch tab.kind {
        case .terminal(let session):
            session.fontSize = defaultFontSize
        case .file:
            editorFontSize = defaultFontSize
        }
    }

    // MARK: - Rename Terminal

    func renameTerminal(_ session: TerminalSession, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
    }
}

// MARK: - Terminal Session
// Definition lives in TerminalSession.swift to isolate the SwiftTerm import.
