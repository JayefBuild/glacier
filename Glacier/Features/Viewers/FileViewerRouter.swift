// FileViewerRouter.swift
// Routes a Tab to the appropriate viewer based on its kind.

import SwiftUI

struct FileViewerRouter: View {
    let tab: Tab?
    let previewItem: FileItem?
    let pane: EditorPane
    let isFocused: Bool
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let previewItem {
            FileContentView(
                item: previewItem,
                editorFontSize: appState.editorFontSize,
                fileService: appState.fileService
            )
        } else if let tab {
            switch tab.kind {
            case .file(let item):
                FileContentView(
                    item: item,
                    editorFontSize: appState.editorFontSize,
                    fileService: appState.fileService
                )
            case .terminal(let terminal):
                TerminalTabView(
                    terminal: terminal,
                    isFocused: isFocused,
                    onSessionInteraction: { sessionID in
                        appState.focusTerminalSession(sessionID, in: pane)
                    },
                    onSessionCommand: { sessionID, command in
                        appState.handleTerminalCommand(command, sessionID: sessionID, in: pane)
                    }
                )
            case .gitGraph:
                GitGraphView(fileService: appState.fileService)
            }
        } else {
            EmptyView()
        }
    }
}

// MARK: - File Content View (async load)

private struct FileContentView: View {
    let item: FileItem
    let editorFontSize: CGFloat
    let fileService: FileService

    @Environment(\.appTheme) private var theme

    @State private var content: FileContent = .empty
    @State private var editableText: String = ""
    @State private var editableExt: String = ""
    @State private var editableExcalidraw: String = "{}"
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(theme.typography.captionFont)
                        .foregroundStyle(.tertiary)
                }
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(theme.typography.labelFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                viewerForContent(content)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.url) {
            await loadContent()
        }
    }

    @ViewBuilder
    private func viewerForContent(_ content: FileContent) -> some View {
        switch content {
        case .text(_, let ext):
            if FileTypeRegistry.kind(for: ext) == .markdown {
                MarkdownEditorView(
                    text: $editableText,
                    url: item.url,
                    fontSize: editorFontSize,
                    fileService: fileService
                )
            } else {
                TextEditorView(
                    text: $editableText,
                    fileExtension: ext,
                    url: item.url,
                    fontSize: editorFontSize,
                    fileService: fileService
                )
            }
        case .markwhen(_, let url):
            MarkwhenViewer(
                text: $editableText,
                url: url,
                fontSize: editorFontSize,
                fileService: fileService
            )
        case .excalidraw(_, let url):
            ExcalidrawViewer(text: $editableExcalidraw, url: url, fileService: fileService)
        case .image(let url):
            ImageViewerView(url: url)
        case .video(let url):
            VideoViewerView(url: url)
        case .audio(let url):
            AudioViewerView(url: url)
        case .pdf(let url):
            PDFViewerView(url: url)
        case .binary(let url):
            BinaryInfoView(url: url)
        case .empty:
            EmptyView()
        }
    }

    private func loadContent() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await fileService.readFile(at: item.url)
            content = loaded
            if case .text(let text, let ext) = loaded {
                editableText = text
                editableExt = ext
            }
            if case .markwhen(let text, _) = loaded {
                editableText = text
            }
            if case .excalidraw(let text, _) = loaded {
                editableExcalidraw = text
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
