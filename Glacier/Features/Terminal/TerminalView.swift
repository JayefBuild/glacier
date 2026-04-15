// TerminalView.swift
// Full terminal emulator using SwiftTerm (PTY + ANSI/VT220).

import SwiftUI
import AppKit
import SwiftTerm

enum TerminalShortcutCommand: Equatable {
    case newTerminalTab
    case closeTerminal
    case splitTerminalVertical
    case splitTerminalHorizontal
    case splitEditorRight
    case splitEditorDown
    case closeEditorSplit
}

struct TerminalTabView: View {
    @ObservedObject var terminal: TerminalTabState
    let isFocused: Bool
    let onSessionInteraction: (UUID) -> Void
    let onSessionCommand: (UUID, TerminalShortcutCommand) -> Void

    var body: some View {
        TerminalSplitNodeView(
            terminal: terminal,
            node: terminal.root,
            isTabFocused: isFocused,
            onSessionInteraction: onSessionInteraction,
            onSessionCommand: onSessionCommand
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalSplitNodeView: View {
    @ObservedObject var terminal: TerminalTabState
    let node: TerminalSplitNode
    let isTabFocused: Bool
    let onSessionInteraction: (UUID) -> Void
    let onSessionCommand: (UUID, TerminalShortcutCommand) -> Void

    var body: some View {
        switch node {
        case .leaf(let sessionID):
            if let session = terminal.session(for: sessionID) {
                TerminalPaneView(
                    session: session,
                    isFocused: isTabFocused && terminal.focusedSessionID == sessionID,
                    onInteraction: { onSessionInteraction(sessionID) },
                    onCommand: { command in
                        onSessionCommand(sessionID, command)
                    }
                )
            } else {
                Color.clear
            }
        case .split(let splitID, let orientation, let fraction, let first, let second):
            TerminalSplitContainerView(
                terminal: terminal,
                splitID: splitID,
                orientation: orientation,
                fraction: fraction,
                first: first,
                second: second,
                isTabFocused: isTabFocused,
                onSessionInteraction: onSessionInteraction,
                onSessionCommand: onSessionCommand
            )
        }
    }
}

private struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    let isFocused: Bool
    let onInteraction: () -> Void
    let onCommand: (TerminalShortcutCommand) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        TerminalView(
            session: session,
            isFocused: isFocused,
            onInteraction: onInteraction,
            onCommand: onCommand
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.terminalBackground.opacity(0.28))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? theme.colors.glassBorder.opacity(0.9)
                        : theme.colors.glassBorder.opacity(0.18),
                    lineWidth: isFocused ? 1 : 0.5
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TerminalSplitContainerView: View {
    @ObservedObject var terminal: TerminalTabState
    let splitID: UUID
    let orientation: TerminalTabSplitOrientation
    let fraction: CGFloat
    let first: TerminalSplitNode
    let second: TerminalSplitNode
    let isTabFocused: Bool
    let onSessionInteraction: (UUID) -> Void
    let onSessionCommand: (UUID, TerminalShortcutCommand) -> Void
    @Environment(\.appTheme) private var theme
    @State private var dragStartFraction: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let layout = resolvedLayout(in: geometry.size)

            Group {
                switch orientation {
                case .vertical:
                    HStack(spacing: 0) {
                        childView(for: first)
                            .frame(width: layout.firstLength, height: geometry.size.height)

                        divider
                            .frame(width: TerminalSplitLayout.dividerThickness, height: geometry.size.height)
                            .gesture(dragGesture(in: geometry.size, startFraction: layout.fraction))

                        childView(for: second)
                            .frame(width: layout.secondLength, height: geometry.size.height)
                    }
                case .horizontal:
                    VStack(spacing: 0) {
                        childView(for: first)
                            .frame(width: geometry.size.width, height: layout.firstLength)

                        divider
                            .frame(width: geometry.size.width, height: TerminalSplitLayout.dividerThickness)
                            .gesture(dragGesture(in: geometry.size, startFraction: layout.fraction))

                        childView(for: second)
                            .frame(width: geometry.size.width, height: layout.secondLength)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var divider: some View {
        ZStack {
            Rectangle()
                .fill(.clear)

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(theme.colors.glassBorder.opacity(0.5))
                .frame(
                    width: orientation == .vertical ? 2 : nil,
                    height: orientation == .horizontal ? 2 : nil
                )
        }
        .contentShape(Rectangle())
    }

    private func childView(for node: TerminalSplitNode) -> some View {
        TerminalSplitNodeView(
            terminal: terminal,
            node: node,
            isTabFocused: isTabFocused,
            onSessionInteraction: onSessionInteraction,
            onSessionCommand: onSessionCommand
        )
    }

    private func dragGesture(in size: CGSize, startFraction: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartFraction == nil {
                    dragStartFraction = startFraction
                }

                let baseFraction = dragStartFraction ?? startFraction
                let delta = orientation == .vertical ? value.translation.width : value.translation.height
                let axisLength = max(1, (orientation == .vertical ? size.width : size.height) - TerminalSplitLayout.dividerThickness)
                let proposedFraction = baseFraction + (delta / axisLength)
                terminal.updateSplitFraction(splitID, to: clampedFraction(proposedFraction, in: size))
            }
            .onEnded { _ in
                dragStartFraction = nil
            }
    }

    private func resolvedLayout(in size: CGSize) -> TerminalSplitResolvedLayout {
        let axisLength = orientation == .vertical ? size.width : size.height
        let usableLength = max(0, axisLength - TerminalSplitLayout.dividerThickness)
        let clamped = clampedFraction(fraction, in: size)
        let firstLength = usableLength * clamped
        return TerminalSplitResolvedLayout(
            fraction: clamped,
            firstLength: firstLength,
            secondLength: max(0, usableLength - firstLength)
        )
    }

    private func clampedFraction(_ proposedFraction: CGFloat, in size: CGSize) -> CGFloat {
        let usableLength = max(0, (orientation == .vertical ? size.width : size.height) - TerminalSplitLayout.dividerThickness)
        guard usableLength > 0 else { return 0.5 }

        let firstMinimumSize = first.minimumSize()
        let secondMinimumSize = second.minimumSize()
        let firstMinimumLength = orientation == .vertical ? firstMinimumSize.width : firstMinimumSize.height
        let secondMinimumLength = orientation == .vertical ? secondMinimumSize.width : secondMinimumSize.height
        let minimumFraction = min(1, firstMinimumLength / usableLength)
        let maximumFraction = max(0, 1 - (secondMinimumLength / usableLength))

        if minimumFraction <= maximumFraction {
            return min(max(proposedFraction, minimumFraction), maximumFraction)
        }

        return min(max(proposedFraction, 0.2), 0.8)
    }
}

private struct TerminalSplitResolvedLayout {
    let fraction: CGFloat
    let firstLength: CGFloat
    let secondLength: CGFloat
}

private enum TerminalSplitLayout {
    static let dividerThickness: CGFloat = 8
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

        let appearance = TerminalAppearance.current
        let newFont = resolvedFont(size: fontSize, appearance: appearance)
        if terminalView.font.pointSize != newFont.pointSize || terminalView.font.fontName != newFont.fontName {
            terminalView.font = newFont
        }

        terminalView.needsDisplay = true
        terminalView.setFocused(isFocused)
    }

    private func cachedOrCreateTerminalView() -> GuardedTerminalView {
        if let cached = TerminalViewCache.shared.get(session.id) {
            cached.removeFromSuperview()
            cached.debugName = session.id.uuidString
            applyAppearance(to: cached, fontSize: fontSize)
            return cached
        }

        let terminalView = GuardedTerminalView(frame: .zero)
        terminalView.debugName = session.id.uuidString
        applyAppearance(to: terminalView, fontSize: fontSize)

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

    private func applyAppearance(to terminalView: GuardedTerminalView, fontSize: CGFloat) {
        let appearance = TerminalAppearance.current
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalView.font = resolvedFont(size: fontSize, appearance: appearance)
        terminalView.useBrightColors = appearance.useBrightColors
        terminalView.nativeBackgroundColor = appearance.backgroundColor.withAlphaComponent(0.88)
        terminalView.nativeForegroundColor = appearance.foregroundColor
        terminalView.selectedTextBackgroundColor = appearance.selectionColor
        terminalView.caretColor = appearance.cursorColor
        terminalView.caretTextColor = appearance.cursorTextColor
        terminalView.getTerminal().ansi256PaletteStrategy = .xterm
        terminalView.installColors(appearance.swiftTermPalette)
    }

    private func resolvedFont(size: CGFloat, appearance: TerminalAppearance) -> NSFont {
        if let fontName = appearance.fontName,
           let font = NSFont(name: fontName, size: size) {
            return font
        }

        return NSFont(name: theme.typography.terminalFontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func buildEnvironment(cwd: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "NO_COLOR")
        env["PWD"] = cwd
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["CLICOLOR"] = env["CLICOLOR"] ?? "1"
        // Some CLIs gate richer styling and hyperlinks on iTerm-compatible identity hints.
        env["TERM_PROGRAM"] = env["TERM_PROGRAM"] ?? "iTerm.app"
        env["LC_TERMINAL"] = env["LC_TERMINAL"] ?? "iTerm2"
        if let terminalVersion = env["TERM_PROGRAM_VERSION"] ?? env["LC_TERMINAL_VERSION"] {
            env["TERM_PROGRAM_VERSION"] = terminalVersion
            env["LC_TERMINAL_VERSION"] = terminalVersion
        }
        env["HOME"] = NSHomeDirectory()
        env["SHELL"] = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return env.map { "\($0.key)=\($0.value)" }
    }
}

struct TerminalAppearance {
    let ansiPalette: [NSColor]
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let cursorColor: NSColor
    let cursorTextColor: NSColor?
    let selectionColor: NSColor
    let fontName: String?
    let defaultFontSize: CGFloat?
    let useBrightColors: Bool

    static let current = resolve()

    var swiftTermPalette: [SwiftTerm.Color] {
        ansiPalette.map(\.swiftTermColor)
    }

    private static func resolve() -> TerminalAppearance {
        guard let profile = ITermPreferences.defaultProfile() else {
            return fallback
        }

        let fallback = fallback
        let ansiPalette = (0..<16).map { index in
            ITermPreferences.color(forKey: "Ansi \(index) Color", in: profile) ?? fallback.ansiPalette[index]
        }

        let parsedFont = ITermPreferences.font(in: profile)

        return TerminalAppearance(
            ansiPalette: ansiPalette,
            backgroundColor: ITermPreferences.color(forKey: "Background Color", in: profile) ?? fallback.backgroundColor,
            foregroundColor: ITermPreferences.color(forKey: "Foreground Color", in: profile) ?? fallback.foregroundColor,
            cursorColor: ITermPreferences.color(forKey: "Cursor Color", in: profile) ?? fallback.cursorColor,
            cursorTextColor: ITermPreferences.color(forKey: "Cursor Text Color", in: profile) ?? fallback.cursorTextColor,
            selectionColor: ITermPreferences.color(forKey: "Selection Color", in: profile) ?? fallback.selectionColor,
            fontName: parsedFont?.name ?? fallback.fontName,
            defaultFontSize: parsedFont?.size ?? fallback.defaultFontSize,
            useBrightColors: ITermPreferences.bool(forKey: "Use Bright Bold", in: profile) ?? fallback.useBrightColors
        )
    }

    private static let fallback = TerminalAppearance(
        ansiPalette: [
            NSColor(hexRed: 0x00, green: 0x00, blue: 0x00),
            NSColor(hexRed: 0xEA, green: 0x40, blue: 0x25),
            NSColor(hexRed: 0x00, green: 0xBB, blue: 0x00),
            NSColor(hexRed: 0xBB, green: 0xBB, blue: 0x00),
            NSColor(hexRed: 0x00, green: 0x9A, blue: 0xF1),
            NSColor(hexRed: 0xBB, green: 0x00, blue: 0xBB),
            NSColor(hexRed: 0x00, green: 0xBB, blue: 0xBB),
            NSColor(hexRed: 0xBB, green: 0xBB, blue: 0xBB),
            NSColor(hexRed: 0x55, green: 0x55, blue: 0x55),
            NSColor(hexRed: 0xEA, green: 0x40, blue: 0x24),
            NSColor(hexRed: 0x55, green: 0xFF, blue: 0x55),
            NSColor(hexRed: 0xFF, green: 0xFF, blue: 0x55),
            NSColor(hexRed: 0x55, green: 0x55, blue: 0xFF),
            NSColor(hexRed: 0xFF, green: 0x55, blue: 0xFF),
            NSColor(hexRed: 0x55, green: 0xFF, blue: 0xFF),
            NSColor(hexRed: 0xFF, green: 0xFF, blue: 0xFF)
        ],
        backgroundColor: NSColor(hexRed: 0x17, green: 0x17, blue: 0x17),
        foregroundColor: NSColor(hexRed: 0xBB, green: 0xBB, blue: 0xBB),
        cursorColor: NSColor(hexRed: 0xBB, green: 0xBB, blue: 0xBB),
        cursorTextColor: NSColor.white,
        selectionColor: NSColor(hexRed: 0xB5, green: 0xD5, blue: 0xFF),
        fontName: "Monaco",
        defaultFontSize: 16,
        useBrightColors: true
    )
}

private enum ITermPreferences {
    private static let suiteName = "com.googlecode.iterm2"

    static func defaultProfile() -> [String: Any]? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let profiles = defaults.array(forKey: "New Bookmarks") as? [[String: Any]],
              !profiles.isEmpty else {
            return nil
        }

        if let defaultGuid = defaults.string(forKey: "Default Bookmark Guid"),
           let profile = profiles.first(where: { ($0["Guid"] as? String) == defaultGuid }) {
            return profile
        }

        if let profile = profiles.first(where: { bool(forKey: "Default Bookmark", in: $0) == true }) {
            return profile
        }

        if let profile = profiles.first(where: { ($0["Name"] as? String) == "Default" || ($0["Description"] as? String) == "Default" }) {
            return profile
        }

        return profiles.first
    }

    static func color(forKey key: String, in profile: [String: Any]) -> NSColor? {
        guard let raw = profile[key] as? [String: Any] else {
            return nil
        }

        let red = double(from: raw["Red Component"])
        let green = double(from: raw["Green Component"])
        let blue = double(from: raw["Blue Component"])
        let alpha = double(from: raw["Alpha Component"]) ?? 1

        guard let red, let green, let blue else {
            return nil
        }

        switch (raw["Color Space"] as? String)?.lowercased() {
        case "p3":
            return NSColor(displayP3Red: red, green: green, blue: blue, alpha: alpha)
        case "srgb":
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        default:
            return NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    static func font(in profile: [String: Any]) -> (name: String, size: CGFloat)? {
        guard let raw = profile["Normal Font"] as? String else {
            return nil
        }

        let pieces = raw.split(separator: " ")
        guard let last = pieces.last,
              let size = Double(last),
              pieces.count > 1 else {
            return nil
        }

        let name = pieces.dropLast().joined(separator: " ")
        guard !name.isEmpty else {
            return nil
        }

        return (name, CGFloat(size))
    }

    static func bool(forKey key: String, in profile: [String: Any]) -> Bool? {
        if let value = profile[key] as? Bool {
            return value
        }
        if let number = profile[key] as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private static func double(from value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(number.doubleValue)
        case let string as String:
            guard let double = Double(string) else {
                return nil
            }
            return CGFloat(double)
        default:
            return nil
        }
    }
}

private extension NSColor {
    convenience init(hexRed red: UInt8, green: UInt8, blue: UInt8, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: alpha
        )
    }

    var swiftTermColor: SwiftTerm.Color {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        return SwiftTerm.Color(
            red: rgb.swiftTermComponent(rgb.redComponent),
            green: rgb.swiftTermComponent(rgb.greenComponent),
            blue: rgb.swiftTermComponent(rgb.blueComponent)
        )
    }

    private func swiftTermComponent(_ component: CGFloat) -> UInt16 {
        UInt16(max(0, min(65535, Int((component * 65535).rounded()))))
    }
}
