// ExcalidrawViewer.swift
// Excalidraw editor via a bundled HTML wrapper in WKWebView.
// Scene state is owned by Glacier and saved to the active .excalidraw file.

import SwiftUI
import WebKit

struct ExcalidrawViewer: View {
    @Binding var text: String
    let url: URL
    let fileService: FileService
    @State private var saveRequest: EditorSaveRequest?

    var body: some View {
        ExcalidrawWebView(
            text: $text,
            url: url,
            saveRequest: saveRequest,
            fileService: fileService
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .glacierSaveDocument)) { notification in
                guard let request = notification.object as? EditorSaveRequest,
                      request.url == url else {
                    return
                }
                saveRequest = request
            }
    }
}

// MARK: - WebView

struct ExcalidrawWebView: NSViewRepresentable {
    @Binding var text: String
    let url: URL
    let saveRequest: EditorSaveRequest?
    let fileService: FileService

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, url: url, fileService: fileService)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(context.coordinator, name: "glacierSave")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        loadPage(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if let saveRequest,
           context.coordinator.lastHandledSaveRequest !== saveRequest {
            context.coordinator.lastHandledSaveRequest = saveRequest
            context.coordinator.pendingSaveRequest = saveRequest
            webView.evaluateJavaScript("window.glacierForceSave && window.glacierForceSave();", completionHandler: nil)
        }
    }

    private func loadPage(in webView: WKWebView) {
        guard let htmlURL = Bundle.main.url(forResource: "excalidraw", withExtension: "html") else {
            webView.loadHTMLString("<p style='font-family:-apple-system;color:gray;padding:20px'>excalidraw.html not found in bundle</p>", baseURL: nil)
            return
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var text: String
        let url: URL
        let fileService: FileService
        weak var webView: WKWebView?
        var didLoadInitialData = false
        weak var lastHandledSaveRequest: EditorSaveRequest?
        var pendingSaveRequest: EditorSaveRequest?

        init(text: Binding<String>, url: URL, fileService: FileService) {
            _text = text
            self.url = url
            self.fileService = fileService
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didLoadInitialData else { return }
            let fallbackScene = """
            {"type":"excalidraw","version":2,"source":"glacier","elements":[],"appState":{"gridSize":null,"viewBackgroundColor":"#ffffff"},"files":{}}
            """
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sceneJSON: String

            if !trimmed.isEmpty,
               trimmed != "{}",
               (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                sceneJSON = trimmed
            } else {
                sceneJSON = fallbackScene
            }

            // Wait for Excalidraw to mount, then load the scene
            let encodedScene = Data(sceneJSON.utf8).base64EncodedString()
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let js = """
            (function tryInit(n) {
                if (typeof window.initExcalidraw === 'function') {
                    window.initExcalidraw(atob('\(encodedScene)'), \(isDark ? "true" : "false"));
                } else if (n > 0) {
                    setTimeout(function() { tryInit(n - 1); }, 100);
                }
            })(50);
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
                try? self.fileService.writeFile(text: json, to: self.url)
                self.pendingSaveRequest?.acknowledge()
                self.pendingSaveRequest = nil
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
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
