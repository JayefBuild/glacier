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

struct EditorSaveRequest {
    let pane: EditorPane
    let url: URL
}

extension Notification.Name {
    static let glacierSaveDocument = Notification.Name("GlacierSaveDocument")
    static let glacierFocusExplorerResponder = Notification.Name("GlacierFocusExplorerResponder")
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
    let windowID = UUID()
    private var cancellables = Set<AnyCancellable>()
    private var lastRegisteredWorkspaceURL: URL?

    // MARK: - Init

    init() {
        AppStateRegistry.shared.register(self)
        focusDebugLog("GlacierFocus appStateInit")
        observeFileTreeChanges()
        observeWorkspaceChanges()

        // Test hooks: allow UI tests to boot straight into a workspace or file.
        let environment = ProcessInfo.processInfo.environment
        guard shouldHonorLaunchEnvironment(environment) else {
            return
        }

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

    private func shouldHonorLaunchEnvironment(_ environment: [String: String]) -> Bool {
        if environment["GLACIER_ENABLE_TEST_HOOKS"] == "1" {
            return true
        }

        return environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Explorer State

    @Published var isSidebarVisible: Bool = true
    @Published private(set) var isExplorerFocused: Bool = false
    @Published var selectedFileItem: FileItem?
    @Published private(set) var selectedFileURLs: Set<URL> = []
    @Published private var primaryPreviewFileItem: FileItem?
    @Published private var secondaryPreviewFileItem: FileItem?
    @Published private(set) var pendingTrashItem: FileItem?
    private var explorerSelectionAnchorURL: URL?

    // MARK: - Font Size

    @Published var editorFontSize: CGFloat = 15
    @Published var sidebarFontSize: CGFloat = 14

    var sidebarCaptionFontSize: CGFloat {
        max(10, sidebarFontSize - 1)
    }

    var sidebarLabelFontSize: CGFloat {
        sidebarFontSize + 1
    }

    var sidebarMetadataFontSize: CGFloat {
        max(9, sidebarFontSize - 4)
    }

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

    var canSaveFocusedDocument: Bool {
        visibleFileItem(in: focusedPane) != nil
    }

    var canTrashSelectedExplorerItem: Bool {
        selectedExplorerTargetURL != nil
    }

    var focusedVisibleFileURL: URL? {
        visibleFileItem(in: focusedPane)?.url
    }

    // MARK: - Open File

    func openFile(_ item: FileItem) {
        clearPreview(in: focusedPane)

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

    // MARK: - Explorer Selection

    func isExplorerItemSelected(_ item: FileItem) -> Bool {
        if selectedFileURLs.count > 1 {
            return selectedFileURLs.contains(item.url)
        }

        guard let selectedURL = selectedExplorerTargetURL else {
            return false
        }

        if selectedURL == item.url {
            return true
        }

        guard item.isDirectory, !item.isExpanded else {
            return false
        }

        let folderPath = item.url.standardizedFileURL.path
        let selectedPath = selectedURL.standardizedFileURL.path
        return selectedPath.hasPrefix(folderPath + "/")
    }

    func selectExplorerItem(_ item: FileItem, extendingRange: Bool = false) {
        if extendingRange {
            selectExplorerRange(to: item)
            return
        }

        selectExplorerURL(item.url)
    }

    func selectExplorerURL(_ url: URL, anchorURL: URL? = nil) {
        let normalizedURL = url.standardizedFileURL
        selectedFileItem = fileItem(at: normalizedURL)
        selectedFileURLs = [normalizedURL]
        explorerSelectionAnchorURL = anchorURL ?? normalizedURL
    }

    func shouldPreserveVisibleFileSelectionWhenTogglingFolder(_ item: FileItem) -> Bool {
        guard item.isDirectory else {
            return false
        }

        guard selectedFileURLs.count <= 1,
              let selectedURL = selectedExplorerTargetURL,
              let visibleURL = focusedVisibleFileURL,
              selectedURL == visibleURL,
              selectedURL != item.url else {
            return false
        }

        let folderPath = item.url.standardizedFileURL.path
        let selectedPath = selectedURL.standardizedFileURL.path
        return selectedPath.hasPrefix(folderPath + "/")
    }

    func clearExplorerSelection() {
        selectedFileItem = nil
        selectedFileURLs = []
        explorerSelectionAnchorURL = nil
    }

    func focusExplorer() {
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus focusExplorer")
        }
        isExplorerFocused = true
        NotificationCenter.default.post(name: .glacierFocusExplorerResponder, object: nil)
    }

    @discardableResult
    func moveExplorerSelection(by offset: Int) -> Bool {
        guard offset != 0 else {
            return false
        }

        let visibleItems = fileService.visibleItems()
        guard !visibleItems.isEmpty else {
            return false
        }

        let fallbackIndex = offset > 0 ? -1 : visibleItems.count
        let currentIndex = selectedVisibleExplorerIndex(in: visibleItems) ?? fallbackIndex
        let targetIndex = min(max(currentIndex + offset, 0), visibleItems.count - 1)

        guard targetIndex != currentIndex else {
            return false
        }

        let item = visibleItems[targetIndex]
        selectExplorerItem(item)
        if !item.isDirectory {
            previewFile(item)
        }
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus moveExplorerSelection offset=\(offset) target=\(item.url.path)")
        }
        return true
    }

    @discardableResult
    func expandSelectedExplorerItem() -> Bool {
        let visibleItems = fileService.visibleItems()
        guard let item = selectedVisibleExplorerItem(in: visibleItems),
              item.isDirectory else {
            return false
        }

        if !item.isExpanded {
            fileService.toggleExpansion(of: item)
            if focusDebugLoggingEnabled {
                focusDebugLog("GlacierFocus expandExplorerItem toggle=\(item.url.path)")
            }
            return true
        }

        guard let firstChild = item.children?.first else {
            return false
        }

        selectExplorerItem(firstChild)
        if !firstChild.isDirectory {
            previewFile(firstChild)
        }
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus expandExplorerItem child=\(firstChild.url.path)")
        }
        return true
    }

    @discardableResult
    func collapseSelectedExplorerItem() -> Bool {
        let visibleItems = fileService.visibleItems()
        guard let item = selectedVisibleExplorerItem(in: visibleItems) else {
            return false
        }

        if item.isDirectory, item.isExpanded {
            fileService.toggleExpansion(of: item)
            if focusDebugLoggingEnabled {
                focusDebugLog("GlacierFocus collapseExplorerItem toggle=\(item.url.path)")
            }
            return true
        }

        guard let parentItem = parentExplorerItem(for: item) else {
            return false
        }

        selectExplorerItem(parentItem)
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus collapseExplorerItem parent=\(parentItem.url.path)")
        }
        return true
    }

    private func selectExplorerRange(to item: FileItem) {
        let visibleItems = fileService.visibleItems()
        let anchorURL = explorerSelectionAnchorURL ?? selectedFileItem?.url ?? item.url

        guard let anchorIndex = visibleItems.firstIndex(where: { $0.url == anchorURL }),
              let targetIndex = visibleItems.firstIndex(where: { $0.url == item.url }) else {
            selectExplorerItem(item)
            return
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)

        selectedFileItem = item
        selectedFileURLs = Set(visibleItems[lowerBound...upperBound].map(\.url))
        if explorerSelectionAnchorURL == nil {
            explorerSelectionAnchorURL = anchorURL
        }
    }

    func previewedFileItem(in pane: EditorPane) -> FileItem? {
        switch pane {
        case .primary:
            return primaryPreviewFileItem
        case .secondary:
            return secondaryPreviewFileItem
        }
    }

    func previewFile(_ item: FileItem, in pane: EditorPane? = nil) {
        let targetPane = pane ?? focusedPane
        setPreviewFileItem(item, in: targetPane)
    }

    func clearPreview(in pane: EditorPane) {
        setPreviewFileItem(nil, in: pane)
    }

    func hasPreview(in pane: EditorPane) -> Bool {
        previewedFileItem(in: pane) != nil
    }

    func requestSaveForFocusedPane() {
        guard let item = visibleFileItem(in: focusedPane) else { return }
        NotificationCenter.default.post(
            name: .glacierSaveDocument,
            object: EditorSaveRequest(pane: focusedPane, url: item.url)
        )
    }

    func moveSelectedExplorerItemToTrash() {
        guard let item = selectedExplorerTargetItem() else { return }
        requestTrashConfirmation(for: item)
    }

    func requestTrashConfirmation(for item: FileItem) {
        pendingTrashItem = item
    }

    func cancelTrashConfirmation() {
        pendingTrashItem = nil
    }

    func confirmPendingTrash() {
        guard let pendingTrashItem else { return }
        try? fileService.trash(item: pendingTrashItem)
        clearExplorerSelection()
        self.pendingTrashItem = nil
    }

    func handleWindowWillClose() {
        WorkspaceStore.shared.unregisterWindow(windowID)
    }

    var openTerminalSessionCount: Int {
        tabs.reduce(into: 0) { count, tab in
            guard case .terminal(let terminal) = tab.kind else { return }
            count += terminal.sessionCount
        }
    }

    func confirmProjectCloseIfNeeded() -> Bool {
        confirmProtectedClose(.project, processCount: openTerminalSessionCount)
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

    func closeTab(_ tab: Tab, bypassingConfirmation: Bool = false) {
        guard bypassingConfirmation || confirmTabCloseIfNeeded(tab) else { return }
        performCloseTab(tab)
    }

    private func performCloseTab(_ tab: Tab) {
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
            clearPreview(in: pane)
            focusPane(pane)
        } else {
            showTab(id: id, in: focusedPane)
        }
    }

    func activateTab(id: UUID, in pane: EditorPane) {
        if tabID(for: pane) == id {
            clearPreview(in: pane)
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
        isExplorerFocused = false
        focusedPane = pane
        activeTabID = tabID(for: pane) ?? primaryTabID
        syncExplorerSelectionToVisibleFile(in: pane)
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
            clearPreview(in: .secondary)
        case .secondary:
            primaryTabID = secondaryTabID
            secondaryTabID = nil
            clearPreview(in: .secondary)
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
    private let defaultSidebarFontSize: CGFloat = 14
    private var defaultTerminalFontSize: CGFloat {
        TerminalAppearance.current.defaultFontSize ?? defaultEditorFontSize
    }

    func adjustFontSize(by delta: CGFloat) {
        sidebarFontSize = max(11, min(28, sidebarFontSize + delta))
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
        sidebarFontSize = defaultSidebarFontSize
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
        clearPreview(in: pane)

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

        if secondaryTabID == nil {
            clearPreview(in: .secondary)
        }

        if let activeTabID, let pane = pane(for: activeTabID) {
            focusedPane = pane
        } else {
            activeTabID = tabID(for: focusedPane) ?? primaryTabID
        }

        syncExplorerSelectionToVisibleFile(in: focusedPane)
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

    private func visibleFileItem(in pane: EditorPane) -> FileItem? {
        if let previewItem = previewedFileItem(in: pane) {
            return previewItem
        }

        guard let tab = tab(with: tabID(for: pane)) else { return nil }
        guard case .file(let item) = tab.kind else { return nil }
        return item
    }

    private func syncExplorerSelectionToVisibleFile(in pane: EditorPane) {
        guard let item = visibleFileItem(in: pane) else { return }
        selectExplorerURL(item.url)
    }

    private var selectedExplorerTargetURL: URL? {
        selectedFileItem?.url ?? selectedFileURLs.first
    }

    private func selectedExplorerTargetItem() -> FileItem? {
        guard let url = selectedExplorerTargetURL else {
            return nil
        }

        if let selectedFileItem, selectedFileItem.url == url {
            return selectedFileItem
        }

        return fileItem(at: url) ?? FileItem(url: url, isDirectory: isDirectory(url))
    }

    private func selectedVisibleExplorerItem(in visibleItems: [FileItem]) -> FileItem? {
        if let selectedURL = selectedExplorerTargetURL,
           let exactMatch = visibleItems.first(where: { $0.url == selectedURL }) {
            return exactMatch
        }

        return visibleItems.first(where: isExplorerItemSelected)
    }

    private func selectedVisibleExplorerIndex(in visibleItems: [FileItem]) -> Int? {
        guard let item = selectedVisibleExplorerItem(in: visibleItems) else {
            return nil
        }

        return visibleItems.firstIndex(where: { $0.url == item.url })
    }

    private func parentExplorerItem(for item: FileItem) -> FileItem? {
        guard let rootURL = fileService.rootURL?.standardizedFileURL else {
            return nil
        }

        let parentURL = item.url.deletingLastPathComponent().standardizedFileURL
        guard parentURL != item.url,
              parentURL.path.hasPrefix(rootURL.path),
              parentURL != rootURL else {
            return nil
        }

        return fileItem(at: parentURL)
    }

    private func fileItem(at url: URL) -> FileItem? {
        let normalizedURL = url.standardizedFileURL

        func search(_ items: [FileItem]) -> FileItem? {
            for item in items {
                if item.url == normalizedURL {
                    return item
                }

                if let children = item.children, let match = search(children) {
                    return match
                }
            }

            return nil
        }

        return search(fileService.rootItems)
    }

    private func observeFileTreeChanges() {
        fileService.$rootItems
            .sink { [weak self] _ in
                self?.reconcileExplorerSelectionAfterTreeChange()
            }
            .store(in: &cancellables)
    }

    private func observeWorkspaceChanges() {
        fileService.$rootURL
            .sink { [weak self] rootURL in
                guard let self else { return }

                let normalizedURL = rootURL?.standardizedFileURL
                guard self.lastRegisteredWorkspaceURL != normalizedURL else { return }

                self.lastRegisteredWorkspaceURL = normalizedURL
                WorkspaceStore.shared.setActiveWorkspace(normalizedURL, for: self.windowID)
            }
            .store(in: &cancellables)
    }

    private func reconcileExplorerSelectionAfterTreeChange() {
        if selectedFileURLs.count > 1 {
            let survivingURLs = Set(selectedFileURLs.filter { fileExists(at: $0) })
            selectedFileURLs = survivingURLs
            if let selectedFileItem, survivingURLs.contains(selectedFileItem.url) {
                self.selectedFileItem = fileItem(at: selectedFileItem.url)
            } else {
                self.selectedFileItem = nil
            }
            if survivingURLs.isEmpty {
                explorerSelectionAnchorURL = nil
            }
            return
        }

        if let visibleURL = focusedVisibleFileURL, fileExists(at: visibleURL) {
            selectExplorerURL(visibleURL, anchorURL: explorerSelectionAnchorURL)
            return
        }

        guard let selectedURL = selectedExplorerTargetURL else { return }
        guard fileExists(at: selectedURL) else {
            clearExplorerSelection()
            return
        }

        selectExplorerURL(selectedURL, anchorURL: explorerSelectionAnchorURL)
    }

    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
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
        guard confirmProtectedClose(.terminal, processCount: 1) else {
            return
        }
        guard let closeResult = terminal.closeFocusedSession() else { return }

        TerminalViewCache.shared.remove(closeResult.removedSessionID)

        if closeResult.shouldCloseTab {
            closeTab(tab, bypassingConfirmation: true)
            return
        }

        focusPane(pane)
    }

    private func confirmTabCloseIfNeeded(_ tab: Tab) -> Bool {
        guard case .terminal(let terminal) = tab.kind else { return true }
        return confirmProtectedClose(.terminal, processCount: terminal.sessionCount)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    private func setPreviewFileItem(_ item: FileItem?, in pane: EditorPane) {
        switch pane {
        case .primary:
            primaryPreviewFileItem = item
        case .secondary:
            secondaryPreviewFileItem = item
        }
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
