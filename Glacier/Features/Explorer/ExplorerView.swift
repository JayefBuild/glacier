// ExplorerView.swift
// File/folder sidebar with recursive tree view, toolbar, and context menus.

import SwiftUI
import AppKit

struct ExplorerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        ExplorerContent(fileService: appState.fileService)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    TitlebarControlStrip(
                        onNewTerminal: {
                            appState.openNewTerminal(workingDirectory: appState.fileService.rootURL)
                        },
                        onToggleSidebar: {
                            toggleSidebar()
                        }
                    )
                }
            }
    }

    private func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }
}

private struct TitlebarControlStrip: View {
    let onNewTerminal: () -> Void
    let onToggleSidebar: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            stripButton(symbolName: "apple.terminal", help: "New Terminal Tab", action: onNewTerminal)

            Rectangle()
                .fill(theme.colors.glassBorder.opacity(0.5))
                .frame(width: 1, height: 18)

            stripButton(symbolName: "sidebar.left", help: "Toggle Sidebar", action: onToggleSidebar)
        }
        .padding(3)
        .frame(height: 34)
        .glacierGlassSurface(
            theme: theme,
            cornerRadius: 14,
            shadowRadius: 8,
            shadowY: 4
        )
    }

    private func stripButton(symbolName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .frame(width: 42, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct ExplorerContent: View {
    @ObservedObject var fileService: FileService
    @EnvironmentObject private var appState: AppState
    @StateObject private var sidebarHost = SidebarHost()
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ExplorerHeaderView(fileService: fileService, sidebarHost: sidebarHost)
            Divider()
            if fileService.rootURL == nil {
                ExplorerEmptyState(fileService: fileService)
            } else {
                ProjectNavigatorOutlineView(host: sidebarHost)
            }
            Spacer(minLength: 0)
            Divider()
            WorkspaceSwitcherView(fileService: fileService)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    LinearGradient(
                        colors: [
                            theme.colors.sidebarBackground.opacity(0.96),
                            theme.colors.windowBackground.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.colors.glassBorder.opacity(0.38))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                appState.focusExplorer()
            },
            including: .subviews
        )
        .onAppear { wireHost() }
        .onChange(of: fileService.rootURL) { _, _ in wireHost() }
    }

    private func wireHost() {
        sidebarHost.setFileManager(fileService.manager)
        sidebarHost.onOpenFile = { url in
            Task { @MainActor in
                let item = FileItem(
                    url: url,
                    isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                )
                appState.previewFile(item)
                appState.selectExplorerURL(url)
            }
        }
        sidebarHost.onOpenFileInTab = { url in
            Task { @MainActor in
                let item = FileItem(
                    url: url,
                    isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                )
                appState.openFile(item)
            }
        }
        sidebarHost.onFileWillBeRenamed = { oldURL in
            // Runs BEFORE disk move. Mark discarding + close tab AND clear preview
            // synchronously so the editor's onDisappear→saveNow fires while the flag
            // is set and is dropped. Must be synchronous (not Task) — the move happens
            // right after this returns.
            let normalized = oldURL.standardizedFileURL
            let normalizedPath = normalized.path
            fileService.beginDiscarding(normalized)

            // Clear preview in any pane that matches.
            appState.clearPreviews(underPaths: [normalizedPath])

            // Close open tabs for this URL or anything under it.
            for tab in appState.tabs {
                guard case .file(let fileItem) = tab.kind else { continue }
                let tabPath = fileItem.url.standardizedFileURL.path
                if tabPath == normalizedPath || tabPath.hasPrefix(normalizedPath + "/") {
                    fileService.beginDiscarding(fileItem.url.standardizedFileURL)
                    appState.closeTab(tab, bypassingConfirmation: true)
                }
            }
        }
        sidebarHost.onFilesWillBeRemoved = { removedURLs in
            // Runs BEFORE disk mutation. Same synchronous close + flag pattern,
            // plus preview clearing.
            let normalized = removedURLs.map { $0.standardizedFileURL.path }
            for url in removedURLs {
                fileService.beginDiscarding(url.standardizedFileURL)
            }

            // Clear preview in any pane that matches.
            appState.clearPreviews(underPaths: normalized)

            // Close matching tabs.
            for tab in appState.tabs {
                guard case .file(let fileItem) = tab.kind else { continue }
                let tabPath = fileItem.url.standardizedFileURL.path
                let match = normalized.contains { removed in
                    tabPath == removed || tabPath.hasPrefix(removed + "/")
                }
                if match {
                    fileService.beginDiscarding(fileItem.url.standardizedFileURL)
                    appState.closeTab(tab, bypassingConfirmation: true)
                }
            }
        }
        sidebarHost.onFileRenamed = { oldURL, newURL in
            // Runs AFTER disk move. Tab was already closed by onFileWillBeRenamed;
            // just reopen under the new URL and clear the discarding flag.
            Task { @MainActor in
                // Delay briefly so any in-flight debounced save has a chance to fire
                // (and be dropped by the discarding flag) before we release it.
                try? await Task.sleep(nanoseconds: 600_000_000)
                fileService.endDiscarding(oldURL.standardizedFileURL)

                // If the rename was a file (not folder), open the renamed URL in a new tab.
                let isFolder = (try? newURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isFolder {
                    let newItem = FileItem(url: newURL, isDirectory: false)
                    appState.openFile(newItem)
                }
            }
        }
        sidebarHost.onFilesRemoved = { removedURLs in
            // Runs AFTER disk mutation. Tabs were already closed by onFilesWillBeRemoved;
            // just clear the discarding flags once pending saves have had a chance to fire.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                for url in removedURLs {
                    fileService.endDiscarding(url.standardizedFileURL)
                }
            }
        }
    }
}

// MARK: - Header + Toolbar

private struct ExplorerHeaderView: View {
    @ObservedObject var fileService: FileService
    @ObservedObject var sidebarHost: SidebarHost
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var gitBranch: String?

    var title: String {
        fileService.rootURL?.lastPathComponent ?? "No Folder"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Folder name row
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: appState.sidebarCaptionFontSize, weight: .semibold))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let gitBranch, !gitBranch.isEmpty {
                    Text("\u{00B7}")
                        .font(.system(size: appState.sidebarCaptionFontSize))
                        .foregroundStyle(.tertiary)
                    Text(gitBranch)
                        .font(.system(size: appState.sidebarCaptionFontSize - 1, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Toolbar
            if fileService.rootURL != nil {
                ExplorerToolbar(fileService: fileService, sidebarHost: sidebarHost)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
        .onAppear { refreshGitBranch(for: fileService.rootURL) }
        .onChange(of: fileService.rootURL) { _, url in
            refreshGitBranch(for: url)
        }
    }

    private func refreshGitBranch(for url: URL?) {
        guard let url else {
            gitBranch = nil
            return
        }
        Task.detached {
            let branch = runGitBranch(in: url)
            await MainActor.run { self.gitBranch = branch }
        }
    }
}

private func runGitBranch(in url: URL) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", url.path, "rev-parse", "--abbrev-ref", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (str?.isEmpty == false) ? str : nil
}

// MARK: - Toolbar

private struct ExplorerToolbar: View {
    @ObservedObject var fileService: FileService
    @ObservedObject var sidebarHost: SidebarHost
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var showNewFileSheet = false
    @State private var showNewFolderSheet = false

    private var isGitGraphActive: Bool {
        guard let activeTab = appState.activeTab else { return false }
        if case .gitGraph = activeTab.kind {
            return true
        }
        return false
    }

    private var canRevealActiveFile: Bool {
        guard let activeTab = appState.activeTab else { return false }
        if case .file = activeTab.kind {
            return true
        }
        return false
    }

    var body: some View {
        HStack(spacing: 2) {
            toolbarButton(icon: "doc.badge.plus", help: "New File") {
                showNewFileSheet = true
            }

            toolbarButton(icon: "folder.badge.plus", help: "New Folder") {
                showNewFolderSheet = true
            }

            toolbarButton(icon: "pencil.and.scribble", help: "New Excalidraw Drawing") {
                createExcalidrawDrawing()
            }

            toolbarButton(icon: "calendar.badge.clock", help: "New Markwhen Timeline") {
                createMarkwhenFile()
            }

            toolbarButton(
                icon: "point.3.connected.trianglepath.dotted",
                help: "Open Git Graph",
                isActive: isGitGraphActive
            ) {
                appState.openGitGraph()
            }

            toolbarButton(icon: "arrow.triangle.turn.up.right.circle", help: "Reveal Active File in Sidebar") {
                revealActiveFile()
            }
            .disabled(!canRevealActiveFile)

            Spacer()

            toolbarButton(icon: "xmark", help: "Close Folder") {
                fileService.closeFolder()
            }
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showNewFileSheet) {
            CreateItemSheet(
                title: "New File",
                placeholder: "note.md",
                helperText: "Leave off the extension to create a Markdown note.",
                directory: fileService.rootURL ?? URL(fileURLWithPath: NSHomeDirectory())
            ) { name in
                let url = try fileService.createFile(
                    named: name,
                    in: fileService.rootURL!,
                    defaultExtension: "md"
                )
                fileService.reload()
                refreshSidebarRoot()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let item = FileItem(url: url, isDirectory: false)
                    appState.openFile(item)
                }
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            CreateItemSheet(
                title: "New Folder",
                placeholder: "folder-name",
                directory: fileService.rootURL ?? URL(fileURLWithPath: NSHomeDirectory())
            ) { name in
                _ = try fileService.createFolder(named: name, in: fileService.rootURL!)
                fileService.reload()
                refreshSidebarRoot()
            }
        }
    }

    private func toolbarButton(
        icon: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? theme.colors.accent : .secondary)
        .help(help)
    }

    private func createMarkwhenFile() {
        guard let dir = fileService.rootURL else { return }

        var name = "Timeline"
        var candidate = dir.appendingPathComponent("\(name).mw")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            name = "Timeline \(counter)"
            candidate = dir.appendingPathComponent("\(name).mw")
            counter += 1
        }

        let template = """
        section \(name)

        // Add events below. Format: MM/DD/YYYY - MM/DD/YYYY: Event Title #Color
        // Example:
        // 01/01/2025 - 06/01/2025: Project Kickoff #Blue
        // 06/01/2025: Milestone #Pink

        endSection
        """
        do {
            try template.write(to: candidate, atomically: true, encoding: .utf8)
            fileService.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let item = FileItem(url: candidate, isDirectory: false)
                appState.openFile(item)
            }
        } catch {}
    }

    private func createExcalidrawDrawing() {
        guard let dir = fileService.rootURL else { return }

        // Find a unique filename: Drawing.excalidraw, Drawing 2.excalidraw, ...
        var name = "Drawing"
        var candidate = dir.appendingPathComponent("\(name).excalidraw")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            name = "Drawing \(counter)"
            candidate = dir.appendingPathComponent("\(name).excalidraw")
            counter += 1
        }

        let emptyDrawing = """
        {"type":"excalidraw","version":2,"source":"glacier","elements":[],"appState":{"gridSize":null,"viewBackgroundColor":"#ffffff"},"files":{}}
        """
        do {
            try emptyDrawing.write(to: candidate, atomically: true, encoding: .utf8)
            fileService.reload()
            // Open the new file in a tab
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let item = FileItem(url: candidate, isDirectory: false)
                appState.openFile(item)
            }
        } catch {
            // Silently fail — file system issue
        }
    }

    private func revealActiveFile() {
        guard let tab = appState.activeTab,
              case .file(let item) = tab.kind else { return }
        appState.selectExplorerItem(item)
        // Drive the NSOutlineView sidebar to scroll + select + expand parents.
        sidebarHost.reveal(item.url)
    }

    /// Force the NSOutlineView sidebar (driven by `CEWorkspaceFileManager`) to re-diff its
    /// root children immediately. Without this, toolbar-created files/folders only appear
    /// after the FSEvents stream catches up — which can take a moment (or miss entirely if
    /// the user launched Glacier from Spotlight and FSEvents hasn't primed yet).
    private func refreshSidebarRoot() {
        guard let manager = sidebarHost.fileManager else { return }
        let root = manager.workspaceItem
        do {
            try manager.rebuildFiles(fromItem: root)
            manager.notifyObservers(updatedItems: [root])
        } catch {
            // Non-fatal: FSEvents will eventually catch up.
        }
    }
}

// MARK: - Empty State

private struct ExplorerEmptyState: View {
    @ObservedObject var fileService: FileService
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("Open a Folder")
                .font(.system(size: appState.sidebarLabelFontSize, weight: .regular))
                .foregroundStyle(.secondary)

            Button("Choose…") {
                openFolderPanel { url in
                    fileService.openFolder(at: url)
                }
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Shared Panel Helper

@MainActor
func openFolderPanel(completion: @MainActor @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.title = "Open Folder"

    NSApp.activate(ignoringOtherApps: true)

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    } else {
        panel.begin { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
}

// MARK: - Create Item Sheet

struct CreateItemSheet: View {
    let title: String
    let placeholder: String
    let helperText: String?
    let directory: URL
    let onCreate: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var name: String = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(
        title: String,
        placeholder: String,
        helperText: String? = nil,
        directory: URL,
        onCreate: @escaping (String) throws -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.helperText = helperText
        self.directory = directory
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(theme.typography.labelFont)
                .fontWeight(.semibold)

            Text("in \(directory.lastPathComponent)")
                .font(theme.typography.captionFont)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commit() }

            if let helperText {
                Text(helperText)
                    .font(theme.typography.captionFont)
                    .foregroundStyle(.secondary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(theme.typography.captionFont)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try onCreate(trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    let item: FileItem
    let onRename: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(item: FileItem, onRename: @escaping (String) throws -> Void) {
        self.item = item
        self.onRename = onRename
        _name = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename")
                .font(theme.typography.labelFont)
                .fontWeight(.semibold)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commit() }

            if let error = errorMessage {
                Text(error)
                    .font(theme.typography.captionFont)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == item.name)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        do {
            try onRename(trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Git Sidebar

struct GitGraphView: View {
    @ObservedObject var fileService: FileService

    @StateObject private var model = GitGraphSidebarModel()
    @Environment(\.appTheme) private var theme

    private var workspaceURL: URL? {
        fileService.rootURL
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle:
                GitSidebarMessageView(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Git not initialized",
                    message: "Open a folder inside a Git repository to view its history."
                )

            case .loading:
                ProgressView("Loading Git History…")
                    .controlSize(.small)
                    .font(theme.typography.captionFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .notGit(let workspaceName):
                GitSidebarMessageView(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Git not initialized",
                    message: "\(workspaceName) is not inside a Git repository."
                )

            case .failed(let message):
                GitSidebarMessageView(
                    icon: "exclamationmark.triangle",
                    title: "Unable to Load Git History",
                    message: message
                )

            case .ready(let snapshot):
                GitGraphContentView(
                    snapshot: snapshot,
                    onRefresh: {
                        Task { await model.load(for: workspaceURL) }
                    },
                    onLoadMore: {
                        Task { await model.loadMore(for: workspaceURL) }
                    }
                )
            }
        }
        .task(id: workspaceURL?.path ?? "no-workspace") {
            await model.load(for: workspaceURL)
        }
    }
}

@MainActor
private final class GitGraphSidebarModel: ObservableObject {
    enum State {
        case idle
        case loading
        case notGit(workspaceName: String)
        case ready(GitGraphSnapshot)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func load(for workspaceURL: URL?) async {
        guard let workspaceURL else {
            state = .idle
            return
        }

        state = .loading
        let result = await Task.detached(priority: .userInitiated) {
            GitGraphLoader.load(from: workspaceURL)
        }.value

        switch result {
        case .notGit(let workspaceName):
            state = .notGit(workspaceName: workspaceName)
        case .ready(let snapshot):
            state = .ready(snapshot)
        case .failed(let message):
            state = .failed(message)
        }
    }

    func loadMore(for workspaceURL: URL?) async {
        guard let workspaceURL, case .ready(let current) = state, current.canLoadMore else { return }
        let result = await Task.detached(priority: .userInitiated) {
            GitGraphLoader.loadMore(from: workspaceURL, existing: current)
        }.value
        if case .ready(let updated) = result {
            state = .ready(updated)
        }
    }
}

private struct GitGraphContentView: View {
    let snapshot: GitGraphSnapshot
    let onRefresh: () -> Void
    let onLoadMore: () -> Void

    @Environment(\.appTheme) private var theme

    private var workingTreeLane: Int {
        snapshot.rows.first?.commitLane ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.repoName)
                            .font(theme.typography.labelFont)
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.colors.primaryText)
                            .lineLimit(1)

                        Text(snapshot.repoPath)
                            .font(theme.typography.captionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let statusLine = snapshot.statusLine, !statusLine.isEmpty {
                            Text(statusLine)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.colors.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh Git Graph")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    if !snapshot.workingTreeEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Working Tree")
                                    .font(theme.typography.captionFont.weight(.semibold))
                                    .foregroundStyle(theme.colors.secondaryText)

                                Spacer()

                                Text("\(snapshot.workingTreeEntries.count) unstaged")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 6)

                            ForEach(Array(snapshot.workingTreeEntries.enumerated()), id: \.element.id) { index, entry in
                                GitWorkingTreeRowView(
                                    entry: entry,
                                    graphColumnCount: snapshot.graphColumnCount,
                                    lane: workingTreeLane,
                                    isFirst: index == 0,
                                    isLast: index == snapshot.workingTreeEntries.count - 1,
                                    connectsToHistory: !snapshot.rows.isEmpty
                                )
                            }
                            .padding(.bottom, 8)
                        }

                        Divider()
                    }

                    if snapshot.rows.isEmpty {
                        GitSidebarMessageView(
                            icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                            title: "No Commits Yet",
                            message: "This repository exists, but it does not have any commits yet.",
                            fillsAvailableSpace: false
                        )
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(snapshot.rows) { row in
                                GitGraphRowView(
                                    row: row,
                                    graphColumnCount: snapshot.graphColumnCount
                                )
                            }

                            if snapshot.canLoadMore {
                                Button(action: onLoadMore) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "ellipsis.circle")
                                            .font(.system(size: 12))
                                        Text("Load More  (\(snapshot.loadedCommitCount) of \(snapshot.totalCommitCount))")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: snapshot.rows.isEmpty ? .infinity : nil, alignment: .topLeading)
                .fixedSize(horizontal: snapshot.rows.isEmpty == false, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GitGraphRowView: View {
    let row: GitGraphRow
    let graphColumnCount: Int

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            GitLaneGraphView(
                row: row,
                graphColumnCount: graphColumnCount,
                isCurrentCommit: row.isCurrentCommit
            )
            .padding(.leading, 14)

            HStack(alignment: .center, spacing: 6) {
                if !row.pillGroups.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(row.pillGroups.enumerated()), id: \.offset) { _, group in
                            GitBranchPill(group: group)
                        }
                    }
                }

                Text(row.subject)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(
                        row.isMergeCommit
                            ? theme.colors.primaryText.opacity(0.35)
                            : theme.colors.primaryText
                    )
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
        }
        .frame(height: 29)
    }
}

private struct GitWorkingTreeRowView: View {
    let entry: GitWorkingTreeEntry
    let graphColumnCount: Int
    let lane: Int
    let isFirst: Bool
    let isLast: Bool
    let connectsToHistory: Bool

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            GitWorkingTreeLaneView(
                graphColumnCount: graphColumnCount,
                lane: lane,
                isFirst: isFirst,
                isLast: isLast,
                connectsToHistory: connectsToHistory
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.status.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(entry.status.tint)
                        .clipShape(Capsule())

                    Text(entry.path)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.colors.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct GitLaneGraphView: View {
    let row: GitGraphRow
    let graphColumnCount: Int
    let isCurrentCommit: Bool

    @Environment(\.appTheme) private var theme

    private let laneSpacing: CGFloat = 18

    private var palette: [Color] {
        GitGraphPalette.colors(for: theme)
    }

    private var graphWidth: CGFloat {
        let columns = max(graphColumnCount, 1)
        return CGFloat(columns) * laneSpacing + 14
    }

    private var graphHeight: CGFloat {
        29
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let centerY = size.height / 2
            let topY: CGFloat = 1
            let bottomY = size.height - 1
            let strokeStyle = StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round)

            // Draw all lane lines first, passing through commit center (bead-on-wire)
            for segment in row.segments {
                let start = point(for: segment.startLane, anchor: segment.startAnchor, topY: topY, centerY: centerY, bottomY: bottomY)
                let end = point(for: segment.endLane, anchor: segment.endAnchor, topY: topY, centerY: centerY, bottomY: bottomY)
                let color = palette[segment.colorIndex % palette.count]

                var path = Path()
                path.move(to: start)
                if segment.startLane == segment.endLane {
                    path.addLine(to: end)
                } else {
                    let bend = abs(end.y - start.y) * 0.72
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: min(start.y + bend, bottomY)),
                        control2: CGPoint(x: end.x, y: max(end.y - bend, topY))
                    )
                }

                context.stroke(path, with: .color(color), style: strokeStyle)
            }

            // Draw dot on top of lines — "bead on a wire" effect
            let commitColor = palette[row.commitColorIndex % palette.count]
            let commitX = xPosition(for: row.commitLane)
            let radius: CGFloat = 5.5
            let haloRect = CGRect(x: commitX - radius - 2, y: centerY - radius - 2, width: (radius + 2) * 2, height: (radius + 2) * 2)
            let commitRect = CGRect(x: commitX - radius, y: centerY - radius, width: radius * 2, height: radius * 2)

            if isCurrentCommit {
                // Hollow ring for HEAD commit
                context.fill(Path(ellipseIn: haloRect), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(Path(ellipseIn: commitRect), with: .color(commitColor), style: StrokeStyle(lineWidth: 2.5))
            } else {
                // Punched background halo so lines don't bleed through dot
                context.fill(Path(ellipseIn: haloRect), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.fill(Path(ellipseIn: commitRect), with: .color(commitColor))
            }
        }
        .frame(width: graphWidth, height: graphHeight, alignment: .leading)
        .drawingGroup()
    }

    private func point(for lane: Int, anchor: GitLaneAnchor, topY: CGFloat, centerY: CGFloat, bottomY: CGFloat) -> CGPoint {
        CGPoint(
            x: xPosition(for: lane),
            y: {
                switch anchor {
                case .top:
                    return topY
                case .center:
                    return centerY
                case .bottom:
                    return bottomY
                }
            }()
        )
    }

    private func xPosition(for lane: Int) -> CGFloat {
        6 + CGFloat(lane) * laneSpacing + (laneSpacing / 2)
    }
}

private struct GitWorkingTreeLaneView: View {
    let graphColumnCount: Int
    let lane: Int
    let isFirst: Bool
    let isLast: Bool
    let connectsToHistory: Bool

    private let laneSpacing: CGFloat = 18

    private var graphWidth: CGFloat {
        let columns = max(graphColumnCount, 1)
        return CGFloat(columns) * laneSpacing + 14
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let x = xPosition(for: lane)
            let centerY = size.height / 2
            let topY: CGFloat = 2
            let bottomY = size.height - 2
            let tint = Color(red: 0.97, green: 0.59, blue: 0.22)

            var line = Path()
            if !isFirst {
                line.move(to: CGPoint(x: x, y: topY))
                line.addLine(to: CGPoint(x: x, y: centerY - 5))
            }
            if !isLast || connectsToHistory {
                line.move(to: CGPoint(x: x, y: centerY + 5))
                line.addLine(to: CGPoint(x: x, y: bottomY))
            }
            context.stroke(
                line,
                with: .color(tint.opacity(0.9)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )

            var diamond = Path()
            diamond.move(to: CGPoint(x: x, y: centerY - 4.5))
            diamond.addLine(to: CGPoint(x: x + 4.5, y: centerY))
            diamond.addLine(to: CGPoint(x: x, y: centerY + 4.5))
            diamond.addLine(to: CGPoint(x: x - 4.5, y: centerY))
            diamond.closeSubpath()

            context.fill(diamond, with: .color(tint))
            context.stroke(
                diamond,
                with: .color(Color.white.opacity(0.8)),
                style: StrokeStyle(lineWidth: 1)
            )
        }
        .frame(width: graphWidth, height: 24, alignment: .leading)
        .drawingGroup()
    }

    private func xPosition(for lane: Int) -> CGFloat {
        6 + CGFloat(lane) * laneSpacing + (laneSpacing / 2)
    }
}

private enum GitGraphPalette {
    static func colors(for theme: any AppTheme) -> [Color] {
        [
            Color(red: 0.16, green: 0.56, blue: 0.95),
            Color(red: 0.13, green: 0.74, blue: 0.55),
            Color(red: 0.97, green: 0.59, blue: 0.22),
            Color(red: 0.87, green: 0.29, blue: 0.52),
            Color(red: 0.65, green: 0.48, blue: 0.96),
            Color(red: 0.27, green: 0.79, blue: 0.84),
            Color(red: 0.93, green: 0.34, blue: 0.54),
            Color(red: 0.90, green: 0.78, blue: 0.27),
            theme.colors.accent
        ]
    }

    static func color(_ index: Int, theme: any AppTheme) -> Color {
        let colors = colors(for: theme)
        return colors[index % colors.count]
    }
}

/// Cursor-style branch/ref pill. Shows the branch name as the primary label, and
/// — when the commit is also pointed at by a remote-tracking ref of the same
/// short name — a second segment (`origin`) appears on the left, visually
/// merged into one rounded-rectangle pill.
private struct GitBranchPill: View {
    let group: GitBranchPillGroup

    @Environment(\.appTheme) private var theme

    private var tintColor: Color {
        if group.isHead {
            return Color(red: 0.55, green: 0.55, blue: 0.58)
        }
        return GitGraphPalette.color(group.colorIndex, theme: theme)
    }

    private var foreground: Color { Color.white }

    var body: some View {
        HStack(spacing: 0) {
            segment(text: group.primaryLabel, fill: tintColor, showsIcon: group.showsBranchIcon)
            if let remote = group.remoteSegment {
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1)
                segment(text: remote, fill: tintColor.opacity(0.72), showsIcon: false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func segment(text: String, fill: Color, showsIcon: Bool) -> some View {
        HStack(spacing: 3) {
            if showsIcon {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(foreground)
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(fill)
    }
}

private struct GitSidebarMessageView: View {
    let icon: String
    let title: String
    let message: String
    let fillsAvailableSpace: Bool

    @Environment(\.appTheme) private var theme

    init(
        icon: String,
        title: String,
        message: String,
        fillsAvailableSpace: Bool = true
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.fillsAvailableSpace = fillsAvailableSpace
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(theme.typography.labelFont)
                .fontWeight(.semibold)
                .foregroundStyle(theme.colors.primaryText)

            Text(message)
                .font(theme.typography.captionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableSpace ? .infinity : nil)
        .padding()
    }
}

enum GitGraphLoadResult: Sendable {
    case notGit(workspaceName: String)
    case ready(GitGraphSnapshot)
    case failed(String)
}

struct GitGraphSnapshot: Sendable {
    let repoName: String
    let repoPath: String
    let currentRef: String
    let statusLine: String?
    let branchNames: [String]
    let workingTreeEntries: [GitWorkingTreeEntry]
    let rows: [GitGraphRow]
    let graphColumnCount: Int
    let totalCommitCount: Int
    let loadedCommitCount: Int

    var canLoadMore: Bool { loadedCommitCount < totalCommitCount }
}

struct GitGraphRow: Identifiable, Sendable {
    let id: Int
    let shortHash: String
    let references: [GitReference]
    let pillGroups: [GitBranchPillGroup]
    let subject: String
    let commitLane: Int
    let commitColorIndex: Int
    let isCurrentCommit: Bool
    let isMergeCommit: Bool
    let segments: [GitLaneSegment]

    var maxLaneIndex: Int {
        max(
            commitLane,
            segments.flatMap { [$0.startLane, $0.endLane] }.max() ?? 0
        )
    }
}

/// A visual grouping of related refs that should render as a single pill.
/// Example: `main` + `origin/main` collapses into one pill with a leading
/// "origin" segment followed by the branch name.
struct GitBranchPillGroup: Hashable, Sendable {
    let primaryLabel: String
    let remoteSegment: String?
    let isHead: Bool
    let colorIndex: Int
    let showsBranchIcon: Bool
}

struct GitReference: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case head
        case localBranch
        case remoteBranch
        case tag
        case other
    }

    let label: String
    let kind: Kind
}

struct GitWorkingTreeEntry: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let status: GitWorkingTreeStatus

    init(path: String, status: GitWorkingTreeStatus) {
        self.id = "\(status.label):\(path)"
        self.path = path
        self.status = status
    }
}

enum GitWorkingTreeStatus: Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted

    var label: String {
        switch self {
        case .modified:
            return "MOD"
        case .added:
            return "ADD"
        case .deleted:
            return "DEL"
        case .renamed:
            return "REN"
        case .copied:
            return "CPY"
        case .untracked:
            return "NEW"
        case .conflicted:
            return "CON"
        }
    }

    var tint: Color {
        switch self {
        case .modified:
            return Color(red: 0.97, green: 0.59, blue: 0.22)
        case .added, .copied, .untracked:
            return Color(red: 0.13, green: 0.74, blue: 0.55)
        case .deleted:
            return Color(red: 0.87, green: 0.29, blue: 0.52)
        case .renamed:
            return Color(red: 0.16, green: 0.56, blue: 0.95)
        case .conflicted:
            return Color(red: 0.93, green: 0.34, blue: 0.54)
        }
    }
}

// MARK: - Lane geometry

enum GitLaneAnchor: Hashable, Sendable {
    case top, center, bottom
}

struct GitLaneSegment: Hashable, Sendable {
    let startLane: Int
    let endLane: Int
    let startAnchor: GitLaneAnchor
    let endAnchor: GitLaneAnchor
    let colorIndex: Int
}

// MARK: - Git command protocol (inspired by maoyama/Changes)

private protocol GitCommand {
    associatedtype Output
    var repoRoot: String { get }
    var arguments: [String] { get }
    func parse(_ stdout: String) -> Output
}

private extension GitCommand {
    func run() -> Result<Output, GitError> {
        let result = GitProcess.run(arguments: ["-C", repoRoot] + arguments)
        guard result.exitCode == 0 else {
            return .failure(GitError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(parse(result.stdout))
    }
}

private struct GitError: Error { let message: String }

private struct GitCmdResult { let exitCode: Int32; let stdout: String; let stderr: String }

private enum GitProcess {
    static func run(arguments: [String]) -> GitCmdResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        let stdoutQ = DispatchQueue(label: "glacier.git.stdout")
        let stderrQ = DispatchQueue(label: "glacier.git.stderr")

        stdoutPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil } else { stdoutQ.sync { stdoutData.append(chunk) } }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil } else { stderrQ.sync { stderrData.append(chunk) } }
        }

        do { try process.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return GitCmdResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        process.waitUntilExit()
        stdoutQ.sync { stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile()) }
        stderrQ.sync { stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile()) }
        return GitCmdResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}

// MARK: - Typed commands

private struct GitRepoRoot: GitCommand {
    let repoRoot: String
    var arguments: [String] { ["rev-parse", "--show-toplevel"] }
    func parse(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
private struct GitCurrentRef: GitCommand {
    let repoRoot: String
    var arguments: [String] { ["symbolic-ref", "--quiet", "--short", "HEAD"] }
    func parse(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
private struct GitDetachedHead: GitCommand {
    let repoRoot: String
    var arguments: [String] { ["rev-parse", "--short", "HEAD"] }
    func parse(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
private struct GitStatusLine: GitCommand {
    let repoRoot: String
    var arguments: [String] { ["status", "--short", "--branch"] }
    func parse(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).first.map(String.init)?
            .replacingOccurrences(of: "## ", with: "")
    }
}
private struct GitWorkingTreeCmd: GitCommand {
    let repoRoot: String
    var arguments: [String] { ["status", "--porcelain=v1", "--untracked-files=all"] }
    func parse(_ s: String) -> [GitWorkingTreeEntry] { parseWorkingTreeEntries(from: s) }
}
private struct GitBranchesCmd: GitCommand {
    let repoRoot: String
    var arguments: [String] { ["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads", "refs/remotes"] }
    func parse(_ s: String) -> [String] { s.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty } }
}
private struct GitRemotesCmd: GitCommand {
    let repoRoot: String
    var arguments: [String] { ["remote"] }
    func parse(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}
private struct GitTotalCountCmd: GitCommand {
    let repoRoot: String
    var arguments: [String] { ["rev-list", "--count", "--all"] }
    func parse(_ s: String) -> Int { Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
}
private struct GitLogCmd: GitCommand {
    let repoRoot: String
    let skip: Int
    let limit: Int
    let remoteNames: Set<String>
    var arguments: [String] {
        ["log", "--topo-order", "--decorate=short", "--pretty=format:%h\u{1f}%H\u{1f}%P\u{1f}%D\u{1f}%s",
         "--all", "--skip", "\(skip)", "-n", "\(limit)", "--color=never"]
    }
    func parse(_ s: String) -> [GitGraphCommitRecord] {
        s.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { return nil }
            return GitGraphCommitRecord(
                shortHash: fields[0], fullHash: fields[1],
                parentHashes: fields[2].split(separator: " ").map(String.init),
                references: parseReferences(fields[3], remoteNames: remoteNames),
                subject: fields[4]
            )
        }
    }
}

// MARK: - Git data models

private struct GitGraphCommitRecord: Sendable {
    let shortHash: String
    let fullHash: String
    let parentHashes: [String]
    let references: [GitReference]
    let subject: String
}

private struct GitActiveLane: Hashable, Sendable {
    let id: Int
    let hash: String
    let colorIndex: Int
}

private struct GitRowBuildState: Sendable {
    let rows: [GitGraphRow]
    let graphColumnCount: Int
}

// MARK: - Loader

private enum GitGraphLoader {
    static let pageSize = 150

    static func load(from workspaceURL: URL) -> GitGraphLoadResult {
        let workspacePath = workspaceURL.path
        let rootResult = GitRepoRoot(repoRoot: workspacePath).run()
        guard case .success(let repoRoot) = rootResult, !repoRoot.isEmpty else {
            return .notGit(workspaceName: workspaceURL.lastPathComponent)
        }
        return loadCommits(repoRoot: repoRoot, skip: 0, mergeInto: nil)
    }

    static func loadMore(from workspaceURL: URL, existing: GitGraphSnapshot) -> GitGraphLoadResult {
        let rootResult = GitRepoRoot(repoRoot: workspaceURL.path).run()
        guard case .success(let repoRoot) = rootResult, !repoRoot.isEmpty else {
            return .notGit(workspaceName: workspaceURL.lastPathComponent)
        }
        return loadCommits(repoRoot: repoRoot, skip: existing.loadedCommitCount, mergeInto: existing)
    }

    private static func loadCommits(repoRoot: String, skip: Int, mergeInto existing: GitGraphSnapshot?) -> GitGraphLoadResult {
        let currentRef = (try? GitCurrentRef(repoRoot: repoRoot).run().get()) ?? ""
        let detachedHead = (try? GitDetachedHead(repoRoot: repoRoot).run().get()) ?? ""
        let statusLine = (try? GitStatusLine(repoRoot: repoRoot).run().get()) ?? nil
        let workingTreeEntries = skip == 0 ? ((try? GitWorkingTreeCmd(repoRoot: repoRoot).run().get()) ?? []) : (existing?.workingTreeEntries ?? [])
        let branchNames = skip == 0 ? ((try? GitBranchesCmd(repoRoot: repoRoot).run().get()) ?? []) : (existing?.branchNames ?? [])
        let remoteNames = (try? GitRemotesCmd(repoRoot: repoRoot).run().get()) ?? []

        let hasCommits = GitProcess.run(arguments: ["-C", repoRoot, "rev-parse", "--verify", "HEAD"]).exitCode == 0
        let totalCount = hasCommits ? ((try? GitTotalCountCmd(repoRoot: repoRoot).run().get()) ?? 0) : 0

        let rowState: GitRowBuildState
        if hasCommits {
            let logResult = GitLogCmd(repoRoot: repoRoot, skip: skip, limit: pageSize, remoteNames: remoteNames).run()
            guard case .success(let commits) = logResult else {
                if case .failure(let err) = logResult { return .failed(err.message) }
                return .failed("Unknown error loading commits")
            }
            rowState = buildRows(from: commits)
        } else {
            rowState = GitRowBuildState(rows: [], graphColumnCount: 0)
        }

        let allRows: [GitGraphRow]
        let columnCount: Int
        if let existing {
            let idOffset = existing.rows.count
            let offsetRows = rowState.rows.map { row in
                GitGraphRow(id: row.id + idOffset, shortHash: row.shortHash, references: row.references,
                            pillGroups: row.pillGroups, subject: row.subject, commitLane: row.commitLane,
                            commitColorIndex: row.commitColorIndex, isCurrentCommit: row.isCurrentCommit,
                            isMergeCommit: row.isMergeCommit, segments: row.segments)
            }
            allRows = existing.rows + offsetRows
            columnCount = max(existing.graphColumnCount, rowState.graphColumnCount)
        } else {
            allRows = rowState.rows
            columnCount = rowState.graphColumnCount
        }

        let repoURL = URL(fileURLWithPath: repoRoot)
        return .ready(GitGraphSnapshot(
            repoName: repoURL.lastPathComponent,
            repoPath: displayPath(for: repoURL),
            currentRef: currentRef.isEmpty ? (detachedHead.isEmpty ? "HEAD" : detachedHead) : currentRef,
            statusLine: statusLine,
            branchNames: branchNames,
            workingTreeEntries: workingTreeEntries,
            rows: allRows,
            graphColumnCount: columnCount,
            totalCommitCount: totalCount,
            loadedCommitCount: skip + rowState.rows.count
        ))
    }

    private static func displayPath(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Lane layout algorithm

private func buildRows(from commits: [GitGraphCommitRecord]) -> GitRowBuildState {
    let visibleHashes = Set(commits.map(\.fullHash))
    var rows: [GitGraphRow] = []
    var activeLanes: [GitActiveLane] = []
    var nextLaneIdentifier = 0
    var nextColorIndex = 0

    func makeLane(hash: String, colorIndex: Int? = nil) -> GitActiveLane {
        defer { nextLaneIdentifier += 1 }
        let lane = GitActiveLane(id: nextLaneIdentifier, hash: hash, colorIndex: colorIndex ?? nextColorIndex)
        if colorIndex == nil { nextColorIndex += 1 }
        return lane
    }

    for (index, commit) in commits.enumerated() {
        let commitWasAlreadyTracked = activeLanes.contains(where: { $0.hash == commit.fullHash })
        if !commitWasAlreadyTracked { activeLanes.append(makeLane(hash: commit.fullHash)) }

        let lanesBefore = activeLanes
        guard let commitLaneIndex = lanesBefore.firstIndex(where: { $0.hash == commit.fullHash }) else { continue }
        let commitLane = lanesBefore[commitLaneIndex]
        var lanesAfter = lanesBefore
        var commitSegments: [GitLaneSegment] = []

        let visibleParents = commit.parentHashes.filter { visibleHashes.contains($0) }
        if visibleParents.isEmpty {
            lanesAfter.remove(at: commitLaneIndex)
        } else {
            let firstParent = visibleParents[0]
            if lanesAfter.contains(where: { $0.id != commitLane.id && $0.hash == firstParent }) {
                lanesAfter.remove(at: commitLaneIndex)
            } else {
                lanesAfter[commitLaneIndex] = GitActiveLane(id: commitLane.id, hash: firstParent, colorIndex: commitLane.colorIndex)
            }
            var insertionIndex = min(commitLaneIndex + 1, lanesAfter.count)
            for parentHash in visibleParents.dropFirst() {
                guard !lanesAfter.contains(where: { $0.hash == parentHash }) else { continue }
                lanesAfter.insert(makeLane(hash: parentHash), at: insertionIndex)
                insertionIndex += 1
            }
        }

        let continuingSegments = lanesBefore.compactMap { lane -> GitLaneSegment? in
            guard lane.id != commitLane.id,
                  let fromLane = lanesBefore.firstIndex(of: lane),
                  let toLane = lanesAfter.firstIndex(of: lane) else { return nil }
            return GitLaneSegment(startLane: fromLane, endLane: toLane, startAnchor: .top, endAnchor: .bottom, colorIndex: lane.colorIndex)
        }

        if commitWasAlreadyTracked {
            commitSegments.append(GitLaneSegment(startLane: commitLaneIndex, endLane: commitLaneIndex, startAnchor: .top, endAnchor: .center, colorIndex: commitLane.colorIndex))
        }
        for parentHash in visibleParents {
            guard let targetLane = lanesAfter.first(where: { $0.hash == parentHash }),
                  let targetLaneIndex = lanesAfter.firstIndex(of: targetLane) else { continue }
            commitSegments.append(GitLaneSegment(startLane: commitLaneIndex, endLane: targetLaneIndex, startAnchor: .center, endAnchor: .bottom, colorIndex: targetLane.colorIndex))
        }

        rows.append(GitGraphRow(
            id: index, shortHash: commit.shortHash, references: commit.references,
            pillGroups: buildPillGroups(from: commit.references, colorIndex: commitLane.colorIndex),
            subject: commit.subject, commitLane: commitLaneIndex, commitColorIndex: commitLane.colorIndex,
            isCurrentCommit: commit.references.contains(where: { $0.kind == .head }),
            isMergeCommit: commit.parentHashes.count > 1,
            segments: continuingSegments + commitSegments
        ))
        activeLanes = lanesAfter
    }

    let graphColumnCount = max(rows.map(\.maxLaneIndex).max() ?? 0, 0) + 1
    return GitRowBuildState(rows: rows, graphColumnCount: graphColumnCount)
}

// MARK: - Reference + working tree parsers

private func parseReferences(_ decorations: String, remoteNames: Set<String>) -> [GitReference] {
    guard !decorations.isEmpty else { return [] }
    return decorations.split(separator: ",").compactMap { part in
        let label = part.trimmingCharacters(in: .whitespaces)
        if label.isEmpty { return nil }
        if label.hasPrefix("HEAD -> ") { return GitReference(label: label, kind: .head) }
        if label.hasPrefix("tag: ") { return GitReference(label: String(label.dropFirst(5)), kind: .tag) }
        let firstComponent = label.split(separator: "/", maxSplits: 1).first.map(String.init) ?? label
        if remoteNames.contains(firstComponent) { return GitReference(label: label, kind: .remoteBranch) }
        return GitReference(label: label, kind: .localBranch)
    }
}

private func parseWorkingTreeEntries(from output: String) -> [GitWorkingTreeEntry] {
    output.split(whereSeparator: \.isNewline).compactMap { line -> GitWorkingTreeEntry? in
        guard line.count >= 4 else { return nil }
        let xy = String(line.prefix(2))
        let rawPath = String(line.dropFirst(3))
        let path = rawPath.range(of: " -> ").map { String(rawPath[$0.upperBound...]) } ?? rawPath
        let status: GitWorkingTreeStatus
        if xy == "??" { status = .untracked }
        else if xy.contains("M") { status = .modified }
        else if xy.contains("A") { status = .added }
        else if xy.contains("D") { status = .deleted }
        else if xy.contains("R") { status = .renamed }
        else if xy.contains("C") { status = .copied }
        else if xy == "UU" || xy == "AA" || xy == "DD" { status = .conflicted }
        else { status = .modified }
        return GitWorkingTreeEntry(path: path, status: status)
    }
}

private func buildPillGroups(from references: [GitReference], colorIndex: Int) -> [GitBranchPillGroup] {
    var local: [String] = []
    var localSet: Set<String> = []
    var remotes: [String: String] = [:]
    var tags: [String] = []
    var headTarget: String?

    for ref in references {
        if ref.kind == .remoteBranch && ref.label.hasSuffix("/HEAD") { continue }
        switch ref.kind {
        case .head: headTarget = ref.label.replacingOccurrences(of: "HEAD -> ", with: "")
        case .localBranch:
            if !localSet.contains(ref.label) { local.append(ref.label); localSet.insert(ref.label) }
        case .remoteBranch:
            if let slash = ref.label.firstIndex(of: "/") {
                remotes[String(ref.label[ref.label.index(after: slash)...])] = String(ref.label[..<slash])
            } else { remotes[ref.label] = "origin" }
        case .tag: tags.append(ref.label)
        case .other: break
        }
    }

    var groups: [GitBranchPillGroup] = []
    if let headTarget {
        groups.append(GitBranchPillGroup(primaryLabel: "HEAD -> \(headTarget)", remoteSegment: nil, isHead: true, colorIndex: colorIndex, showsBranchIcon: true))
        if localSet.contains(headTarget) { local.removeAll { $0 == headTarget } }
    }
    for branch in local {
        groups.append(GitBranchPillGroup(primaryLabel: branch, remoteSegment: remotes.removeValue(forKey: branch), isHead: false, colorIndex: colorIndex, showsBranchIcon: true))
    }
    for (_, remote) in remotes {
        groups.append(GitBranchPillGroup(primaryLabel: remote, remoteSegment: nil, isHead: false, colorIndex: colorIndex, showsBranchIcon: true))
    }
    for tag in tags {
        groups.append(GitBranchPillGroup(primaryLabel: tag, remoteSegment: nil, isHead: false, colorIndex: colorIndex, showsBranchIcon: false))
    }
    return groups
}

