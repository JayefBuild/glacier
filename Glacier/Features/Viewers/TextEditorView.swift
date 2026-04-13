// TextEditorView.swift
// Editable code/text view with syntax highlighting.

import SwiftUI
import Combine

struct TextEditorView: View {
    @Binding var text: String
    let fileExtension: String
    let url: URL
    var fontSize: CGFloat = 13

    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    // Debounced save
    @State private var saveCancellable: AnyCancellable?

    private var languageLabel: String {
        FileTypeRegistry.languageName(for: fileExtension)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorStatusBar

            Divider()

            SyntaxTextView(
                text: $text,
                fileExtension: fileExtension,
                showLineNumbers: false,
                fontSize: fontSize,
                theme: theme
            )
        }
        .onChange(of: text) { _, newValue in
            scheduleSave(text: newValue)
        }
    }

    // MARK: - Save

    private func scheduleSave(text: String) {
        saveCancellable?.cancel()
        saveCancellable = Just(text)
            .delay(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { value in
                try? appState.fileService.writeFile(text: value, to: url)
            }
    }

    // MARK: - Status Bar

    private var editorStatusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: FileTypeRegistry.icon(for: fileExtension))
                    .font(.system(size: 10))
                    .foregroundStyle(FileTypeRegistry.color(for: fileExtension))
                Text(languageLabel)
                    .font(theme.typography.captionFont)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 12)

            Text("\(text.components(separatedBy: "\n").count) lines")
                .font(theme.typography.captionFont)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(theme.colors.editorBackground)
    }
}

// MARK: - Syntax Text View (editable NSTextView bridge)

struct SyntaxTextView: NSViewRepresentable {
    @Binding var text: String
    let fileExtension: String
    let showLineNumbers: Bool
    var fontSize: CGFloat = 13
    let theme: any AppTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> GlacierScrollView {
        let scrollView = GlacierScrollView()
        scrollView.setup(showLineNumbers: showLineNumbers)
        scrollView.textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ nsView: GlacierScrollView, context: Context) {
        let highlighter = SyntaxHighlighter(theme: theme, fontSize: fontSize)
        let attributed = highlighter.highlight(text, extension: fileExtension)

        // Only update if content actually changed to avoid clobbering cursor position
        let currentString = nsView.textView.string
        if currentString != text {
            if let nsAttr = try? NSAttributedString(attributed, including: \.appKit) {
                nsView.textView.textStorage?.setAttributedString(nsAttr)
            } else {
                nsView.textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                nsView.textView.textColor = NSColor.labelColor
                nsView.textView.string = text
            }
        } else {
            // Content same — re-apply highlighting without replacing (preserves cursor)
            if let nsAttr = try? NSAttributedString(attributed, including: \.appKit) {
                let selectedRanges = nsView.textView.selectedRanges
                nsView.textView.textStorage?.setAttributedString(nsAttr)
                nsView.textView.selectedRanges = selectedRanges
            }
        }

        // Sync font size change
        let newFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if nsView.textView.font?.pointSize != newFont.pointSize {
            nsView.textView.font = newFont
        }

        if let textContainer = nsView.textView.textContainer {
            nsView.textView.layoutManager?.ensureLayout(for: textContainer)
        }
        nsView.textView.sizeToFit()
        nsView.reflectScrolledClipView(nsView.contentView)

        nsView.textView.isEditable = true
        nsView.textView.isSelectable = true
        nsView.textView.backgroundColor = NSColor(theme.colors.editorBackground)
        nsView.setShowLineNumbers(showLineNumbers)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

// MARK: - Glacier Scroll View (line numbers + text view)

final class GlacierScrollView: NSScrollView {
    let textView: NSTextView
    private let lineNumberView: LineNumberRulerView

    override init(frame: NSRect) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        lineNumberView = LineNumberRulerView(textView: textView)

        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setup(showLineNumbers: Bool) {
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesRuler = false

        documentView = textView

        verticalRulerView = lineNumberView
        hasVerticalRuler = showLineNumbers
        rulersVisible = showLineNumbers

        lineNumberView.wantsLayer = true
        lineNumberView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
    }

    func setShowLineNumbers(_ show: Bool) {
        hasVerticalRuler = show
        rulersVisible = show
    }
}

// MARK: - Line Number Ruler

final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        self.ruleThickness = 44
        self.clientView = textView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func textDidChange() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = textView.enclosingScrollView?.documentVisibleRect ?? textView.bounds
        let inset = textView.textContainerInset
        let originOffset = convert(NSPoint.zero, from: textView)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let fullText = textView.string as NSString
        var lineNumber = 1
        var charIndex = 0
        let totalChars = fullText.length

        while charIndex < totalChars || charIndex == 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: charIndex, length: 0),
                actualCharacterRange: nil
            )
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location == NSNotFound ? 0 : glyphRange.location,
                effectiveRange: nil
            )

            let yPos = lineRect.minY + inset.height + originOffset.y - visibleRect.minY

            if yPos >= -lineRect.height && yPos <= bounds.height + lineRect.height {
                let label = "\(lineNumber)" as NSString
                let labelSize = label.size(withAttributes: attrs)
                label.draw(
                    at: NSPoint(x: ruleThickness - labelSize.width - 6, y: yPos + (lineRect.height - labelSize.height) / 2),
                    withAttributes: attrs
                )
            }

            let lineRange = (fullText as NSString).lineRange(for: NSRange(location: charIndex, length: 0))
            if lineRange.length == 0 { break }
            charIndex = NSMaxRange(lineRange)
            lineNumber += 1

            if charIndex >= totalChars { break }
        }
    }
}
