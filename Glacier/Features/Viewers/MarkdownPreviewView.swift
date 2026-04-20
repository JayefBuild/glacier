// MarkdownPreviewView.swift
// Source + live preview split for .md files using MarkdownUI for rendering.

import SwiftUI
import Combine
import MarkdownUI

struct MarkdownEditorView: View {
    @Binding var text: String
    let url: URL
    var fontSize: CGFloat = 16
    let fileService: FileService

    @Environment(\.appTheme) private var theme

    @State private var mode: MarkdownEditorMode = .split
    @State private var saveCancellable: AnyCancellable?

    private var lineCount: Int {
        guard !text.isEmpty else { return 1 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    private var documentDirectory: URL {
        url.deletingLastPathComponent()
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            Divider()

            Group {
                switch mode {
                case .preview:
                    previewPane
                case .source:
                    sourcePane
                case .split:
                    HSplitView {
                        sourcePane
                            .frame(minWidth: 240)
                        previewPane
                            .frame(minWidth: 240)
                    }
                }
            }
        }
        .background(theme.colors.editorBackground)
        .onChange(of: text) { _, newValue in
            scheduleSave(text: newValue)
        }
        .onDisappear {
            saveNow(text: text)
        }
        .onReceive(NotificationCenter.default.publisher(for: .glacierSaveDocument)) { notification in
            guard let request = notification.object as? EditorSaveRequest,
                  request.url == url else {
                return
            }
            saveNow(text: text)
            request.acknowledge()
        }
    }

    @ViewBuilder
    private var sourcePane: some View {
        MarkdownSourceTextView(
            text: $text,
            documentDirectory: documentDirectory,
            fontSize: fontSize,
            theme: theme
        )
        .background(theme.colors.editorBackground)
    }

    @ViewBuilder
    private var previewPane: some View {
        ScrollView {
            Markdown(text, baseURL: documentDirectory, imageBaseURL: documentDirectory)
                .markdownTheme(.gitHub)
                .markdownImageProvider(LocalFileImageProvider())
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(theme.colors.editorBackground)
    }

    private func scheduleSave(text: String) {
        saveCancellable?.cancel()
        saveCancellable = Just(text)
            .delay(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { value in
                saveNow(text: value)
            }
    }

    private func saveNow(text: String) {
        saveCancellable?.cancel()
        try? fileService.writeFile(text: text, to: url)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: FileTypeRegistry.icon(for: "md"))
                    .font(.system(size: 10))
                    .foregroundStyle(FileTypeRegistry.color(for: "md"))
                Text("Markdown")
                    .font(theme.typography.captionFont)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 12)

            Text("\(lineCount) lines")
                .font(theme.typography.captionFont)
                .foregroundStyle(.tertiary)

            Spacer()

            Picker("", selection: $mode) {
                ForEach(MarkdownEditorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(theme.colors.editorBackground)
    }
}

private enum MarkdownEditorMode: String, CaseIterable, Identifiable {
    case source
    case split
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: return "Source"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }
}
