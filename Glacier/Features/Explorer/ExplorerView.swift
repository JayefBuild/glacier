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

    var body: some View {
        HStack(spacing: 0) {
            stripButton(symbolName: "apple.terminal", help: "New Terminal Tab", action: onNewTerminal)

            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 18)

            stripButton(symbolName: "sidebar.left", help: "Toggle Sidebar", action: onToggleSidebar)
        }
        .frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
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
    @EnvironmentObject private var appState: AppState

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
        .background(.ultraThinMaterial)
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

    var body: some View {
        HStack(spacing: 2) {
            // New File
            toolbarButton(icon: "doc.badge.plus", help: "New File") {
                showNewFileSheet = true
            }

            // New Folder
            toolbarButton(icon: "folder.badge.plus", help: "New Folder") {
                showNewFolderSheet = true
            }

            // New Excalidraw Drawing
            toolbarButton(icon: "pencil.and.scribble", help: "New Excalidraw Drawing") {
                createExcalidrawDrawing()
            }

            // New Markwhen Timeline
            toolbarButton(icon: "calendar.badge.clock", help: "New Markwhen Timeline") {
                createMarkwhenFile()
            }

            // Collapse All
            toolbarButton(icon: "chevron.up.chevron.down", help: "Collapse All") {
                withAnimation(GlacierTheme().animation.fast) {
                    fileService.collapseAll()
                }
            }

            // Reveal Active File
            toolbarButton(icon: "arrow.triangle.turn.up.right.circle", help: "Reveal Active File in Sidebar") {
                revealActiveFile()
            }
            .disabled(appState.activeTab == nil)

            Spacer()

            // Close Folder
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

    private func toolbarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
        appState.selectedFileItem = item
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
