// FileTypeRegistry.swift
// Central registry mapping file extensions to icons, colors, and kinds.
// Add new file types here to extend support.

import SwiftUI

enum FileTypeRegistry {

    // MARK: - Icon

    static func icon(for ext: String?) -> String {
        guard let ext else { return "doc" }
        return iconMap[ext] ?? fallbackIcon(for: ext)
    }

    // MARK: - Color

    static func color(for ext: String?) -> Color {
        guard let ext else { return .secondary }
        return colorMap[ext] ?? .secondary
    }

    // MARK: - Kind

    static func kind(for ext: String?) -> FileKind {
        guard let ext else { return .unknown }
        return kindMap[ext] ?? .unknown
    }

    // MARK: - Language Name (for syntax label)

    static func languageName(for ext: String?) -> String {
        guard let ext else { return "Plain Text" }
        return languageNames[ext] ?? ext.uppercased()
    }

    // MARK: - Is Text-Based

    static func isTextBased(_ ext: String?) -> Bool {
        guard let ext else { return false }
        let k = kind(for: ext)
        return k == .text || k == .markdown || k == .code || k == .json
    }

    // MARK: - Private Maps

    private static let iconMap: [String: String] = [
        // Markdown
        "md": "text.badge.checkmark",
        "markdown": "text.badge.checkmark",

        // Code
        "swift": "swift",
        "py": "chevron.left.forwardslash.chevron.right",
        "js": "chevron.left.forwardslash.chevron.right",
        "ts": "chevron.left.forwardslash.chevron.right",
        "jsx": "chevron.left.forwardslash.chevron.right",
        "tsx": "chevron.left.forwardslash.chevron.right",
        "rs": "chevron.left.forwardslash.chevron.right",
        "go": "chevron.left.forwardslash.chevron.right",
        "java": "chevron.left.forwardslash.chevron.right",
        "kt": "chevron.left.forwardslash.chevron.right",
        "cpp": "chevron.left.forwardslash.chevron.right",
        "c": "chevron.left.forwardslash.chevron.right",
        "h": "chevron.left.forwardslash.chevron.right",
        "cs": "chevron.left.forwardslash.chevron.right",
        "rb": "chevron.left.forwardslash.chevron.right",
        "php": "chevron.left.forwardslash.chevron.right",
        "sh": "terminal",
        "bash": "terminal",
        "zsh": "terminal",
        "fish": "terminal",

        // Web
        "html": "globe",
        "htm": "globe",
        "css": "paintbrush",
        "scss": "paintbrush",
        "sass": "paintbrush",

        // Data
        "json": "curlybraces",
        "yaml": "list.bullet",
        "yml": "list.bullet",
        "toml": "list.bullet",
        "xml": "chevron.left.forwardslash.chevron.right",
        "csv": "tablecells",

        // Text
        "txt": "doc.text",
        "rtf": "doc.richtext",
        "log": "doc.text",

        // Images
        "png": "photo",
        "jpg": "photo",
        "jpeg": "photo",
        "gif": "photo",
        "svg": "photo",
        "webp": "photo",
        "heic": "photo",
        "tiff": "photo",

        // Video
        "mp4": "play.rectangle",
        "mov": "play.rectangle",
        "avi": "play.rectangle",
        "mkv": "play.rectangle",
        "m4v": "play.rectangle",
        "wmv": "play.rectangle",

        // Audio
        "mp3": "waveform",
        "wav": "waveform",
        "aac": "waveform",
        "flac": "waveform",
        "m4a": "waveform",

        // Documents
        "pdf": "doc.richtext",

        // Archives
        "zip": "archivebox",
        "tar": "archivebox",
        "gz": "archivebox",
        "rar": "archivebox",
        "7z": "archivebox",

        // Config
        "gitignore": "doc.badge.gearshape",
        "env": "doc.badge.gearshape",
        "lock": "lock.doc",

        // Markwhen
        "mw": "calendar.badge.clock",
        "markwhen": "calendar.badge.clock",

        // Excalidraw
        "excalidraw": "pencil.and.scribble",
    ]

    private static let colorMap: [String: Color] = [
        "mw": Color(red: 0.35, green: 0.62, blue: 0.95),
        "markwhen": Color(red: 0.35, green: 0.62, blue: 0.95),
        "excalidraw": Color(red: 0.62, green: 0.45, blue: 0.95),
        "swift": Color(red: 0.98, green: 0.45, blue: 0.22),
        "py": Color(red: 0.20, green: 0.60, blue: 0.86),
        "js": Color(red: 0.94, green: 0.81, blue: 0.17),
        "ts": Color(red: 0.18, green: 0.47, blue: 0.77),
        "jsx": Color(red: 0.35, green: 0.79, blue: 0.93),
        "tsx": Color(red: 0.18, green: 0.47, blue: 0.77),
        "rs": Color(red: 0.86, green: 0.38, blue: 0.27),
        "go": Color(red: 0.27, green: 0.74, blue: 0.84),
        "rb": Color(red: 0.80, green: 0.11, blue: 0.11),
        "md": Color(red: 0.40, green: 0.72, blue: 0.55),
        "markdown": Color(red: 0.40, green: 0.72, blue: 0.55),
        "json": Color(red: 0.96, green: 0.68, blue: 0.37),
        "html": Color(red: 0.90, green: 0.39, blue: 0.22),
        "css": Color(red: 0.30, green: 0.54, blue: 0.95),
        "scss": Color(red: 0.85, green: 0.43, blue: 0.67),
        "png": Color.purple,
        "jpg": Color.purple,
        "jpeg": Color.purple,
        "gif": Color.purple,
        "svg": Color.teal,
        "mp4": Color(red: 0.96, green: 0.44, blue: 0.44),
        "mov": Color(red: 0.96, green: 0.44, blue: 0.44),
        "mp3": Color.mint,
        "wav": Color.mint,
        "pdf": Color(red: 0.88, green: 0.22, blue: 0.22),
        "sh": Color(red: 0.36, green: 0.72, blue: 0.36),
        "zip": Color.brown,
    ]

    private static let kindMap: [String: FileKind] = [
        "md": .markdown, "markdown": .markdown,
        "txt": .text, "rtf": .text, "log": .text,
        "json": .json, "yaml": .json, "yml": .json, "toml": .json,
        "swift": .code, "py": .code, "js": .code, "ts": .code,
        "jsx": .code, "tsx": .code, "rs": .code, "go": .code,
        "java": .code, "kt": .code, "cpp": .code, "c": .code,
        "h": .code, "cs": .code, "rb": .code, "php": .code,
        "sh": .code, "bash": .code, "zsh": .code, "fish": .code,
        "html": .code, "htm": .code, "css": .code, "scss": .code,
        "sass": .code, "xml": .code, "csv": .text,
        "png": .image, "jpg": .image, "jpeg": .image, "gif": .image,
        "svg": .image, "webp": .image, "heic": .image, "tiff": .image,
        "mp4": .video, "mov": .video, "avi": .video, "mkv": .video,
        "m4v": .video, "wmv": .video,
        "mp3": .audio, "wav": .audio, "aac": .audio, "flac": .audio, "m4a": .audio,
        "pdf": .pdf,
        "zip": .binary, "tar": .binary, "gz": .binary, "rar": .binary,
        "mw": .markwhen, "markwhen": .markwhen,
        "excalidraw": .excalidraw,
    ]

    private static let languageNames: [String: String] = [
        "swift": "Swift", "py": "Python", "js": "JavaScript",
        "ts": "TypeScript", "jsx": "JSX", "tsx": "TSX",
        "rs": "Rust", "go": "Go", "java": "Java", "kt": "Kotlin",
        "cpp": "C++", "c": "C", "h": "C Header", "cs": "C#",
        "rb": "Ruby", "php": "PHP", "sh": "Shell", "bash": "Bash",
        "zsh": "Zsh", "html": "HTML", "htm": "HTML",
        "css": "CSS", "scss": "SCSS", "sass": "Sass",
        "json": "JSON", "yaml": "YAML", "yml": "YAML",
        "toml": "TOML", "xml": "XML", "csv": "CSV",
        "md": "Markdown", "markdown": "Markdown",
        "txt": "Plain Text", "log": "Log",
        "fish": "Fish",
        "mw": "Markwhen", "markwhen": "Markwhen",
        "excalidraw": "Excalidraw",
    ]

    private static func fallbackIcon(for ext: String) -> String {
        switch ext {
        case "gitignore", "env", "npmrc", "prettierrc", "eslintrc": return "doc.badge.gearshape"
        case "lock": return "lock.doc"
        default: return "doc"
        }
    }
}
