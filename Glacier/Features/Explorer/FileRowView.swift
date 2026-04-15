// FileRowView.swift
// A single row in the file explorer tree, recursive for folders.
// Supports right-click context menu and drag-and-drop reordering/moving.

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Draggable file URL

struct DraggedFileURL: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .glacierFileURL)
    }
}

extension UTType {
    static let glacierFileURL = UTType(exportedAs: "com.glacier.fileurl")
}

extension DraggedFileURL: Codable {
    enum CodingKeys: String, CodingKey { case path }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = URL(fileURLWithPath: try c.decode(String.self, forKey: .path))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url.path, forKey: .path)
    }
}

// MARK: - File Row View

struct FileRowView: View {
    @ObservedObject var item: FileItem
    let depth: Int

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var showRenameSheet = false
    @State private var showNewFileSheet = false
    @State private var showNewFolderSheet = false
    @State private var showDeleteConfirm = false
    @State private var isDropTarget = false

    private var isSelected: Bool {
        appState.isExplorerItemSelected(item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { handleDoubleClick() }
                .onTapGesture { handleSingleClick() }
                .background(rowBackground)
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.name)
                .accessibilityIdentifier("file-\(item.name)")
                .accessibilityAddTraits(.isButton)
                .contextMenu { contextMenuItems }
                // Drag source
                .draggable(DraggedFileURL(url: item.url))
                // Drop target — accept drags onto any row; folders get highlighted
                .dropDestination(for: DraggedFileURL.self) { items, _ in
                    guard let dragged = items.first else { return false }
                    let dest = item.isDirectory ? item.url : item.url.deletingLastPathComponent()
                    // Don't drop onto own parent (no-op move)
                    guard dragged.url.deletingLastPathComponent() != dest else { return false }
                    try? appState.fileService.move(from: dragged.url, into: dest)
                    return true
                } isTargeted: { targeted in
                    isDropTarget = targeted
                }

            // Expanded children
            if item.isExpanded, let children = item.children {
                ForEach(children) { child in
                    FileRowView(item: child, depth: depth + 1)
                }
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSheet(item: item) { newName in
                try appState.fileService.rename(item: item, to: newName)
            }
        }
        .sheet(isPresented: $showNewFileSheet) {
            CreateItemSheet(
                title: "New File",
                placeholder: "filename.txt",
                directory: item.isDirectory ? item.url : item.url.deletingLastPathComponent()
            ) { name in
                let dir = item.isDirectory ? item.url : item.url.deletingLastPathComponent()
                try appState.fileService.createFile(named: name, in: dir)
                appState.fileService.reload()
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            CreateItemSheet(
                title: "New Folder",
                placeholder: "folder-name",
                directory: item.isDirectory ? item.url : item.url.deletingLastPathComponent()
            ) { name in
                let dir = item.isDirectory ? item.url : item.url.deletingLastPathComponent()
                try appState.fileService.createFolder(named: name, in: dir)
                appState.fileService.reload()
            }
        }
        .confirmationDialog(
            "Move \"\(item.name)\" to Trash?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                try? appState.fileService.trash(item: item)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: theme.radius.small)
            .fill(
                isDropTarget
                    ? theme.colors.accent.opacity(0.18)
                    : (isSelected ? theme.colors.selectionBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.small)
                    .strokeBorder(
                        isDropTarget ? theme.colors.accent.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
    }

    // MARK: - Row Content

    private var rowContent: some View {
        HStack(spacing: 4) {
            Spacer()
                .frame(width: CGFloat(depth) * theme.spacing.indentWidth)

            if item.isDirectory {
                Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }

            Image(systemName: item.icon)
                .font(.system(size: theme.spacing.iconSize - 2))
                .foregroundStyle(item.iconColor)
                .frame(width: theme.spacing.iconSize)

            Text(item.name)
                .font(theme.typography.sidebarItemFont)
                .foregroundStyle(theme.colors.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(theme.spacing.itemPadding)
        .frame(height: 24)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if !item.isDirectory {
            Button {
                appState.openFile(item)
            } label: {
                Label("Open", systemImage: "doc")
            }
            Divider()
        }

        Button {
            showNewFileSheet = true
        } label: {
            Label("New File", systemImage: "doc.badge.plus")
        }

        Button {
            showNewFolderSheet = true
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }

        Divider()

        Button {
            showRenameSheet = true
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } label: {
            Label("Reveal in Finder", systemImage: "finder")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.clipboard")
        }

        Divider()

        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    // MARK: - Tap

    private func handleSingleClick() {
        let modifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags.contains(.shift) {
            appState.selectExplorerItem(item, extendingRange: true)
            return
        }

        appState.selectExplorerItem(item)
        if item.isDirectory {
            withAnimation(GlacierTheme().animation.fast) {
                appState.fileService.toggleExpansion(of: item)
            }
        } else {
            appState.previewFile(item)
        }
    }

    private func handleDoubleClick() {
        appState.selectExplorerItem(item)
        guard !item.isDirectory else {
            return
        }

        appState.openFile(item)
    }
}
