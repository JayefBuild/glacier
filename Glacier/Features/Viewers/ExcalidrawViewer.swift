// ExcalidrawViewer.swift
// Excalidraw editor via WKWebView loading excalidraw.com directly.
// Requires internet. Fast and always up to date.

import SwiftUI
import WebKit

struct ExcalidrawViewer: View {
    @Binding var text: String
    let url: URL
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ExcalidrawWebView(text: $text, url: url, appState: appState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WebView

struct ExcalidrawWebView: NSViewRepresentable {
    @Binding var text: String
    let url: URL
    let appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, url: url, appState: appState)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(context.coordinator, name: "glacierSave")

        // Poll for changes and save back to disk
        let pollScript = WKUserScript(source: """
            var __glacier_lastSave = '';
            setInterval(function() {
                if (!window.excalidrawAPI) return;
                var el = window.excalidrawAPI.getSceneElements();
                var as = window.excalidrawAPI.getAppState();
                var fi = window.excalidrawAPI.getFiles();
                if (!el || el.length === 0) return;
                var payload = JSON.stringify({
                    type: 'excalidraw', version: 2, source: 'glacier',
                    elements: el,
                    appState: {
                        gridSize: as.gridSize,
                        viewBackgroundColor: as.viewBackgroundColor,
                        theme: as.theme,
                    },
                    files: fi || {},
                });
                if (payload !== __glacier_lastSave) {
                    __glacier_lastSave = payload;
                    window.webkit.messageHandlers.glacierSave.postMessage(payload);
                }
            }, 1500);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(pollScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = isDark ? "dark" : "light"
        webView.load(URLRequest(url: URL(string: "https://excalidraw.com/#theme=\(theme)")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) { }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var text: String
        let url: URL
        let appState: AppState
        weak var webView: WKWebView?
        var didLoadInitialData = false

        init(text: Binding<String>, url: URL, appState: AppState) {
            _text = text
            self.url = url
            self.appState = appState
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didLoadInitialData else { return }
            let json = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !json.isEmpty, json != "{}" else { return }
            guard let _ = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return }

            // Wait for Excalidraw to mount, then load the scene
            let safe = json
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function tryLoad(n) {
                if (window.excalidrawAPI) {
                    var d = JSON.parse('\(safe)');
                    window.excalidrawAPI.updateScene({ elements: d.elements || [], appState: d.appState || {} });
                    if (d.files) window.excalidrawAPI.addFiles(Object.values(d.files));
                } else if (n > 0) {
                    setTimeout(function() { tryLoad(n-1); }, 400);
                }
            })(40);
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            didLoadInitialData = true
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "glacierSave", let json = message.body as? String else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.text = json
                try? self.appState.fileService.writeFile(text: json, to: self.url)
            }
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
