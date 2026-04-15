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
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ExplorerHeaderView(fileService: fileService)
            Divider()
            if fileService.rootURL == nil {
                ExplorerEmptyState(fileService: fileService)
            } else {
                ExplorerTreeView(fileService: fileService)
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
    }
}

// MARK: - Header + Toolbar

private struct ExplorerHeaderView: View {
    @ObservedObject var fileService: FileService
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var title: String {
        fileService.rootURL?.lastPathComponent ?? "No Folder"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Folder name row
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(theme.typography.captionFont)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Toolbar
            if fileService.rootURL != nil {
                ExplorerToolbar(fileService: fileService)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Toolbar

private struct ExplorerToolbar: View {
    @ObservedObject var fileService: FileService
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
                fileService.rootURL = nil
                fileService.rootItems = []
            }
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showNewFileSheet) {
            CreateItemSheet(
                title: "New File",
                placeholder: "filename.txt",
                directory: fileService.rootURL ?? URL(fileURLWithPath: NSHomeDirectory())
            ) { name in
                try fileService.createFile(named: name, in: fileService.rootURL!)
                fileService.reload()
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            CreateItemSheet(
                title: "New Folder",
                placeholder: "folder-name",
                directory: fileService.rootURL ?? URL(fileURLWithPath: NSHomeDirectory())
            ) { name in
                try fileService.createFolder(named: name, in: fileService.rootURL!)
                fileService.reload()
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
        // Expand parents if needed — simple: just reload selection highlight
        // Full path reveal would require parent tracking; this highlights the item
    }
}

// MARK: - Empty State

private struct ExplorerEmptyState: View {
    @ObservedObject var fileService: FileService
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("Open a Folder")
                .font(theme.typography.labelFont)
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

// MARK: - Tree

private struct ExplorerTreeView: View {
    @ObservedObject var fileService: FileService
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(fileService.rootItems) { item in
                    FileRowView(item: item, depth: 0)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Create Item Sheet

struct CreateItemSheet: View {
    let title: String
    let placeholder: String
    let directory: URL
    let onCreate: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var name: String = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

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
                GitGraphContentView(snapshot: snapshot) {
                    Task {
                        await model.load(for: workspaceURL)
                    }
                }
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
}

private struct GitGraphContentView: View {
    let snapshot: GitGraphSnapshot
    let onRefresh: () -> Void

    @Environment(\.appTheme) private var theme

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

            if snapshot.rows.isEmpty {
                GitSidebarMessageView(
                    icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    title: "No Commits Yet",
                    message: "This repository exists, but it does not have any commits yet."
                )
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.rows) { row in
                            GitGraphRowView(
                                row: row,
                                graphColumnCount: snapshot.graphColumnCount
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: true, vertical: false)
                }
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
        let laneTint = GitGraphPalette.color(row.commitColorIndex, theme: theme)

        HStack(alignment: .center, spacing: 10) {
            GitLaneGraphView(
                row: row,
                graphColumnCount: graphColumnCount,
                isCurrentCommit: row.isCurrentCommit
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.shortHash)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.colors.secondaryText)

                    if !row.references.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(row.references.prefix(3)), id: \.self) { reference in
                                GitReferenceChip(reference: reference, tint: laneTint)
                            }

                            if row.references.count > 3 {
                                GitReferenceChip(
                                    reference: GitReference(label: "+\(row.references.count - 3)", kind: .other),
                                    tint: laneTint
                                )
                            }
                        }
                    }
                }

                Text(row.subject)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.colors.primaryText)
                    .lineLimit(1)
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

    private let laneSpacing: CGFloat = 14

    private var palette: [Color] {
        GitGraphPalette.colors(for: theme)
    }

    private var graphWidth: CGFloat {
        let columns = max(graphColumnCount, 1)
        return CGFloat(columns) * laneSpacing + 12
    }

    private var graphHeight: CGFloat {
        28
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let centerY = size.height / 2
            let topY: CGFloat = 2
            let bottomY = size.height - 2
            let strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)

            for segment in row.segments {
                let start = point(for: segment.startLane, anchor: segment.startAnchor, topY: topY, centerY: centerY, bottomY: bottomY)
                let end = point(for: segment.endLane, anchor: segment.endAnchor, topY: topY, centerY: centerY, bottomY: bottomY)
                let color = palette[segment.colorIndex % palette.count]

                var path = Path()
                path.move(to: start)
                if segment.startLane == segment.endLane {
                    path.addLine(to: end)
                } else {
                    let bend = abs(end.y - start.y) * 0.78
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: min(start.y + bend, bottomY)),
                        control2: CGPoint(x: end.x, y: max(end.y - bend, topY))
                    )
                }

                context.stroke(path, with: .color(color), style: strokeStyle)
            }

            let commitColor = palette[row.commitColorIndex % palette.count]
            let commitX = xPosition(for: row.commitLane)
            let commitRect = CGRect(x: commitX - 4.5, y: centerY - 4.5, width: 9, height: 9)
            let commitPath = Path(ellipseIn: commitRect)
            if isCurrentCommit {
                context.fill(commitPath, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(commitPath, with: .color(commitColor), style: StrokeStyle(lineWidth: 2.2))
            } else {
                context.fill(commitPath, with: .color(commitColor))
                context.stroke(commitPath, with: .color(Color.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1))
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

private struct GitReferenceChip: View {
    let reference: GitReference
    let tint: Color

    @Environment(\.appTheme) private var theme

    private var foreground: Color {
        Color.white
    }

    var body: some View {
        Text(reference.label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(reference.kind == .other ? tint.opacity(0.72) : tint)
            .clipShape(Capsule())
    }
}

private struct GitSidebarMessageView: View {
    let icon: String
    let title: String
    let message: String

    @Environment(\.appTheme) private var theme

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private enum GitGraphLoadResult: Sendable {
    case notGit(workspaceName: String)
    case ready(GitGraphSnapshot)
    case failed(String)
}

private struct GitGraphSnapshot: Sendable {
    let repoName: String
    let repoPath: String
    let currentRef: String
    let statusLine: String?
    let branchNames: [String]
    let rows: [GitGraphRow]
    let graphColumnCount: Int
}

private struct GitGraphRow: Identifiable, Sendable {
    let id: Int
    let shortHash: String
    let references: [GitReference]
    let subject: String
    let commitLane: Int
    let commitColorIndex: Int
    let isCurrentCommit: Bool
    let segments: [GitLaneSegment]

    var maxLaneIndex: Int {
        max(
            commitLane,
            segments.flatMap { [$0.startLane, $0.endLane] }.max() ?? 0
        )
    }
}

private struct GitReference: Hashable, Sendable {
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

private enum GitLaneAnchor: Hashable, Sendable {
    case top
    case center
    case bottom
}

private struct GitLaneSegment: Hashable, Sendable {
    let startLane: Int
    let endLane: Int
    let startAnchor: GitLaneAnchor
    let endAnchor: GitLaneAnchor
    let colorIndex: Int
}

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

private enum GitGraphLoader {
    static func load(from workspaceURL: URL) -> GitGraphLoadResult {
        let repoRootResult = runGit(arguments: ["-C", workspaceURL.path, "rev-parse", "--show-toplevel"])
        guard repoRootResult.exitCode == 0 else {
            return .notGit(workspaceName: workspaceURL.lastPathComponent)
        }

        let repoRoot = repoRootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else {
            return .notGit(workspaceName: workspaceURL.lastPathComponent)
        }

        let currentRef =
            runGit(arguments: ["-C", repoRoot, "symbolic-ref", "--quiet", "--short", "HEAD"])
                .stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let detachedHead =
            runGit(arguments: ["-C", repoRoot, "rev-parse", "--short", "HEAD"])
                .stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)

        let statusOutput = runGit(arguments: ["-C", repoRoot, "status", "--short", "--branch"])
        let statusLine = statusOutput.stdout
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .replacingOccurrences(of: "## ", with: "")

        let branchesOutput = runGit(arguments: [
            "-C", repoRoot,
            "for-each-ref",
            "--format=%(refname:short)",
            "--sort=-committerdate",
            "refs/heads",
            "refs/remotes"
        ])
        let branchNames = branchesOutput.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.isEmpty }

        let hasCommits = runGit(arguments: ["-C", repoRoot, "rev-parse", "--verify", "HEAD"]).exitCode == 0
        let rowState: GitRowBuildState
        if hasCommits {
            let commitOutput = runGit(arguments: [
                "-C", repoRoot,
                "log",
                "--topo-order",
                "--decorate=short",
                "--pretty=format:%h%x1f%H%x1f%P%x1f%D%x1f%s",
                "--all",
                "-n", "160",
                "--color=never"
            ])
            if commitOutput.exitCode != 0 {
                return .failed(commitOutput.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            rowState = buildRows(from: parseCommits(from: commitOutput.stdout))
        } else {
            rowState = GitRowBuildState(rows: [], graphColumnCount: 0)
        }

        let repoURL = URL(fileURLWithPath: repoRoot)
        return .ready(
            GitGraphSnapshot(
                repoName: repoURL.lastPathComponent,
                repoPath: displayPath(for: repoURL),
                currentRef: currentRef.isEmpty ? (detachedHead.isEmpty ? "HEAD" : detachedHead) : currentRef,
                statusLine: statusLine,
                branchNames: branchNames,
                rows: rowState.rows,
                graphColumnCount: rowState.graphColumnCount
            )
        )
    }

    private static func runGit(arguments: [String]) -> GitCommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return GitCommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return GitCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private static func displayPath(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func parseCommits(from output: String) -> [GitGraphCommitRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else {
                return nil
            }

            return GitGraphCommitRecord(
                shortHash: fields[0],
                fullHash: fields[1],
                parentHashes: fields[2].split(separator: " ").map(String.init),
                references: parseReferences(fields[3]),
                subject: fields[4]
            )
        }
    }

    private static func buildRows(from commits: [GitGraphCommitRecord]) -> GitRowBuildState {
        let visibleHashes = Set(commits.map(\.fullHash))
        var rows: [GitGraphRow] = []
        var activeLanes: [GitActiveLane] = []
        var nextLaneIdentifier = 0
        var nextColorIndex = 0

        func makeLane(hash: String, colorIndex: Int? = nil) -> GitActiveLane {
            defer { nextLaneIdentifier += 1 }
            let lane = GitActiveLane(
                id: nextLaneIdentifier,
                hash: hash,
                colorIndex: colorIndex ?? nextColorIndex
            )
            if colorIndex == nil {
                nextColorIndex += 1
            }
            return lane
        }

        for (index, commit) in commits.enumerated() {
            let commitWasAlreadyTracked = activeLanes.contains(where: { $0.hash == commit.fullHash })
            if !commitWasAlreadyTracked {
                activeLanes.append(makeLane(hash: commit.fullHash))
            }

            let lanesBefore = activeLanes
            guard let commitLaneIndex = lanesBefore.firstIndex(where: { $0.hash == commit.fullHash }) else {
                continue
            }
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
                    lanesAfter[commitLaneIndex] = GitActiveLane(
                        id: commitLane.id,
                        hash: firstParent,
                        colorIndex: commitLane.colorIndex
                    )
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
                      let toLane = lanesAfter.firstIndex(of: lane) else {
                    return nil
                }

                return GitLaneSegment(
                    startLane: fromLane,
                    endLane: toLane,
                    startAnchor: .top,
                    endAnchor: .bottom,
                    colorIndex: lane.colorIndex
                )
            }

            if commitWasAlreadyTracked {
                commitSegments.append(
                    GitLaneSegment(
                        startLane: commitLaneIndex,
                        endLane: commitLaneIndex,
                        startAnchor: .top,
                        endAnchor: .center,
                        colorIndex: commitLane.colorIndex
                    )
                )
            }

            for parentHash in visibleParents {
                guard let targetLane = lanesAfter.first(where: { $0.hash == parentHash }),
                      let targetLaneIndex = lanesAfter.firstIndex(of: targetLane) else {
                    continue
                }

                commitSegments.append(
                    GitLaneSegment(
                        startLane: commitLaneIndex,
                        endLane: targetLaneIndex,
                        startAnchor: .center,
                        endAnchor: .bottom,
                        colorIndex: targetLane.colorIndex
                    )
                )
            }

            rows.append(
                GitGraphRow(
                    id: index,
                    shortHash: commit.shortHash,
                    references: commit.references,
                    subject: commit.subject,
                    commitLane: commitLaneIndex,
                    commitColorIndex: commitLane.colorIndex,
                    isCurrentCommit: commit.references.contains(where: { $0.kind == .head }),
                    segments: continuingSegments + commitSegments
                )
            )

            activeLanes = lanesAfter
        }

        let graphColumnCount = max(rows.map(\.maxLaneIndex).max() ?? 0, 0) + 1
        return GitRowBuildState(rows: rows, graphColumnCount: graphColumnCount)
    }

    private static func parseReferences(_ decorations: String) -> [GitReference] {
        decorations
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { label in
                let kind: GitReference.Kind
                if label.hasPrefix("HEAD -> ") {
                    kind = .head
                } else if label.hasPrefix("tag: ") {
                    kind = .tag
                } else if label.hasPrefix("origin/") {
                    kind = .remoteBranch
                } else if label.contains("/") {
                    kind = .remoteBranch
                } else {
                    kind = .localBranch
                }

                return GitReference(
                    label: label.replacingOccurrences(of: "tag: ", with: ""),
                    kind: kind
                )
            }
    }
}

private struct GitCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
