// AppState.swift
// Central observable state for the entire application.

import SwiftUI
import Combine
import UniformTypeIdentifiers

let focusDebugLoggingEnabled = ProcessInfo.processInfo.environment["GLACIER_DEBUG_FOCUS"] == "1"
let focusDebugLogPath = ProcessInfo.processInfo.environment["GLACIER_DEBUG_FOCUS_LOG"]

@MainActor
func focusDebugLog(_ message: String) {
    guard focusDebugLoggingEnabled else { return }

    if let focusDebugLogPath {
        let url = URL(fileURLWithPath: focusDebugLogPath)
        let data = Data("\(message)\n".utf8)

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Tab Kind

enum TabKind: Equatable {
    case file(FileItem)
    case terminal(TerminalTabState)
    case gitGraph

    static func == (lhs: TabKind, rhs: TabKind) -> Bool {
        switch (lhs, rhs) {
        case (.file(let a), .file(let b)): return a.id == b.id
        case (.terminal(let a), .terminal(let b)): return a.id == b.id
        case (.gitGraph, .gitGraph): return true
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

    init(terminal: TerminalTabState) {
        self.id = UUID()
        self.kind = .terminal(terminal)
    }

    init(gitGraph _: Void = ()) {
        self.id = UUID()
        self.kind = .gitGraph
    }

    @MainActor
    var title: String {
        switch kind {
        case .file(let item): return item.name
        case .terminal(let terminal): return terminal.title
        case .gitGraph: return "Git Graph"
        }
    }

    var icon: String {
        switch kind {
        case .file(let item): return item.icon
        case .terminal: return "terminal"
        case .gitGraph: return "point.3.connected.trianglepath.dotted"
        }
    }

    var iconColor: Color {
        switch kind {
        case .file(let item): return item.iconColor
        case .terminal: return .green
        case .gitGraph: return .accentColor
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

    @Published var editorFontSize: CGFloat = 15

    // MARK: - Tabs

    @Published var tabs: [Tab] = []
    @Published var activeTabID: UUID?
    @Published var primaryTabID: UUID?
    @Published var secondaryTabID: UUID?
    @Published private var tabPaneAffinities: [UUID: EditorPane] = [:]
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

    var canSplitFocusedPane: Bool {
        isSplitViewVisible || tabs.count > 1
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
        let terminal = TerminalTabState(workingDirectory: dir, fontSize: defaultTerminalFontSize)
        let tab = Tab(terminal: terminal)
        tabs.append(tab)
        showTab(id: tab.id, in: focusedPane)
    }

    func openGitGraph() {
        if let existing = tabs.first(where: {
            if case .gitGraph = $0.kind { return true }
            return false
        }) {
            if let pane = pane(for: existing.id) {
                focusPane(pane)
            } else {
                showTab(id: existing.id, in: focusedPane)
            }
            return
        }

        let tab = Tab(gitGraph: ())
        tabs.append(tab)
        showTab(id: tab.id, in: focusedPane)
    }

    // MARK: - Close Tab

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(of: tab) else { return }
        let wasPrimary = primaryTabID == tab.id
        let wasSecondary = secondaryTabID == tab.id

        if case .terminal(let terminal) = tab.kind {
            for sessionID in terminal.allSessionIDs {
                TerminalViewCache.shared.remove(sessionID)
            }
        }

        tabs.remove(at: idx)
        tabPaneAffinities.removeValue(forKey: tab.id)

        if wasPrimary {
            primaryTabID = replacementTabID(
                afterRemovingIndex: idx,
                replacing: .primary,
                excluding: Set([secondaryTabID].compactMap { $0 })
            )
        }

        if wasSecondary {
            secondaryTabID = replacementTabID(
                afterRemovingIndex: idx,
                replacing: .secondary,
                excluding: Set([primaryTabID].compactMap { $0 })
            )
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

    func activateTab(id: UUID, in pane: EditorPane) {
        if tabID(for: pane) == id {
            focusPane(pane)
        } else {
            showTab(id: id, in: pane)
        }
    }

    func closeOtherTabs(keeping id: UUID, in pane: EditorPane? = nil) {
        let tabsToClose: [Tab]
        if let pane, isSplitViewVisible {
            tabsToClose = tabs(for: pane).filter { $0.id != id }
        } else {
            tabsToClose = tabs.filter { $0.id != id }
        }

        tabsToClose.forEach { closeTab($0) }
    }

    func focusTerminalSession(_ sessionID: UUID, in pane: EditorPane) {
        guard let terminal = visibleTerminalTab(in: pane) else {
            focusPane(pane)
            return
        }

        terminal.focusSession(sessionID)
        focusPane(pane)
    }

    func handleTerminalCommand(_ command: TerminalShortcutCommand, sessionID: UUID, in pane: EditorPane) {
        guard let terminal = visibleTerminalTab(in: pane) else {
            if command == .newTerminalTab {
                openNewTerminal()
            }
            return
        }

        terminal.focusSession(sessionID)

        switch command {
        case .newTerminalTab:
            focusPane(pane)
            let workingDirectory = terminal.session(for: sessionID)?.workingDirectory
            openNewTerminal(workingDirectory: workingDirectory)
        case .closeTerminal:
            closeTerminalSession(sessionID, in: pane)
        case .splitTerminalVertical:
            splitTerminalSession(sessionID, in: pane, orientation: .vertical)
        case .splitTerminalHorizontal:
            splitTerminalSession(sessionID, in: pane, orientation: .horizontal)
        case .splitEditorRight:
            focusPane(pane)
            splitFocusedPaneRight()
        case .splitEditorDown:
            focusPane(pane)
            splitFocusedPaneDown()
        case .closeEditorSplit:
            focusPane(pane)
            closeSplit()
        }
    }

    func focusPane(_ pane: EditorPane) {
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus focusPane pane=\(pane.rawValue)")
        }
        focusedPane = pane
        activeTabID = tabID(for: pane) ?? primaryTabID
        restoreTerminalFocusForVisibleTab(in: pane)
    }

    func splitFocusedPaneRight() {
        splitFocusedPane(edge: .right)
    }

    func splitFocusedPaneDown() {
        splitFocusedPane(edge: .bottom)
    }

    func closeSplit() {
        guard isSplitViewVisible else { return }

        switch focusedPane {
        case .primary:
            secondaryTabID = nil
        case .secondary:
            primaryTabID = secondaryTabID
            secondaryTabID = nil
        }

        normalizePaneAssignments()
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

    private let defaultEditorFontSize: CGFloat = 15
    private var defaultTerminalFontSize: CGFloat {
        TerminalAppearance.current.defaultFontSize ?? defaultEditorFontSize
    }

    func adjustFontSize(by delta: CGFloat) {
        guard let tab = activeTab else { return }
        switch tab.kind {
        case .terminal(let terminal):
            terminal.adjustFontSize(by: delta)
        case .file:
            editorFontSize = max(8, min(36, editorFontSize + delta))
        case .gitGraph:
            break
        }
    }

    func resetFontSize() {
        guard let tab = activeTab else { return }
        switch tab.kind {
        case .terminal(let terminal):
            terminal.resetFontSize(to: defaultTerminalFontSize)
        case .file:
            editorFontSize = defaultEditorFontSize
        case .gitGraph:
            break
        }
    }

    // MARK: - Rename Terminal

    func renameTerminal(_ terminal: TerminalTabState, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        objectWillChange.send()
        terminal.title = trimmed
    }

    func isTabVisible(_ id: UUID) -> Bool {
        pane(for: id) != nil
    }

    func paneAssignment(for id: UUID) -> EditorPane {
        pane(for: id) ?? tabPaneAffinities[id] ?? .primary
    }

    func tabs(for pane: EditorPane) -> [Tab] {
        guard isSplitViewVisible else { return tabs }
        return tabs.filter { paneAssignment(for: $0.id) == pane }
    }

    func visibleTabID(for pane: EditorPane) -> UUID? {
        tabID(for: pane)
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

        syncVisibleTabPaneAffinities()

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

    private func visibleTerminalTab(in pane: EditorPane) -> TerminalTabState? {
        guard let tab = tab(with: tabID(for: pane)) else { return nil }
        guard case .terminal(let terminal) = tab.kind else { return nil }
        return terminal
    }

    private func restoreTerminalFocusForVisibleTab(in pane: EditorPane) {
        guard let terminal = visibleTerminalTab(in: pane) else { return }
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus restore pane=\(pane.rawValue) session=\(terminal.focusedSessionID.uuidString)")
        }
        TerminalViewCache.shared.focus(terminal.focusedSessionID)
    }

    private func syncVisibleTabPaneAffinities() {
        if let primaryTabID {
            tabPaneAffinities[primaryTabID] = .primary
        }

        if let secondaryTabID {
            tabPaneAffinities[secondaryTabID] = .secondary
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

    private func splitFocusedPane(edge: EditorSplitDropEdge) {
        if isSplitViewVisible {
            splitOrientation = edge.orientation
            return
        }

        guard let anchorID = tabID(for: focusedPane) ?? activeTabID ?? primaryTabID else {
            return
        }

        guard let splitTabID = nextTabIDForSplit(excluding: anchorID) else {
            return
        }

        splitPane(with: splitTabID, edge: edge)
    }

    private func nextTabIDForSplit(excluding anchorID: UUID) -> UUID? {
        let candidateIDs = tabs.map(\.id).filter { $0 != anchorID }
        return candidateIDs.first(where: { pane(for: $0) == nil }) ?? candidateIDs.first
    }

    private func splitTerminalSession(
        _ sessionID: UUID,
        in pane: EditorPane,
        orientation: TerminalTabSplitOrientation
    ) {
        guard let terminal = visibleTerminalTab(in: pane) else { return }
        terminal.focusSession(sessionID)
        guard terminal.splitFocusedSession(orientation) != nil else { return }
        focusPane(pane)
    }

    private func closeTerminalSession(_ sessionID: UUID, in pane: EditorPane) {
        guard let tab = tab(with: tabID(for: pane)),
              case .terminal(let terminal) = tab.kind else {
            return
        }

        terminal.focusSession(sessionID)
        guard let closeResult = terminal.closeFocusedSession() else { return }

        TerminalViewCache.shared.remove(closeResult.removedSessionID)

        if closeResult.shouldCloseTab {
            closeTab(tab)
            return
        }

        focusPane(pane)
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

    private func replacementTabID(afterRemovingIndex index: Int, replacing pane: EditorPane, excluding excluded: Set<UUID>) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let start = min(index, tabs.count - 1)

        for tab in tabs[start...] where !excluded.contains(tab.id) && paneAssignment(for: tab.id) == pane {
            return tab.id
        }

        if start > 0 {
            for tab in tabs[..<start].reversed() where !excluded.contains(tab.id) && paneAssignment(for: tab.id) == pane {
                return tab.id
            }
        }

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
