// MarkdownPreviewView.swift
// Rich Markdown editing for .md files, with source mode as an escape hatch.

import SwiftUI
import WebKit
import Combine

struct MarkdownEditorView: View {
    @Binding var text: String
    let url: URL
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

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            Divider()

            Group {
                switch mode {
                case .rich:
                    MarkdownLiveEditorWebView(text: $text, url: url, fontSize: fontSize)
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
            guard mode == .source else { return }
            scheduleSave(text: newValue)
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .rich {
                saveCancellable?.cancel()
                Task { @MainActor in
                    try? fileService.writeFile(text: text, to: url)
                }
            }
        }
        .onDisappear {
            saveCancellable?.cancel()
        }
    }

    private func scheduleSave(text: String) {
        saveCancellable?.cancel()
        saveCancellable = Just(text)
            .delay(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { value in
                Task { @MainActor in
                    try? fileService.writeFile(text: value, to: url)
                }
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

private struct MarkdownLiveEditorWebView: NSViewRepresentable {
    @Binding var text: String
    let url: URL
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, url: url)
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
        webView.loadHTMLString(buildHTML(markdown: text, fontSize: fontSize), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let script = "window.glacierSetFontSize && window.glacierSetFontSize(\(fontSize));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func buildHTML(markdown: String, fontSize: CGFloat) -> String {
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
          }
          #editor {
            height: 100%;
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
            <div id="editor"></div>
          </div>

          <script src="https://uicdn.toast.com/editor/3.2.2/toastui-editor-all.min.js"></script>
          <script>
            const INITIAL_MARKDOWN = \(javaScriptStringLiteral(markdown));
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

            try {
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
              document.getElementById('editor-shell').style.display = 'block';
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var text: String
        let url: URL
        weak var webView: WKWebView?

        init(text: Binding<String>, url: URL) {
            _text = text
            self.url = url
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "glacierSave":
                guard let markdown = message.body as? String else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.text = markdown
                    try? markdown.write(to: self.url, atomically: true, encoding: .utf8)
                }
            case "glacierReady":
                break
            default:
                break
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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
