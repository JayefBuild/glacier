// MarkdownPreviewView.swift
// Rich Markdown editing for .md files, with source mode as an escape hatch.

import SwiftUI
import WebKit
import Combine
import MarkdownEditor

struct MarkdownEditorView: View {
    @Binding var text: String
    let url: URL
    let pane: EditorPane
    var fontSize: CGFloat = 16
    let fileService: FileService

    @Environment(\.appTheme) private var theme

    @State private var mode: MarkdownEditorMode = .rich
    @State private var saveCancellable: AnyCancellable?

    private var lineCount: Int {
        guard !text.isEmpty else { return 1 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    private var richDocument: MarkdownRichDocument {
        MarkdownRichDocument(markdown: text)
    }

    private var richBodyText: Binding<String> {
        Binding(
            get: { richDocument.bodyMarkdown },
            set: { newBody in
                text = (richDocument.frontmatterPrefix ?? "") + newBody
            }
        )
    }

    private var richEditorConfiguration: EditorConfiguration {
        EditorConfiguration(
            fontSize: fontSize,
            showLineNumbers: false,
            wrapLines: true,
            renderMermaid: true,
            renderMath: true,
            renderImages: true,
            hideSyntax: true
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            Divider()

            Group {
                switch mode {
                case .rich:
                    richEditor
                case .source:
                    SyntaxTextView(
                        text: $text,
                        fileExtension: "md",
                        showLineNumbers: false,
                        fontSize: fontSize,
                        theme: theme
                    )
                }
            }
        }
        .background(theme.colors.editorBackground)
        .onChange(of: text) { _, newValue in
            scheduleSave(text: newValue)
        }
        .onDisappear {
            saveCancellable?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .glacierSaveDocument)) { notification in
            guard let request = notification.object as? EditorSaveRequest,
                  request.pane == pane,
                  request.url == url else {
                return
            }
            saveNow(text: text)
        }
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
        Task { @MainActor in
            try? fileService.writeFile(text: text, to: url)
        }
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
            .frame(width: 140)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(theme.colors.editorBackground)
    }

    @ViewBuilder
    private var richEditor: some View {
        VStack(spacing: 0) {
            if !richDocument.properties.isEmpty {
                MarkdownFrontmatterPanel(properties: richDocument.properties)
                Divider()
            }

            EditorWebView(
                text: richBodyText,
                configuration: richEditorConfiguration
            )
            .background(theme.colors.editorBackground)
        }
    }
}

private enum MarkdownEditorMode: String, CaseIterable, Identifiable {
    case rich
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rich: return "Rich"
        case .source: return "Source"
        }
    }
}

private struct MarkdownFrontmatterPanel: View {
    let properties: [MarkdownFrontmatterProperty]

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Properties")
                .font(theme.typography.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(properties.enumerated()), id: \.offset) { _, property in
                    HStack(alignment: .top, spacing: 12) {
                        Text(property.name)
                            .font(theme.typography.captionFont.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)

                        Text(property.value)
                            .font(theme.typography.captionFont)
                            .foregroundStyle(theme.colors.primaryText)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(theme.colors.editorBackground.opacity(0.82))
    }
}

private struct MarkdownLiveEditorWebView: NSViewRepresentable {
    @Binding var text: String
    let url: URL
    let saveRequestCount: Int
    let fontSize: CGFloat
    let document: MarkdownRichDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, url: url, frontmatterPrefix: document.frontmatterPrefix)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: "glacierSave")
        config.userContentController.add(context.coordinator, name: "glacierReady")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        webView.loadHTMLString(
            buildHTML(
                bodyMarkdown: document.bodyMarkdown,
                frontmatter: document.properties,
                fontSize: fontSize
            ),
            baseURL: nil
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let script = "window.glacierSetFontSize && window.glacierSetFontSize(\(fontSize));"
        webView.evaluateJavaScript(script, completionHandler: nil)

        if context.coordinator.lastSaveRequestCount != saveRequestCount {
            context.coordinator.lastSaveRequestCount = saveRequestCount
            webView.evaluateJavaScript("window.glacierForceSave && window.glacierForceSave();", completionHandler: nil)
        }
    }

    private func buildHTML(
        bodyMarkdown: String,
        frontmatter: [MarkdownFrontmatterProperty],
        fontSize: CGFloat
    ) -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let fg = isDark ? "#e8e8ed" : "#1c1c1e"
        let bg = isDark ? "#1c1c1e" : "#ffffff"
        let panel = isDark ? "#232326" : "#fafaf8"
        let codeBg = isDark ? "#2c2c2e" : "#f2f2f7"
        let border = isDark ? "#3a3a3c" : "#d9d9de"
        let link = isDark ? "#78b8ff" : "#0a66d8"
        let muted = isDark ? "#9a9aa0" : "#6e6e73"
        let selection = isDark ? "rgba(120, 184, 255, 0.16)" : "rgba(10, 102, 216, 0.12)"
        let baseCSS = "https://uicdn.toast.com/editor/3.2.2/toastui-editor.min.css"
        let themeCSS = isDark
            ? #"<link rel="stylesheet" href="https://uicdn.toast.com/editor/3.2.2/theme/toastui-editor-dark.min.css">"#
            : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="\(baseCSS)">
        \(themeCSS)
        <style>
          :root {
            --editor-font-size: \(fontSize)px;
            --editor-fg: \(fg);
            --editor-bg: \(bg);
            --editor-panel: \(panel);
            --editor-code-bg: \(codeBg);
            --editor-border: \(border);
            --editor-link: \(link);
            --editor-muted: \(muted);
            --editor-selection: \(selection);
          }
          * { box-sizing: border-box; }
          html, body {
            margin: 0;
            height: 100%;
            overflow: hidden;
            background: var(--editor-bg);
            color: var(--editor-fg);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          }
          body {
            font-size: var(--editor-font-size);
          }
          #loading {
            display: flex;
            align-items: center;
            justify-content: center;
            height: 100%;
            color: var(--editor-muted);
            font-size: 13px;
          }
          #editor-shell {
            display: none;
            height: 100%;
            background: var(--editor-bg);
            flex-direction: column;
          }
          #frontmatter {
            display: none;
            max-width: 820px;
            width: 100%;
            margin: 0 auto;
            padding: 24px 36px 10px;
          }
          #frontmatter.has-properties {
            display: block;
          }
          .glacier-frontmatter-header {
            display: flex;
            align-items: center;
            gap: 8px;
            margin-bottom: 10px;
            color: var(--editor-muted);
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.08em;
            text-transform: uppercase;
          }
          .glacier-frontmatter-header::before {
            content: '';
            width: 14px;
            height: 14px;
            border-radius: 4px;
            background:
              linear-gradient(var(--editor-muted), var(--editor-muted)) 3px 3px / 8px 1.5px no-repeat,
              linear-gradient(var(--editor-muted), var(--editor-muted)) 3px 6.3px / 8px 1.5px no-repeat,
              linear-gradient(var(--editor-muted), var(--editor-muted)) 3px 9.6px / 8px 1.5px no-repeat,
              color-mix(in srgb, var(--editor-panel) 80%, transparent);
            border: 1px solid color-mix(in srgb, var(--editor-border) 92%, transparent);
          }
          .glacier-frontmatter-list {
            display: flex;
            flex-direction: column;
          }
          .glacier-frontmatter-row {
            display: grid;
            grid-template-columns: minmax(120px, 180px) minmax(0, 1fr);
            gap: 14px;
            align-items: start;
            padding: 10px 0;
            border-bottom: 1px solid color-mix(in srgb, var(--editor-border) 88%, transparent);
          }
          .glacier-frontmatter-row:first-child {
            border-top: 1px solid color-mix(in srgb, var(--editor-border) 88%, transparent);
          }
          .glacier-frontmatter-name {
            color: var(--editor-muted);
            font-size: 13px;
            font-weight: 600;
            line-height: 1.45;
          }
          .glacier-frontmatter-value {
            color: var(--editor-fg);
            font-size: 14px;
            line-height: 1.55;
            white-space: pre-wrap;
            word-break: break-word;
          }
          #editor {
            height: 100%;
            min-height: 0;
            flex: 1;
          }
          .toastui-editor-defaultUI {
            border: 0 !important;
            border-radius: 0 !important;
            background: transparent !important;
          }
          .toastui-editor-defaultUI-toolbar,
          .toastui-editor-toolbar,
          .toastui-editor-md-tab-container,
          .toastui-editor-mode-switch {
            display: none !important;
          }
          .toastui-editor-main,
          .toastui-editor-main-container,
          .toastui-editor-ww-container,
          .toastui-editor.ww-mode {
            height: 100% !important;
            border: 0 !important;
            background: transparent !important;
          }
          .ProseMirror.toastui-editor-contents,
          .toastui-editor-contents {
            max-width: 820px;
            margin: 0 auto;
            padding: 28px 36px 120px;
            color: var(--editor-fg);
            font-size: var(--editor-font-size) !important;
            line-height: 1.75;
          }
          .toastui-editor-contents h1,
          .toastui-editor-contents h2,
          .toastui-editor-contents h3,
          .toastui-editor-contents h4,
          .toastui-editor-contents h5,
          .toastui-editor-contents h6 {
            color: var(--editor-fg);
            line-height: 1.25;
            letter-spacing: -0.02em;
            margin-top: 1.3em;
            margin-bottom: 0.4em;
          }
          .toastui-editor-contents h1 {
            font-size: calc(var(--editor-font-size) * 2.05);
            font-weight: 750;
          }
          .toastui-editor-contents h2 {
            font-size: calc(var(--editor-font-size) * 1.55);
            font-weight: 700;
            padding-bottom: 0.35em;
            border-bottom: 1px solid var(--editor-border);
          }
          .toastui-editor-contents h3 {
            font-size: calc(var(--editor-font-size) * 1.28);
            font-weight: 680;
          }
          .toastui-editor-contents p,
          .toastui-editor-contents li {
            color: var(--editor-fg);
          }
          .toastui-editor-contents a {
            color: var(--editor-link);
          }
          .toastui-editor-contents blockquote {
            margin: 1rem 0;
            padding: 0.8rem 1rem;
            border-left: 3px solid var(--editor-border);
            background: var(--editor-panel);
            color: var(--editor-muted);
            border-radius: 0 10px 10px 0;
          }
          .toastui-editor-contents code {
            background: var(--editor-code-bg);
            border-radius: 6px;
            padding: 0.14em 0.35em;
          }
          .toastui-editor-contents pre {
            background: var(--editor-code-bg);
            border: 1px solid var(--editor-border);
            border-radius: 12px;
            padding: 16px 18px;
          }
          .toastui-editor-contents hr {
            border-top-color: var(--editor-border);
            margin: 1.8rem 0;
          }
          .toastui-editor-contents table th,
          .toastui-editor-contents table td {
            border-color: var(--editor-border);
          }
          .toastui-editor-contents table th {
            background: var(--editor-panel);
          }
          .toastui-editor-contents img {
            border-radius: 12px;
          }
          .toastui-editor-contents .task-list-item {
            list-style: none;
          }
          .toastui-editor-contents ::selection {
            background: var(--editor-selection);
          }
          .glacier-error {
            max-width: 440px;
            margin: 56px auto;
            padding: 18px 20px;
            border: 1px solid var(--editor-border);
            border-radius: 14px;
            background: var(--editor-panel);
            color: var(--editor-muted);
            line-height: 1.6;
          }
          .glacier-error strong {
            color: var(--editor-fg);
            display: block;
            margin-bottom: 6px;
          }
        </style>
        </head>
        <body>
          <div id="loading">Loading rich markdown editor…</div>
          <div id="editor-shell">
            <div id="frontmatter"></div>
            <div id="editor"></div>
          </div>

          <script src="https://uicdn.toast.com/editor/3.2.2/toastui-editor-all.min.js"></script>
          <script>
            const INITIAL_MARKDOWN = \(javaScriptStringLiteral(bodyMarkdown));
            const FRONTMATTER_PROPERTIES = \(javaScriptJSONLiteral(frontmatter));
            const ROOT = document.documentElement;
            let editor = null;

            function debounce(fn, ms) {
              let timer;
              return (...args) => {
                clearTimeout(timer);
                timer = setTimeout(() => fn(...args), ms);
              };
            }

            function showError(message) {
              const loading = document.getElementById('loading');
              loading.innerHTML = '<div class="glacier-error"><strong>Rich editor unavailable</strong>' + message + '</div>';
            }

            function syncMarkdownToSwift() {
              if (!editor) return;
              window.webkit.messageHandlers.glacierSave.postMessage(editor.getMarkdown());
            }

            window.glacierSetFontSize = function(size) {
              ROOT.style.setProperty('--editor-font-size', size + 'px');
            };
            window.glacierForceSave = function() {
              syncMarkdownToSwift();
            };

            function renderFrontmatter() {
              const container = document.getElementById('frontmatter');
              container.innerHTML = '';

              if (!FRONTMATTER_PROPERTIES.length) {
                container.classList.remove('has-properties');
                return;
              }

              container.classList.add('has-properties');

              const header = document.createElement('div');
              header.className = 'glacier-frontmatter-header';
              header.textContent = 'Properties';
              container.appendChild(header);

              const list = document.createElement('div');
              list.className = 'glacier-frontmatter-list';

              FRONTMATTER_PROPERTIES.forEach((item) => {
                const row = document.createElement('div');
                row.className = 'glacier-frontmatter-row';

                const name = document.createElement('div');
                name.className = 'glacier-frontmatter-name';
                name.textContent = item.name;

                const value = document.createElement('div');
                value.className = 'glacier-frontmatter-value';
                value.textContent = item.value;

                row.appendChild(name);
                row.appendChild(value);
                list.appendChild(row);
              });

              container.appendChild(list);
            }

            try {
              renderFrontmatter();

              editor = new toastui.Editor({
                el: document.querySelector('#editor'),
                height: '100%',
                initialValue: INITIAL_MARKDOWN,
                initialEditType: 'wysiwyg',
                previewStyle: 'tab',
                hideModeSwitch: true,
                autofocus: false,
                usageStatistics: false
              });

              editor.on('change', debounce(syncMarkdownToSwift, 450));
              window.glacierSetFontSize(\(fontSize));
              document.getElementById('loading').style.display = 'none';
              document.getElementById('editor-shell').style.display = 'flex';
              window.webkit.messageHandlers.glacierReady.postMessage('ready');
            } catch (error) {
              showError('The rich Markdown view uses pinned Toast UI assets. Switch to Source mode if loading fails.');
              console.error(error);
            }
          </script>
        </body>
        </html>
        """
    }

    private func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    private func javaScriptJSONLiteral<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return encoded
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var text: String
        let url: URL
        let frontmatterPrefix: String?
        weak var webView: WKWebView?
        var lastSaveRequestCount = 0

        init(text: Binding<String>, url: URL, frontmatterPrefix: String?) {
            _text = text
            self.url = url
            self.frontmatterPrefix = frontmatterPrefix
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "glacierSave":
                guard let markdown = message.body as? String else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let fullMarkdown = (self.frontmatterPrefix ?? "") + markdown
                    self.text = fullMarkdown
                    try? fullMarkdown.write(to: self.url, atomically: true, encoding: .utf8)
                }
            case "glacierReady":
                break
            default:
                break
            }
        }

        @MainActor
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

private struct MarkdownRichDocument {
    let frontmatterPrefix: String?
    let bodyMarkdown: String
    let properties: [MarkdownFrontmatterProperty]

    init(markdown: String) {
        guard let frontmatter = Self.extractFrontmatter(from: markdown) else {
            frontmatterPrefix = nil
            bodyMarkdown = markdown
            properties = []
            return
        }

        frontmatterPrefix = frontmatter.prefix
        bodyMarkdown = frontmatter.body
        properties = Self.parseProperties(from: frontmatter.content)
    }

    private static func extractFrontmatter(
        from markdown: String
    ) -> (prefix: String, content: String, body: String)? {
        let hasBOM = markdown.hasPrefix("\u{FEFF}")
        let candidate = hasBOM ? String(markdown.dropFirst()) : markdown
        let pattern = #"(?s)\A---[ \t]*\r?\n(.*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: candidate,
                  range: NSRange(candidate.startIndex..., in: candidate)
              ),
              let fullRange = Range(match.range(at: 0), in: candidate),
              let contentRange = Range(match.range(at: 1), in: candidate) else {
            return nil
        }

        let prefix = (hasBOM ? "\u{FEFF}" : "") + String(candidate[fullRange])
        let content = String(candidate[contentRange])
        let body = String(candidate[fullRange.upperBound...])
        return (prefix, content, body)
    }

    private static func parseProperties(from frontmatter: String) -> [MarkdownFrontmatterProperty] {
        let normalized = frontmatter.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var properties: [MarkdownFrontmatterProperty] = []
        var currentName: String?
        var currentInlineValue = ""
        var currentNestedLines: [String] = []

        func flushCurrentProperty() {
            guard let propertyName = currentName else { return }

            let renderedValue = renderValue(
                inlineValue: currentInlineValue,
                nestedLines: currentNestedLines
            )

            properties.append(
                MarkdownFrontmatterProperty(
                    name: propertyName,
                    value: renderedValue.isEmpty ? " " : renderedValue
                )
            )

            currentName = nil
            currentInlineValue = ""
            currentNestedLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if currentName == nil {
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("#"),
                      let property = splitTopLevelPropertyLine(line) else {
                    continue
                }

                currentName = property.name
                currentInlineValue = property.value
                continue
            }

            if !trimmed.isEmpty,
               !trimmed.hasPrefix("#"),
               let property = splitTopLevelPropertyLine(line) {
                flushCurrentProperty()
                currentName = property.name
                currentInlineValue = property.value
            } else {
                currentNestedLines.append(line)
            }
        }

        flushCurrentProperty()
        return properties
    }

    private static func splitTopLevelPropertyLine(_ line: String) -> (name: String, value: String)? {
        guard line.first.map({ $0 != " " && $0 != "\t" }) == true else {
            return nil
        }

        var isInsideSingleQuotes = false
        var isInsideDoubleQuotes = false

        for index in line.indices {
            let character = line[index]

            switch character {
            case "'" where !isInsideDoubleQuotes:
                isInsideSingleQuotes.toggle()
            case "\"" where !isInsideSingleQuotes:
                isInsideDoubleQuotes.toggle()
            case ":" where !isInsideSingleQuotes && !isInsideDoubleQuotes:
                let rawName = line[..<index].trimmingCharacters(in: .whitespaces)
                guard !rawName.isEmpty, rawName != "-" else { return nil }

                let valueStart = line.index(after: index)
                let rawValue = line[valueStart...].trimmingCharacters(in: .whitespaces)
                let cleanedName = trimmedQuotes(in: String(rawName))
                return (cleanedName, rawValue)
            default:
                continue
            }
        }

        return nil
    }

    private static func renderValue(inlineValue: String, nestedLines: [String]) -> String {
        let trimmedInlineValue = inlineValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulNestedLines = nestedLines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }

        if meaningfulNestedLines.isEmpty {
            return renderInlineValue(trimmedInlineValue)
        }

        if trimmedInlineValue == "|" || trimmedInlineValue == ">" {
            return removeSharedIndentation(from: meaningfulNestedLines).joined(separator: "\n")
        }

        if !trimmedInlineValue.isEmpty {
            let nestedText = renderNestedValue(from: meaningfulNestedLines)
            return nestedText.isEmpty
                ? renderInlineValue(trimmedInlineValue)
                : renderInlineValue(trimmedInlineValue) + "\n" + nestedText
        }

        return renderNestedValue(from: meaningfulNestedLines)
    }

    private static func renderInlineValue(_ value: String) -> String {
        let trimmed = trimmedQuotes(in: value)

        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inner = trimmed.dropFirst().dropLast()
            return inner
                .split(separator: ",")
                .map { trimmedQuotes(in: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                .joined(separator: ", ")
        }

        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            let inner = trimmed.dropFirst().dropLast()
            return inner
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "\n")
        }

        return trimmed
    }

    private static func renderNestedValue(from lines: [String]) -> String {
        let unindented = removeSharedIndentation(from: lines)
        let trimmed = unindented.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if trimmed.allSatisfy({ $0.hasPrefix("- ") }) {
            return trimmed
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
                .map(renderInlineValue)
                .joined(separator: ", ")
        }

        return unindented
            .map { line in
                let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanLine.hasPrefix("- ")
                    ? String(cleanLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    : cleanLine
            }
            .joined(separator: "\n")
    }

    private static func removeSharedIndentation(from lines: [String]) -> [String] {
        let indentationWidths = lines.compactMap { line -> Int? in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return line.prefix { $0 == " " || $0 == "\t" }.count
        }

        guard let sharedIndentation = indentationWidths.min(), sharedIndentation > 0 else {
            return lines
        }

        return lines.map { line in
            guard line.count >= sharedIndentation else { return line }
            return String(line.dropFirst(sharedIndentation))
        }
    }

    private static func trimmedQuotes(in value: String) -> String {
        guard value.count >= 2 else { return value }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }

        return value
    }
}

private struct MarkdownFrontmatterProperty: Encodable {
    let name: String
    let value: String
}
