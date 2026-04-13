// FileViewerRouter.swift
// Routes a Tab to the appropriate viewer based on its kind.

import SwiftUI

struct FileViewerRouter: View {
    let tab: Tab
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch tab.kind {
        case .file(let item):
            FileContentView(item: item, tab: tab)
        case .terminal(let session):
            TerminalView(session: session)
        }
    }
}

// MARK: - File Content View (async load)

private struct FileContentView: View {
    let item: FileItem
    let tab: Tab

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @State private var content: FileContent = .empty
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
        case .text(let text, let ext):
            TextEditorView(text: text, fileExtension: ext, url: item.url, fontSize: appState.editorFontSize)
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
            content = try await appState.fileService.readFile(at: item.url)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
