// AppState.swift
// Central observable state for the entire application.

import SwiftUI
import Combine
import UniformTypeIdentifiers

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

enum EditorPane: String {
    case primary
    case secondary
}

enum EditorSplitOrientation {
    case sideBySide
    case topBottom
}

enum EditorSplitDropEdge {
    case left
    case right
    case top
    case bottom

    var orientation: EditorSplitOrientation {
        switch self {
        case .left, .right:
            return .sideBySide
        case .top, .bottom:
            return .topBottom
        }
    }

    var insertsBeforeAnchor: Bool {
        switch self {
        case .left, .top:
            return true
        case .right, .bottom:
            return false
        }
    }
}

struct DraggedTabReference: Transferable, Codable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .glacierTabReference)
    }
}

extension UTType {
    static let glacierTabReference = UTType(exportedAs: "com.glacier.tabreference")
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
        // Test hooks: allow UI tests to boot straight into a workspace or file.
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["GLACIER_OPEN_FILE"] {
            let fileURL = URL(fileURLWithPath: path)
            Task { @MainActor in
                self.fileService.openFolder(at: fileURL.deletingLastPathComponent())
                self.openFile(FileItem(url: fileURL, isDirectory: false))
            }
        } else if let path = environment["GLACIER_OPEN_FOLDER"] {
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
    @Published var primaryTabID: UUID?
    @Published var secondaryTabID: UUID?
    @Published var focusedPane: EditorPane = .primary
    @Published var splitOrientation: EditorSplitOrientation = .sideBySide

    var activeTab: Tab? {
        tab(with: activeTabID) ?? tab(with: tabID(for: focusedPane)) ?? primaryTab
    }

    var primaryTab: Tab? {
        tab(with: primaryTabID)
    }

    var secondaryTab: Tab? {
        tab(with: secondaryTabID)
    }

    var isSplitViewVisible: Bool {
        primaryTab != nil && secondaryTab != nil
    }

    // MARK: - Open File

    func openFile(_ item: FileItem) {
        // If already open, just activate
        if let existing = tabs.first(where: {
            if case .file(let f) = $0.kind { return f.url == item.url }
            return false
        }) {
            if let pane = pane(for: existing.id) {
                focusPane(pane)
            } else {
                showTab(id: existing.id, in: focusedPane)
            }
            return
        }
        let tab = Tab(file: item)
        tabs.append(tab)
        showTab(id: tab.id, in: focusedPane)
    }

    // MARK: - Open Terminal

    func openNewTerminal(workingDirectory: URL? = nil) {
        let dir = workingDirectory ?? fileService.rootURL ?? URL(fileURLWithPath: NSHomeDirectory())
        let session = TerminalSession(workingDirectory: dir)
        let tab = Tab(terminal: session)
        tabs.append(tab)
        showTab(id: tab.id, in: focusedPane)
    }

    // MARK: - Close Tab

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(of: tab) else { return }
        let wasPrimary = primaryTabID == tab.id
        let wasSecondary = secondaryTabID == tab.id

        tabs.remove(at: idx)

        if wasPrimary {
            primaryTabID = replacementTabID(afterRemovingIndex: idx, excluding: Set([secondaryTabID].compactMap { $0 }))
        }

        if wasSecondary {
            secondaryTabID = replacementTabID(afterRemovingIndex: idx, excluding: Set([primaryTabID].compactMap { $0 }))
        }

        normalizePaneAssignments()
    }

    func activateTab(id: UUID) {
        if let pane = pane(for: id) {
            focusPane(pane)
        } else {
            showTab(id: id, in: focusedPane)
        }
    }

    func focusPane(_ pane: EditorPane) {
        focusedPane = pane
        activeTabID = tabID(for: pane) ?? primaryTabID
    }

    func splitPane(with tabID: UUID, edge: EditorSplitDropEdge) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        guard let anchorID = self.tabID(for: focusedPane) ?? primaryTabID else {
            showTab(id: tabID, in: .primary)
            return
        }
        guard let companionID = splitCompanionID(for: tabID, preferredAnchor: anchorID) else {
            return
        }

        splitOrientation = edge.orientation

        if edge.insertsBeforeAnchor {
            primaryTabID = tabID
            secondaryTabID = companionID
        } else {
            primaryTabID = companionID
            secondaryTabID = tabID
        }

        normalizePaneAssignments()
        if let pane = self.pane(for: tabID) {
            focusPane(pane)
        }
    }

    func splitFile(at url: URL, edge: EditorSplitDropEdge) {
        guard !isDirectory(url) else { return }

        if let existingTab = tabs.first(where: {
            if case .file(let file) = $0.kind {
                return file.url == url
            }
            return false
        }) {
            splitPane(with: existingTab.id, edge: edge)
            return
        }

        let tab = Tab(file: FileItem(url: url, isDirectory: false))
        tabs.append(tab)
        splitPane(with: tab.id, edge: edge)
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

    func isTabVisible(_ id: UUID) -> Bool {
        pane(for: id) != nil
    }

    func pane(for id: UUID) -> EditorPane? {
        if primaryTabID == id { return .primary }
        if secondaryTabID == id { return .secondary }
        return nil
    }

    func otherPane(of pane: EditorPane) -> EditorPane {
        pane == .primary ? .secondary : .primary
    }

    // MARK: - Pane State

    private func showTab(id: UUID, in pane: EditorPane) {
        switch pane {
        case .primary:
            if secondaryTabID == id {
                secondaryTabID = primaryTabID
            }
            primaryTabID = id
        case .secondary:
            guard primaryTabID != nil else {
                primaryTabID = id
                break
            }
            if primaryTabID == id {
                primaryTabID = secondaryTabID
            }
            secondaryTabID = id
        }

        normalizePaneAssignments()
        if let pane = self.pane(for: id) {
            focusPane(pane)
        }
    }

    private func normalizePaneAssignments() {
        if primaryTabID != nil, tab(with: primaryTabID) == nil {
            primaryTabID = nil
        }

        if secondaryTabID != nil, tab(with: secondaryTabID) == nil {
            secondaryTabID = nil
        }

        if primaryTabID == nil {
            primaryTabID = secondaryTabID
            secondaryTabID = nil
        }

        if primaryTabID == secondaryTabID {
            secondaryTabID = nil
        }

        if primaryTabID == nil {
            activeTabID = nil
            focusedPane = .primary
            return
        }

        if secondaryTabID == nil, focusedPane == .secondary {
            focusedPane = .primary
        }

        if let activeTabID, let pane = pane(for: activeTabID) {
            focusedPane = pane
        } else {
            activeTabID = tabID(for: focusedPane) ?? primaryTabID
        }
    }

    private func tabID(for pane: EditorPane) -> UUID? {
        switch pane {
        case .primary: return primaryTabID
        case .secondary: return secondaryTabID
        }
    }

    private func splitCompanionID(for draggedTabID: UUID, preferredAnchor anchorID: UUID) -> UUID? {
        if anchorID != draggedTabID {
            return anchorID
        }

        let visibleTabIDs = [primaryTabID, secondaryTabID].compactMap { $0 }
        if let otherVisibleID = visibleTabIDs.first(where: { $0 != draggedTabID }) {
            return otherVisibleID
        }

        return tabs.map(\.id).first(where: { $0 != draggedTabID })
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    private func tab(with id: UUID?) -> Tab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    private func replacementTabID(afterRemovingIndex index: Int, excluding excluded: Set<UUID>) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let start = min(index, tabs.count - 1)

        for tab in tabs[start...] where !excluded.contains(tab.id) {
            return tab.id
        }

        if start > 0 {
            for tab in tabs[..<start].reversed() where !excluded.contains(tab.id) {
                return tab.id
            }
        }

        return nil
    }
}

func splitPreviewEdge(for location: CGPoint, in size: CGSize) -> EditorSplitDropEdge? {
    guard size.width > 0, size.height > 0 else { return nil }

    let horizontalThreshold = min(max(size.width * 0.22, 140), 220)
    let verticalThreshold = min(max(size.height * 0.22, 110), 180)

    let candidates: [(EditorSplitDropEdge, CGFloat)] = [
        (.left, location.x / horizontalThreshold),
        (.right, (size.width - location.x) / horizontalThreshold),
        (.top, location.y / verticalThreshold),
        (.bottom, (size.height - location.y) / verticalThreshold)
    ]

    guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 <= 1 else {
        return nil
    }

    return best.0
}

// MARK: - Terminal Session
// Definition lives in TerminalSession.swift to isolate the SwiftTerm import.
