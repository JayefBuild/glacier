// AppState.swift
// Central observable state for the entire application.
//
// Tab content & data model (file/terminal/gitGraph) live here. Pane layout,
// per-pane tab ordering, focus, and drag-to-split gestures are owned by
// Bonsplit via BonsplitBridge (see BonsplitBridge.swift).

import SwiftUI
import Combine
import UniformTypeIdentifiers
import Bonsplit

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

@MainActor
final class EditorSaveRequest {
    let url: URL

    private var didAcknowledge = false
    private let onAcknowledge: (() -> Void)?

    init(url: URL, onAcknowledge: (() -> Void)? = nil) {
        self.url = url
        self.onAcknowledge = onAcknowledge
    }

    func acknowledge() {
        guard !didAcknowledge else { return }
        didAcknowledge = true
        onAcknowledge?()
    }
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

    // MARK: - Bonsplit bridge (owns pane layout)

    let bridge: BonsplitBridge

    var bonsplitController: BonsplitController { bridge.controller }

    // MARK: - Init

    init() {
        self.bridge = BonsplitBridge()
        AppStateRegistry.shared.register(self)
        focusDebugLog("GlacierFocus appStateInit")
        self.bridge.appState = self
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

        if environment["GLACIER_OPEN_GIT_GRAPH"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.openGitGraph()

                if let window = NSApp.windows.first(where: { $0.isVisible }) {
                    window.makeKeyAndOrderFront(nil)
                }
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

    var activeTab: Tab? {
        bridge.focusedGlacierTab ?? tabs.first
    }

    // `activeTabID` is a derived convenience for the few call sites that still
    // reference it (tests, commands). It mirrors whatever Bonsplit reports as
    // the focused-pane's selected tab.
    var activeTabID: UUID? {
        bridge.focusedGlacierTabID
    }

    var canSaveFocusedDocument: Bool {
        focusedVisibleFileItem != nil
    }

    var canTrashSelectedExplorerItem: Bool {
        selectedExplorerTargetURL != nil
    }

    var focusedVisibleFileURL: URL? {
        focusedVisibleFileItem?.url
    }

    private var focusedVisibleFileItem: FileItem? {
        if let paneID = bonsplitController.focusedPaneId,
           let previewItem = bridge.preview(inPane: paneID) {
            return previewItem
        }
        guard let tab = activeTab else { return nil }
        if case .file(let item) = tab.kind { return item }
        return nil
    }

    // MARK: - Open File

    func openFile(_ item: FileItem) {
        if let paneID = bonsplitController.focusedPaneId {
            bridge.setPreview(nil, inPane: paneID)
        }

        if let existing = tabs.first(where: {
            if case .file(let f) = $0.kind { return f.url == item.url }
            return false
        }) {
            bridge.selectTab(glacierID: existing.id)
            return
        }
        let tab = Tab(file: item)
        tabs.append(tab)
        bridge.addTab(tab)
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

        guard item.isDirectory, !fileService.isExpanded(item) else {
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

        if !fileService.isExpanded(item) {
            fileService.toggleExpansion(of: item)
            if focusDebugLoggingEnabled {
                focusDebugLog("GlacierFocus expandExplorerItem toggle=\(item.url.path)")
            }
            return true
        }

        guard let firstChild = fileService.children(of: item)?.first else {
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

        if item.isDirectory, fileService.isExpanded(item) {
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

    // MARK: - Preview

    /// Whether the focused pane currently shows a preview item.
    var hasFocusedPreview: Bool {
        guard let paneID = bonsplitController.focusedPaneId else { return false }
        return bridge.preview(inPane: paneID) != nil
    }

    func clearFocusedPreview() {
        guard let paneID = bonsplitController.focusedPaneId else { return }
        bridge.setPreview(nil, inPane: paneID)
    }

    /// Remove the given URL's preview from any pane that's showing it.
    func clearPreview(matching url: URL) {
        for paneID in bonsplitController.allPaneIds {
            if let previewed = bridge.preview(inPane: paneID),
               previewed.url.standardizedFileURL == url.standardizedFileURL {
                bridge.setPreview(nil, inPane: paneID)
            }
        }
    }

    /// Clear previews whose URL is at or under any of the given paths.
    func clearPreviews(underPaths paths: [String]) {
        let normalizedPaths = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for paneID in bonsplitController.allPaneIds {
            guard let previewed = bridge.preview(inPane: paneID) else { continue }
            let previewPath = previewed.url.standardizedFileURL.path
            let shouldClear = normalizedPaths.contains { removedPath in
                previewPath == removedPath || previewPath.hasPrefix(removedPath + "/")
            }
            if shouldClear {
                fileService.beginDiscarding(previewed.url.standardizedFileURL)
                bridge.setPreview(nil, inPane: paneID)
            }
        }
    }

    func previewFile(_ item: FileItem) {
        // Never overlay a terminal tab with a preview — SwiftTerm's NSView gets
        // yanked out of the hierarchy and its rendering wedges until the tab is
        // reselected. Instead, route previews to a pane whose active tab is NOT
        // a terminal. If no such pane exists, fall back to opening the file as
        // a real tab so the terminal just gets deselected, never unmounted.
        if let paneID = nonTerminalPreviewTargetPane() {
            bridge.setPreview(item, inPane: paneID)
        } else {
            openFile(item)
        }
    }

    /// Returns the pane we should use for a preview, preferring the focused
    /// pane if its active tab isn't a terminal, then any other non-terminal
    /// pane, then a pane with no active tab at all.
    private func nonTerminalPreviewTargetPane() -> PaneID? {
        let candidates: [PaneID?] = [bonsplitController.focusedPaneId] + bonsplitController.allPaneIds.map { .some($0) }
        for case let paneID? in candidates where !paneActiveTabIsTerminal(paneID) {
            return paneID
        }
        return nil
    }

    private func paneActiveTabIsTerminal(_ paneID: PaneID) -> Bool {
        guard let selected = bonsplitController.selectedTab(inPane: paneID),
              let glacierID = bridge.glacierTabID(for: selected.id),
              let tab = tab(with: glacierID) else {
            return false
        }
        if case .terminal = tab.kind { return true }
        return false
    }

    func requestSaveForFocusedPane() {
        guard let item = focusedVisibleFileItem else { return }
        postSaveRequest(url: item.url)
    }

    func saveOpenDocumentsBeforeClose(timeout: TimeInterval = 1.5) {
        let urls = visibleDocumentSaveURLs()
        guard !urls.isEmpty else { return }

        var remainingAcks = urls.count
        for url in urls {
            postSaveRequest(url: url) {
                remainingAcks -= 1
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while remainingAcks > 0 && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
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
        guard confirmProtectedClose(.project, processCount: openTerminalSessionCount) else {
            return false
        }

        saveOpenDocumentsBeforeClose()
        return true
    }

    // MARK: - Open Terminal

    func openNewTerminal(workingDirectory: URL? = nil) {
        let dir = workingDirectory ?? fileService.rootURL ?? URL(fileURLWithPath: NSHomeDirectory())
        let terminal = TerminalTabState(workingDirectory: dir, fontSize: defaultTerminalFontSize)
        let tab = Tab(terminal: terminal)
        tabs.append(tab)
        bridge.addTab(tab)
    }

    func openGitGraph() {
        if let existing = tabs.first(where: {
            if case .gitGraph = $0.kind { return true }
            return false
        }) {
            bridge.selectTab(glacierID: existing.id)
            return
        }

        let tab = Tab(gitGraph: ())
        tabs.append(tab)
        bridge.addTab(tab)
    }

    // MARK: - Close Tab

    func closeTab(_ tab: Tab, bypassingConfirmation: Bool = false) {
        guard bypassingConfirmation || confirmTabCloseIfNeeded(tab) else { return }
        saveTabIfNeededBeforeClose(tab)
        bridge.removeTab(glacierID: tab.id)
        // Bonsplit's delegate callback `handleBonsplitTabClosed` finishes the removal.
    }

    func activateTab(id: UUID) {
        bridge.selectTab(glacierID: id)
    }

    func closeOtherTabs(keeping id: UUID) {
        let tabsToClose = tabs.filter { $0.id != id }
        tabsToClose.forEach { closeTab($0) }
    }

    func focusTerminalSession(_ sessionID: UUID) {
        guard let paneID = bonsplitController.focusedPaneId,
              let terminal = visibleTerminalTab(inPane: paneID) else {
            return
        }

        terminal.focusSession(sessionID)
    }

    func handleTerminalCommand(_ command: TerminalShortcutCommand, sessionID: UUID) {
        guard let paneID = bonsplitController.focusedPaneId else { return }
        guard let terminal = visibleTerminalTab(inPane: paneID) else {
            if command == .newTerminalTab {
                openNewTerminal()
            }
            return
        }

        terminal.focusSession(sessionID)

        switch command {
        case .newTerminalTab:
            let workingDirectory = terminal.session(for: sessionID)?.workingDirectory
            openNewTerminal(workingDirectory: workingDirectory)
        case .closeTerminal:
            closeTerminalSession(sessionID, inPane: paneID)
        case .splitTerminalVertical:
            terminal.focusSession(sessionID)
            _ = terminal.splitFocusedSession(.vertical)
        case .splitTerminalHorizontal:
            terminal.focusSession(sessionID)
            _ = terminal.splitFocusedSession(.horizontal)
        case .splitEditorRight:
            bonsplitController.splitPane(orientation: .horizontal)
        case .splitEditorDown:
            bonsplitController.splitPane(orientation: .vertical)
        case .closeEditorSplit:
            if let paneID = bonsplitController.focusedPaneId {
                bonsplitController.closePane(paneID)
            }
        }
    }

    // MARK: - Bonsplit delegate hooks (called by BonsplitBridge)

    func confirmBonsplitTabClose(_ tab: Tab) -> Bool {
        guard confirmTabCloseIfNeeded(tab) else { return false }
        saveTabIfNeededBeforeClose(tab)
        return true
    }

    func handleBonsplitTabClosed(glacierID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == glacierID }) else { return }
        let tab = tabs[idx]
        if case .terminal(let terminal) = tab.kind {
            for sessionID in terminal.allSessionIDs {
                TerminalViewCache.shared.remove(sessionID)
            }
        }
        tabs.remove(at: idx)
    }

    func handleBonsplitTabSelected(glacierID: UUID, inPane paneID: PaneID) {
        guard let tab = tab(with: glacierID) else { return }
        syncExplorerSelectionToVisibleFile(in: tab)
        restoreTerminalFocus(for: tab)
    }

    func handleBonsplitPaneFocused(_ paneID: PaneID) {
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus paneFocused")
        }
        isExplorerFocused = false
        if let tab = tab(with: bridge.focusedGlacierTabID ?? UUID()) {
            syncExplorerSelectionToVisibleFile(in: tab)
            restoreTerminalFocus(for: tab)
        }
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
        // Push the new title into Bonsplit so the tab renders the update.
        if let idx = tabs.firstIndex(where: {
            if case .terminal(let t) = $0.kind { return t.id == terminal.id }
            return false
        }) {
            bridge.syncTabMetadata(tabs[idx])
        }
    }

    // MARK: - Tab Lookup

    func tab(with id: UUID?) -> Tab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    // MARK: - Private helpers

    private func visibleTerminalTab(inPane paneID: PaneID) -> TerminalTabState? {
        guard let selected = bonsplitController.selectedTab(inPane: paneID),
              let glacierID = bridge.glacierTabID(for: selected.id),
              let tab = tab(with: glacierID) else { return nil }
        guard case .terminal(let terminal) = tab.kind else { return nil }
        return terminal
    }

    private func visibleDocumentSaveURLs() -> [URL] {
        var urls: Set<URL> = []
        for paneID in bonsplitController.allPaneIds {
            if let previewItem = bridge.preview(inPane: paneID) {
                urls.insert(previewItem.url)
                continue
            }
            if let selected = bonsplitController.selectedTab(inPane: paneID),
               let glacierID = bridge.glacierTabID(for: selected.id),
               let tab = tab(with: glacierID),
               case .file(let item) = tab.kind {
                urls.insert(item.url)
            }
        }
        return Array(urls)
    }

    private func postSaveRequest(url: URL, onAcknowledge: (() -> Void)? = nil) {
        NotificationCenter.default.post(
            name: .glacierSaveDocument,
            object: EditorSaveRequest(
                url: url,
                onAcknowledge: onAcknowledge
            )
        )
    }

    private func syncExplorerSelectionToVisibleFile(in tab: Tab) {
        guard case .file(let item) = tab.kind else { return }
        selectExplorerURL(item.url)
    }

    private func restoreTerminalFocus(for tab: Tab) {
        guard case .terminal(let terminal) = tab.kind else { return }
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus restore session=\(terminal.focusedSessionID.uuidString)")
        }
        TerminalViewCache.shared.focus(terminal.focusedSessionID)
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
        fileService.fileItem(at: url)
    }

    private func observeFileTreeChanges() {
        fileService.$treeChangeToken
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

    private func closeTerminalSession(_ sessionID: UUID, inPane paneID: PaneID) {
        guard let selected = bonsplitController.selectedTab(inPane: paneID),
              let glacierID = bridge.glacierTabID(for: selected.id),
              let tab = tab(with: glacierID),
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
        }
    }

    private func confirmTabCloseIfNeeded(_ tab: Tab) -> Bool {
        guard case .terminal(let terminal) = tab.kind else { return true }
        return confirmProtectedClose(.terminal, processCount: terminal.sessionCount)
    }

    private func saveTabIfNeededBeforeClose(_ tab: Tab) {
        guard case .file(let item) = tab.kind else {
            return
        }
        postSaveRequest(url: item.url)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
}

// MARK: - Terminal Session
// Definition lives in TerminalSession.swift to isolate the SwiftTerm import.
