// MarkdownSourceTextView.swift
// NSTextView-backed source editor that intercepts image paste to save into an assets/ folder
// alongside the document, inserting a relative markdown image reference.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MarkdownSourceTextView: NSViewRepresentable {
    @Binding var text: String
    let documentDirectory: URL
    var fontSize: CGFloat = 15
    let theme: any AppTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> GlacierScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let mdTextView = MarkdownPasteTextView(frame: .zero, textContainer: container)
        let scrollView = GlacierScrollView(frame: .zero, textView: mdTextView)
        scrollView.setup(showLineNumbers: false)
        scrollView.textView.delegate = context.coordinator

        mdTextView.onImagePaste = { [weak coordinator = context.coordinator] data, ext in
            coordinator?.handleImagePaste(data: data, ext: ext, documentDirectory: documentDirectory)
        }
        return scrollView
    }

    func updateNSView(_ nsView: GlacierScrollView, context: Context) {
        context.coordinator.update(
            nsView: nsView,
            text: text,
            fontSize: fontSize,
            theme: theme
        )
        // Refresh paste handler closure so it captures the latest documentDirectory
        if let mdTextView = nsView.textView as? MarkdownPasteTextView {
            mdTextView.onImagePaste = { [weak coordinator = context.coordinator] data, ext in
                coordinator?.handleImagePaste(data: data, ext: ext, documentDirectory: documentDirectory)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        private var renderedText = ""
        private var renderedThemeName = ""
        private var renderedFontSize: CGFloat = 0
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func update(
            nsView: GlacierScrollView,
            text: String,
            fontSize: CGFloat,
            theme: any AppTheme
        ) {
            self.textView = nsView.textView
            nsView.textView.backgroundColor = NSColor(theme.colors.editorBackground)
            nsView.textView.linkTextAttributes = [
                .foregroundColor: NSColor(theme.colors.accentSecondary),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]

            let didChangeHighlightInputs =
                renderedText != text ||
                renderedThemeName != theme.name ||
                renderedFontSize != fontSize

            guard didChangeHighlightInputs else { return }

            let highlighter = SyntaxHighlighter(
                theme: theme,
                fontSize: fontSize,
                displayStyle: .source
            )
            let attributed = highlighter.highlight(text, extension: "md")
            let currentString = nsView.textView.string
            let selectedRanges = nsView.textView.selectedRanges

            if let nsAttr = try? NSAttributedString(attributed, including: \.appKit) {
                nsView.textView.textStorage?.setAttributedString(nsAttr)
                if currentString == text {
                    nsView.textView.selectedRanges = selectedRanges
                }
            } else {
                nsView.textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                nsView.textView.textColor = NSColor.labelColor
                nsView.textView.string = text
            }

            renderedText = text
            renderedThemeName = theme.name
            renderedFontSize = fontSize
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func handleImagePaste(data: Data, ext: String, documentDirectory: URL) {
            let assetsDir = documentDirectory.appendingPathComponent("assets")
            let filename = UUID().uuidString + "." + ext
            let fileURL = assetsDir.appendingPathComponent(filename)

            do {
                try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
                try data.write(to: fileURL)
            } catch {
                NSLog("[MarkdownSource] Failed to save pasted image: \(error)")
                return
            }

            let markdownRef = "![](assets/\(filename))"
            if let textView {
                textView.insertText(markdownRef, replacementRange: textView.selectedRange())
                // insertText fires textDidChange, so binding updates automatically
            }
        }
    }
}

// MARK: - NSTextView subclass with image paste interception

final class MarkdownPasteTextView: GlacierTextView {
    /// Called when an image is pasted. Return value: true if consumed, false to fall through.
    var onImagePaste: ((_ data: Data, _ ext: String) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        // PNG
        if let data = pb.data(forType: .png) {
            onImagePaste?(data, "png")
            return
        }

        // JPEG
        if let data = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            onImagePaste?(data, "jpg")
            return
        }

        // TIFF (screenshots) → convert to PNG
        if let tiff = pb.data(forType: .tiff),
           let image = NSImage(data: tiff),
           let rep = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: rep),
           let png = bitmap.representation(using: .png, properties: [:]) {
            onImagePaste?(png, "png")
            return
        }

        // File URL pointing to an image
        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = fileURLs.first,
           let type = UTType(filenameExtension: first.pathExtension),
           type.conforms(to: .image),
           let data = try? Data(contentsOf: first) {
            let ext = first.pathExtension.lowercased()
            onImagePaste?(data, ext.isEmpty ? "png" : ext)
            return
        }

        super.paste(sender)
    }
}
