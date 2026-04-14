// TerminalView.swift
// Full terminal emulator using SwiftTerm (PTY + ANSI/VT220).

import SwiftUI
import SwiftTerm

enum TerminalShortcutCommand {
    case newTerminalTab
    case closeTab
    case splitRight
    case splitDown
    case closeSplit
}

struct TerminalView: View {
    @ObservedObject var session: TerminalSession
    let isFocused: Bool
    let onInteraction: () -> Void
    let onCommand: (TerminalShortcutCommand) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        SwiftTermRepresentable(
            session: session,
            fontSize: session.fontSize,
            theme: theme,
            isFocused: isFocused,
            onInteraction: onInteraction,
            onCommand: onCommand
        )
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - NSViewRepresentable

struct SwiftTermRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let fontSize: CGFloat
    let theme: any AppTheme
    let isFocused: Bool
    let onInteraction: () -> Void
    let onCommand: (TerminalShortcutCommand) -> Void

    func makeNSView(context: Context) -> GuardedTerminalView {
        let terminalView = cachedOrCreateTerminalView()
        terminalView.onInteraction = onInteraction
        terminalView.onCommand = onCommand
        return terminalView
    }

    func updateNSView(_ terminalView: GuardedTerminalView, context: Context) {
        terminalView.onInteraction = onInteraction
        terminalView.onCommand = onCommand

        let newFont = resolvedFont(size: fontSize)
        if terminalView.font.pointSize != newFont.pointSize {
            terminalView.font = newFont
        }

        terminalView.needsDisplay = true
        terminalView.setFocused(isFocused)
    }

    private func cachedOrCreateTerminalView() -> GuardedTerminalView {
        if let cached = TerminalViewCache.shared.get(session.id) {
            cached.removeFromSuperview()
            cached.debugName = session.id.uuidString
            return cached
        }

        let terminalView = GuardedTerminalView(frame: .zero)
        terminalView.debugName = session.id.uuidString
        terminalView.configureNativeColors()
        terminalView.font = resolvedFont(size: fontSize)
        terminalView.nativeBackgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cwd = session.workingDirectory.path
        terminalView.startProcess(
            executable: shell,
            args: ["--login", "-i"],
            environment: buildEnvironment(cwd: cwd),
            execName: shell,
            currentDirectory: cwd
        )

        TerminalViewCache.shared.set(session.id, view: terminalView)
        return terminalView
    }

    private func resolvedFont(size: CGFloat) -> NSFont {
        NSFont(name: theme.typography.terminalFontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func buildEnvironment(cwd: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["PWD"] = cwd
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["HOME"] = NSHomeDirectory()
        env["SHELL"] = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return env.map { "\($0.key)=\($0.value)" }
    }
}
