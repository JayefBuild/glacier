// MarkdownPreviewView.swift
// Renders Markdown as a styled WKWebView preview.

import SwiftUI
import WebKit

struct MarkdownPreviewView: View {
    let text: String
    var fontSize: CGFloat = 14

    var body: some View {
        MarkdownWebViewRepresentable(text: text, fontSize: fontSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - NSViewRepresentable

private struct MarkdownWebViewRepresentable: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 14

    func makeNSView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")  // transparent bg, let CSS handle it
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when content changes
        let newHTML = buildHTML(text)
        guard newHTML != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = newHTML
        webView.loadHTMLString(newHTML, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""

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

    // MARK: - HTML

    private func buildHTML(_ markdown: String) -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let fg      = isDark ? "#e8e8ed"  : "#1c1c1e"
        let bg      = isDark ? "#1c1c1e"  : "#ffffff"
        let codeBg  = isDark ? "#2c2c2e"  : "#f2f2f7"
        let link    = isDark ? "#64b5f6"  : "#007aff"
        let border  = isDark ? "#3a3a3c"  : "#d1d1d6"
        let h1fg    = isDark ? "#f5f5f7"  : "#000000"
        let muted   = isDark ? "#98989d"  : "#6e6e73"

        let body = markdownToHTML(markdown)

        return """
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <style>
        *{box-sizing:border-box;margin:0;padding:0}
        html,body{height:100%;background:\(bg)}
        body{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif;
          font-size:\(fontSize)px;line-height:1.7;color:\(fg);padding:28px 36px;max-width:820px}
        h1,h2,h3,h4,h5,h6{color:\(h1fg);margin:24px 0 8px;font-weight:600;line-height:1.3}
        h1{font-size:28px;font-weight:700}
        h2{font-size:22px;border-bottom:1px solid \(border);padding-bottom:6px}
        h3{font-size:18px}
        p{margin-bottom:14px}
        a{color:\(link);text-decoration:none}
        a:hover{text-decoration:underline}
        code{font-family:'SF Mono',Menlo,monospace;font-size:12.5px;
          background:\(codeBg);padding:2px 5px;border-radius:4px}
        pre{background:\(codeBg);border-radius:8px;padding:16px;
          overflow-x:auto;margin-bottom:16px}
        pre code{background:none;padding:0}
        blockquote{border-left:3px solid \(border);padding-left:16px;
          color:\(muted);margin:12px 0}
        ul,ol{padding-left:20px;margin-bottom:14px}
        li{margin-bottom:4px}
        hr{border:none;border-top:1px solid \(border);margin:24px 0}
        table{border-collapse:collapse;width:100%;margin-bottom:16px}
        th,td{border:1px solid \(border);padding:8px 12px;text-align:left}
        th{background:\(codeBg);font-weight:600}
        img{max-width:100%;border-radius:8px}
        strong{font-weight:600}em{font-style:italic}
        </style></head><body>\(body)</body></html>
        """
    }

    // MARK: - Simple Markdown → HTML

    private func markdownToHTML(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        var out: [String] = []
        var inCode = false
        var inUL = false
        var inOL = false

        for rawLine in lines {
            // Code fence
            if rawLine.hasPrefix("```") {
                if inUL { out.append("</ul>"); inUL = false }
                if inOL { out.append("</ol>"); inOL = false }
                inCode ? out.append("</code></pre>") : out.append("<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode {
                out.append(esc(rawLine))
                continue
            }

            let line = rawLine

            // Close lists if needed
            let isULItem = line.hasPrefix("- ") || line.hasPrefix("* ")
            let isOLItem = line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            if !isULItem && inUL { out.append("</ul>"); inUL = false }
            if !isOLItem && inOL { out.append("</ol>"); inOL = false }

            if line.hasPrefix("######") {
                out.append("<h6>\(inline(String(line.dropFirst(7))))</h6>")
            } else if line.hasPrefix("#####") {
                out.append("<h5>\(inline(String(line.dropFirst(6))))</h5>")
            } else if line.hasPrefix("####") {
                out.append("<h4>\(inline(String(line.dropFirst(5))))</h4>")
            } else if line.hasPrefix("###") {
                out.append("<h3>\(inline(String(line.dropFirst(4))))</h3>")
            } else if line.hasPrefix("##") {
                out.append("<h2>\(inline(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("# ") {
                out.append("<h1>\(inline(String(line.dropFirst(2))))</h1>")
            } else if line.hasPrefix("---") || line.hasPrefix("***") || line.hasPrefix("___") {
                out.append("<hr>")
            } else if line.hasPrefix("> ") {
                out.append("<blockquote><p>\(inline(String(line.dropFirst(2))))</p></blockquote>")
            } else if isULItem {
                if !inUL { out.append("<ul>"); inUL = true }
                let text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : String(line.dropFirst(2))
                out.append("<li>\(inline(text))</li>")
            } else if isOLItem {
                if !inOL { out.append("<ol>"); inOL = true }
                let text = line.replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression)
                out.append("<li>\(inline(text))</li>")
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("<br>")
            } else {
                out.append("<p>\(inline(line))</p>")
            }
        }

        if inUL { out.append("</ul>") }
        if inOL { out.append("</ol>") }
        if inCode { out.append("</code></pre>") }

        return out.joined(separator: "\n")
    }

    private func inline(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"__(.+?)__"#,     with: "<strong>$1</strong>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*(.+?)\*"#,     with: "<em>$1</em>",         options: .regularExpression)
        t = t.replacingOccurrences(of: #"_(.+?)_"#,       with: "<em>$1</em>",         options: .regularExpression)
        t = t.replacingOccurrences(of: #"`(.+?)`"#,       with: "<code>$1</code>",     options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[(.+?)\]\((.+?)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return t
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
