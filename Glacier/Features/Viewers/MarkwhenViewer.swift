// MarkwhenViewer.swift
// Renders .mw / .markwhen files. Toggle between source editor and Gantt timeline.

import SwiftUI
import WebKit
import Combine

struct MarkwhenViewer: View {
    @Binding var text: String
    let url: URL
    var fontSize: CGFloat = 13

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme
    @State private var showSource: Bool = false
    @State private var saveCancellable: AnyCancellable?

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.35, green: 0.62, blue: 0.95))
                    Text("Markwhen")
                        .font(theme.typography.captionFont)
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 12)

                Text("\(text.components(separatedBy: "\n").filter { $0.contains(":") }.count) events")
                    .font(theme.typography.captionFont)
                    .foregroundStyle(.tertiary)

                Spacer()

                // View toggle
                HStack(spacing: 2) {
                    toggleButton(icon: "pencil", label: "Edit Source", active: showSource) {
                        showSource = true
                    }
                    toggleButton(icon: "chart.bar.xaxis", label: "Timeline View", active: !showSource) {
                        showSource = false
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(height: 32)
            .background(theme.colors.editorBackground)

            Divider()

            if showSource {
                SyntaxTextView(
                    text: $text,
                    fileExtension: "mw",
                    showLineNumbers: false,
                    fontSize: fontSize,
                    theme: theme
                )
                .transition(.opacity)
            } else {
                MarkwhenWebView(text: text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(GlacierTheme().animation.fast, value: showSource)
        .onChange(of: text) { _, newValue in
            scheduleSave(text: newValue)
        }
    }

    private func toggleButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .background(active ? theme.colors.accent.opacity(0.15) : Color.clear)
                .foregroundStyle(active ? theme.colors.accent : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func scheduleSave(text: String) {
        saveCancellable?.cancel()
        saveCancellable = Just(text)
            .delay(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { value in
                try? appState.fileService.writeFile(text: value, to: url)
            }
    }
}

// MARK: - WebView

struct MarkwhenWebView: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.pendingText = text

        loadPage(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastText != text else { return }
        context.coordinator.lastText = text
        injectContent(into: webView, text: text)
    }

    private func loadPage(in webView: WKWebView) {
        guard let htmlURL = Bundle.main.url(forResource: "markwhen", withExtension: "html") else {
            webView.loadHTMLString("<p style='font-family:-apple-system;color:gray;padding:20px'>markwhen.html not found in bundle</p>", baseURL: nil)
            return
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    private func injectContent(into webView: WKWebView, text: String) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        webView.evaluateJavaScript("setContent(`\(escaped)`, \(isDark ? "true" : "false"));", completionHandler: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastText = ""
        var pendingText = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !pendingText.isEmpty else { return }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let escaped = pendingText
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            webView.evaluateJavaScript("setContent(`\(escaped)`, \(isDark ? "true" : "false"));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
