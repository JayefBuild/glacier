// TerminalView.swift
// Full terminal emulator using SwiftTerm (PTY + ANSI/VT220).

import SwiftUI
import SwiftTerm

struct TerminalView: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.appTheme) private var theme

    var body: some View {
        SwiftTermRepresentable(session: session, fontSize: session.fontSize, theme: theme)
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - NSViewControllerRepresentable

struct SwiftTermRepresentable: NSViewControllerRepresentable {
    let session: TerminalSession
    let fontSize: CGFloat
    let theme: any AppTheme

    func makeNSViewController(context: Context) -> TerminalHostController {
        if let cached = TerminalViewCache.shared.get(session.id) {
            return TerminalHostController(terminalView: cached)
        }

        let tv = GuardedTerminalView(frame: .zero)

        let bg = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        let fg = NSColor(white: 0.9, alpha: 1)
        let font = resolvedFont(size: session.fontSize)

        tv.configureNativeColors()
        tv.font = font
        tv.nativeBackgroundColor = bg
        tv.nativeForegroundColor = fg

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cwd = session.workingDirectory.path
        tv.startProcess(executable: shell,
                        args: ["--login", "-i"],
                        environment: buildEnvironment(cwd: cwd),
                        execName: shell,
                        currentDirectory: cwd)

        TerminalViewCache.shared.set(session.id, view: tv)
        return TerminalHostController(terminalView: tv)
    }

    func updateNSViewController(_ nsViewController: TerminalHostController, context: Context) {
        // Apply live font size changes
        guard let tv = TerminalViewCache.shared.get(session.id) else { return }
        let newFont = resolvedFont(size: session.fontSize)
        if tv.font.pointSize != newFont.pointSize {
            tv.font = newFont
        }
    }

    // MARK: - Helpers

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

// MARK: - Host controller

final class TerminalHostController: NSViewController {
    private let terminalView: GuardedTerminalView

    init(terminalView: GuardedTerminalView) {
        self.terminalView = terminalView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = terminalView
    }
}
