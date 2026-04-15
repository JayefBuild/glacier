// WorkspaceSwitcherView.swift
// Bottom-of-sidebar workspace picker — shows recent folders, switch or open in new tab.

import SwiftUI
import AppKit

struct WorkspaceSwitcherView: View {
    @ObservedObject var fileService: FileService
    @ObservedObject private var store = WorkspaceStore.shared
    @Environment(\.appTheme) private var theme

    @State private var showPopover = false

    private var currentName: String {
        fileService.rootURL?.lastPathComponent ?? "Open Folder…"
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(fileService.rootURL != nil ? theme.colors.accent : .secondary)

                Text(currentName)
                    .font(theme.typography.captionFont)
                    .fontWeight(.medium)
                    .foregroundStyle(fileService.rootURL != nil ? theme.colors.primaryText : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glacierGlassSurface(
            theme: theme,
            cornerRadius: theme.radius.medium,
            shadowRadius: 10,
            shadowY: 4
        )
        .padding(8)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            WorkspacePickerPopover(fileService: fileService, store: store, isPresented: $showPopover)
        }
    }
}

// MARK: - Popover

private struct WorkspacePickerPopover: View {
    @ObservedObject var fileService: FileService
    @ObservedObject var store: WorkspaceStore
    @Binding var isPresented: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Workspaces")
                .font(theme.typography.captionFont)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Divider()

            if store.recents.isEmpty {
                Text("No recent workspaces")
                    .font(theme.typography.captionFont)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.recents) { workspace in
                            WorkspaceRow(
                                workspace: workspace,
                                isCurrent: fileService.rootURL == workspace.url,
                                onSelect: {
                                    fileService.openFolder(at: workspace.url)
                                    isPresented = false
                                },
                                onOpenInNewTab: {
                                    openInNewTab(url: workspace.url)
                                    isPresented = false
                                },
                                onRemove: {
                                    store.remove(workspace)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            Divider()

            Button {
                isPresented = false
                openFolderPanel { url in
                    fileService.openFolder(at: url)
                }
            } label: {
                Label("Open Folder…", systemImage: "folder.badge.plus")
                    .font(theme.typography.captionFont)
                    .foregroundStyle(theme.colors.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 260)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    LinearGradient(
                        colors: [
                            theme.colors.sidebarBackground.opacity(0.94),
                            theme.colors.windowBackground.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
    }

    // Opens a workspace URL as a new tab in the current window
    private func openInNewTab(url: URL) {
        guard let currentWindow = NSApp.keyWindow else { return }

        // Queue the URL so the new ContentView picks it up on appear
        WorkspaceStore.shared.pendingOpenURL = url

        // Open a new window via SwiftUI's WindowGroup mechanism
        NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: NSApp)

        // After a short delay the new window exists — grab it and merge into current
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let newWindow = NSApp.windows.filter({ $0 !== currentWindow && $0.isVisible }).last else { return }
            currentWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Workspace Row

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isCurrent: Bool
    let onSelect: () -> Void
    let onOpenInNewTab: () -> Void
    let onRemove: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.colors.accent)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(theme.typography.captionFont)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(theme.colors.primaryText)
                    .lineLimit(1)

                Text(workspace.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Open in new tab button
            Button {
                onOpenInNewTab()
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .help("Open in New Tab")

            // Remove button
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Group {
                if isCurrent {
                    theme.colors.selectionBackground.opacity(0.92)
                } else if isHovered {
                    theme.colors.hoverBackground.opacity(0.9)
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }
}
