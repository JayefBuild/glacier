// SyntaxHighlighter.swift
// Lightweight regex-based syntax highlighter for common languages.
// Produces an AttributedString for use in the editor view.

import SwiftUI

struct SyntaxHighlighter {

    let theme: any AppTheme
    var fontSize: CGFloat? = nil   // overrides theme.typography.editorFontSize when set

    private var resolvedFontSize: CGFloat {
        fontSize ?? theme.typography.editorFontSize
    }

    // MARK: - Highlight

    func highlight(_ text: String, extension ext: String) -> AttributedString {
        let kind = FileTypeRegistry.kind(for: ext)

        switch kind {
        case .code:
            return highlightCode(text, ext: ext)
        case .json:
            return highlightJSON(text)
        case .markdown:
            return highlightMarkdown(text)
        default:
            return AttributedString(text)
        }
    }

    // MARK: - Code Highlighting

    private func highlightCode(_ text: String, ext: String) -> AttributedString {
        var result = AttributedString(text)

        let tc = theme.colors
        let fontSize = resolvedFontSize
        let fontName = theme.typography.editorFontName

        // Base font
        applyBase(&result, fontName: fontName, fontSize: fontSize, color: NSColor(tc.codeText))

        // Comments (line and block)
        apply(&result, pattern: #"(//[^\n]*)|(\/\*[\s\S]*?\*\/)"#,
              color: NSColor(tc.syntaxComment), italic: true, fontName: fontName, fontSize: fontSize)

        // Strings
        apply(&result, pattern: #"("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#,
              color: NSColor(tc.syntaxString), fontName: fontName, fontSize: fontSize)

        // Keywords per language
        let kws = keywords(for: ext)
        if !kws.isEmpty {
            let pattern = #"\b("# + kws.joined(separator: "|") + #")\b"#
            apply(&result, pattern: pattern, color: NSColor(tc.syntaxKeyword),
                  bold: true, fontName: fontName, fontSize: fontSize)
        }

        // Numbers
        apply(&result, pattern: #"\b(\d+\.?\d*)\b"#,
              color: NSColor(tc.syntaxNumber), fontName: fontName, fontSize: fontSize)

        // Function calls: name(
        apply(&result, pattern: #"\b([a-zA-Z_][a-zA-Z0-9_]*)(?=\()"#,
              color: NSColor(tc.syntaxFunction), fontName: fontName, fontSize: fontSize)

        // Types: CapitalizedWords
        apply(&result, pattern: #"\b([A-Z][a-zA-Z0-9_]*)\b"#,
              color: NSColor(tc.syntaxType), fontName: fontName, fontSize: fontSize)

        return result
    }

    // MARK: - JSON Highlighting

    private func highlightJSON(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let tc = theme.colors
        let fontSize = resolvedFontSize
        let fontName = theme.typography.editorFontName

        applyBase(&result, fontName: fontName, fontSize: fontSize, color: NSColor(tc.codeText))
        // Keys
        apply(&result, pattern: #""([^"]+)"\s*:"#,
              color: NSColor(tc.syntaxFunction), fontName: fontName, fontSize: fontSize)
        // String values
        apply(&result, pattern: #":\s*"([^"]*)"#,
              color: NSColor(tc.syntaxString), fontName: fontName, fontSize: fontSize)
        // Numbers
        apply(&result, pattern: #":\s*(-?\d+\.?\d*)"#,
              color: NSColor(tc.syntaxNumber), fontName: fontName, fontSize: fontSize)
        // Booleans / null
        apply(&result, pattern: #"\b(true|false|null)\b"#,
              color: NSColor(tc.syntaxKeyword), bold: true, fontName: fontName, fontSize: fontSize)

        return result
    }

    // MARK: - Markdown Highlighting

    private func highlightMarkdown(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let tc = theme.colors
        let fontSize = resolvedFontSize
        let fontName = theme.typography.editorFontName

        applyBase(&result, fontName: fontName, fontSize: fontSize, color: NSColor(tc.codeText))
        // Headings
        apply(&result, pattern: #"^#{1,6} .+$"#,
              color: NSColor(tc.syntaxKeyword), bold: true, fontName: fontName, fontSize: fontSize,
              options: [.anchorsMatchLines])
        // Bold
        apply(&result, pattern: #"\*\*(.+?)\*\*"#,
              color: NSColor(tc.primaryText), bold: true, fontName: fontName, fontSize: fontSize)
        // Italic
        apply(&result, pattern: #"\*(.+?)\*"#,
              color: NSColor(tc.primaryText), italic: true, fontName: fontName, fontSize: fontSize)
        // Code spans
        apply(&result, pattern: #"`[^`]+`"#,
              color: NSColor(tc.syntaxString), fontName: fontName, fontSize: fontSize)
        // Links
        apply(&result, pattern: #"\[([^\]]+)\]\([^\)]+\)"#,
              color: NSColor(tc.accentSecondary), fontName: fontName, fontSize: fontSize)
        // Comments-style blockquotes
        apply(&result, pattern: #"^>.*$"#,
              color: NSColor(tc.syntaxComment), italic: true, fontName: fontName, fontSize: fontSize,
              options: [.anchorsMatchLines])

        return result
    }

    // MARK: - Helpers

    private func applyBase(_ result: inout AttributedString, fontName: String, fontSize: CGFloat, color: NSColor) {
        var container = AttributeContainer()
        container.font = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        container.foregroundColor = color
        result.mergeAttributes(container)
    }

    private func apply(
        _ result: inout AttributedString,
        pattern: String,
        color: NSColor,
        bold: Bool = false,
        italic: Bool = false,
        fontName: String,
        fontSize: CGFloat,
        options: NSRegularExpression.Options = []
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let str = String(result.characters)
        let nsRange = NSRange(str.startIndex..., in: str)

        regex.enumerateMatches(in: str, range: nsRange) { match, _, _ in
            guard let match else { return }
            let range = match.range(at: match.numberOfRanges > 1 ? 1 : 0)
            guard
                let swiftRange = Range(range, in: str),
                let attrRange = Range(swiftRange, in: result)
            else { return }

            var container = AttributeContainer()
            var traits: NSFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }

            let baseFont = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            if !traits.isEmpty {
                let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
                container.font = NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
            } else {
                container.font = baseFont
            }
            container.foregroundColor = color
            result[attrRange].mergeAttributes(container)
        }
    }

    // MARK: - Keywords

    private func keywords(for ext: String) -> [String] {
        switch ext {
        case "swift":
            return ["import", "class", "struct", "enum", "protocol", "extension", "func", "var", "let",
                    "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default",
                    "break", "continue", "where", "throws", "throw", "try", "catch", "async", "await",
                    "static", "final", "override", "init", "deinit", "self", "super", "nil", "true", "false",
                    "public", "private", "internal", "fileprivate", "open", "mutating", "lazy", "weak",
                    "unowned", "typealias", "associatedtype", "@MainActor", "@Published", "@State",
                    "@Binding", "@ObservableObject", "@EnvironmentObject", "@Environment"]
        case "py":
            return ["import", "from", "as", "class", "def", "if", "elif", "else", "for", "in", "while",
                    "return", "yield", "lambda", "with", "try", "except", "finally", "raise", "pass",
                    "break", "continue", "and", "or", "not", "is", "None", "True", "False", "async", "await",
                    "global", "nonlocal", "del", "print", "len", "range", "type", "self"]
        case "js", "jsx", "ts", "tsx":
            return ["import", "export", "from", "default", "class", "function", "const", "let", "var",
                    "if", "else", "return", "for", "of", "in", "while", "switch", "case", "break",
                    "continue", "new", "this", "typeof", "instanceof", "async", "await", "try", "catch",
                    "finally", "throw", "null", "undefined", "true", "false", "extends", "implements",
                    "interface", "type", "enum", "readonly", "public", "private", "protected", "static",
                    "abstract", "void", "never", "any", "string", "number", "boolean"]
        case "rs":
            return ["use", "mod", "pub", "fn", "let", "mut", "const", "static", "struct", "enum",
                    "trait", "impl", "where", "for", "in", "if", "else", "match", "return", "break",
                    "continue", "loop", "while", "async", "await", "move", "ref", "Box", "Option",
                    "Result", "Some", "None", "Ok", "Err", "self", "Self", "super", "crate", "true", "false"]
        case "go":
            return ["package", "import", "func", "var", "const", "type", "struct", "interface", "map",
                    "chan", "go", "select", "case", "default", "if", "else", "for", "range", "return",
                    "break", "continue", "defer", "goroutine", "nil", "true", "false",
                    "string", "int", "int64", "float64", "bool", "byte", "error", "any"]
        case "sh", "bash", "zsh", "fish":
            return ["if", "then", "else", "elif", "fi", "for", "do", "done", "while", "until",
                    "case", "esac", "function", "return", "exit", "echo", "export", "local", "source",
                    "cd", "ls", "grep", "awk", "sed", "cat", "rm", "cp", "mv"]
        case "html", "htm":
            return ["DOCTYPE", "html", "head", "body", "div", "span", "p", "a", "h1", "h2", "h3",
                    "h4", "h5", "h6", "ul", "ol", "li", "table", "tr", "td", "th", "form", "input",
                    "button", "script", "style", "link", "meta", "title", "img", "nav", "section",
                    "article", "header", "footer", "main", "aside"]
        case "css", "scss", "sass":
            return ["import", "use", "mixin", "include", "extend", "if", "else", "for", "each",
                    "while", "function", "return", "media", "keyframes", "from", "to",
                    "display", "position", "color", "background", "margin", "padding", "border",
                    "font", "text", "flex", "grid", "width", "height", "transform", "transition"]
        default:
            return []
        }
    }
}
