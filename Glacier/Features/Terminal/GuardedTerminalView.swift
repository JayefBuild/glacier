// GuardedTerminalView.swift
// Subclass that prevents PTY death from zero-size frame updates.

import SwiftTerm
import AppKit

/// LocalProcessTerminalView subclass that guards against zero-size frame updates.
/// When SwiftUI removes a view from the hierarchy it sends setFrameSize(.zero),
/// which propagates through SwiftTerm as TIOCSWINSZ with 0 rows/cols — killing the PTY.
@MainActor
final class GuardedTerminalView: LocalProcessTerminalView {
    private let focusDebugLoggingEnabled = ProcessInfo.processInfo.environment["GLACIER_DEBUG_FOCUS"] == "1"
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    var debugName = ""
    var onInteraction: (() -> Void)?
    var onCommand: ((TerminalShortcutCommand) -> Void)?
    private var interactionMonitor: EventMonitor?
    private var keyMonitor: EventMonitor?
    private var shouldRestoreFocus = false

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != .zero else { return }
        super.setFrameSize(newSize)
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            guard newValue.size != .zero else { return }
            super.frame = newValue
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installInteractionMonitorIfNeeded()
        restoreFocusIfNeeded()
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityLabel() -> String? {
        "Terminal"
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard handleShortcutIfNeeded(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func setFocused(_ isFocused: Bool) {
        shouldRestoreFocus = isFocused
        guard isFocused else { return }
        restoreFocusIfNeeded()
    }

    func focusNow() {
        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus focusNow session=\(debugName)")
        }
        shouldRestoreFocus = true
        restoreFocusIfNeeded()
    }

    private func installInteractionMonitorIfNeeded() {
        guard interactionMonitor == nil else { return }

        let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else {
                return event
            }

            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            if self.focusDebugLoggingEnabled {
                focusDebugLog("GlacierFocus click session=\(self.debugName)")
            }
            window.makeFirstResponder(self)
            self.shouldRestoreFocus = true
            self.onInteraction?()
            return event
        }

        guard let token else {
            return
        }

        interactionMonitor = EventMonitor(token: token)

        let keyToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  window.firstResponder === self else {
                return event
            }

            if self.handleLineFeedOverrideIfNeeded(event) {
                return nil
            }

            return self.handleShortcutIfNeeded(event) ? nil : event
        }

        if let keyToken {
            keyMonitor = EventMonitor(token: keyToken)
        }
    }

    private func restoreFocusIfNeeded(attempt: Int = 0) {
        guard shouldRestoreFocus else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard let window = self.window else {
                guard attempt < 6 else { return }
                self.restoreFocusIfNeeded(attempt: attempt + 1)
                return
            }

            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }

            if self.focusDebugLoggingEnabled {
                focusDebugLog("GlacierFocus restored session=\(self.debugName) firstResponder=\(window.firstResponder === self)")
            }
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }

    private func handleShortcutIfNeeded(_ event: NSEvent) -> Bool {
        guard let command = shortcutCommand(for: event) else {
            logUnhandledShortcut(event)
            return false
        }

        if focusDebugLoggingEnabled {
            focusDebugLog("GlacierFocus shortcut session=\(debugName) command=\(command)")
        }

        onInteraction?()
        onCommand?(command)
        return true
    }

    private func shortcutCommand(for event: NSEvent) -> TerminalShortcutCommand? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = modifiers.contains(.command)
        let hasOption = modifiers.contains(.option)
        let hasControl = modifiers.contains(.control)
        let hasShift = modifiers.contains(.shift)

        if hasCommand && !hasOption && !hasControl,
           let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "t":
                return hasShift ? nil : .newTerminalTab
            case "w":
                return hasShift ? nil : .closeTerminal
            case "d":
                return hasShift ? .splitTerminalHorizontal : .splitTerminalVertical
            default:
                break
            }
        }

        if hasCommand && hasOption {
            switch event.keyCode {
            case 124:
                return .splitEditorRight
            case 125:
                return .splitEditorDown
            default:
                break
            }

            if let specialKey = event.specialKey {
                switch specialKey {
                case .rightArrow:
                    return .splitEditorRight
                case .downArrow:
                    return .splitEditorDown
                default:
                    break
                }
            }

            if event.charactersIgnoringModifiers == "\\" {
                return .closeEditorSplit
            }
        }

        return nil
    }

    private func shouldSendLineFeedForShiftReturn(_ event: NSEvent) -> Bool {
        guard Self.returnKeyCodes.contains(event.keyCode) else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.shift) else { return false }
        guard !modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              !modifiers.contains(.function) else {
            return false
        }

        return true
    }

    private func handleLineFeedOverrideIfNeeded(_ event: NSEvent) -> Bool {
        guard shouldSendLineFeedForShiftReturn(event) else { return false }
        send(EscapeSequences.cmdNewLine)
        return true
    }

    private func logUnhandledShortcut(_ event: NSEvent) {
        guard focusDebugLoggingEnabled else { return }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return }

        let chars = event.characters ?? "nil"
        let ignoring = event.charactersIgnoringModifiers ?? "nil"
        focusDebugLog(
            "GlacierFocus unhandledShortcut session=\(debugName) keyCode=\(event.keyCode) modifiers=\(modifiers.rawValue) chars=\(chars) ignoring=\(ignoring)"
        )
    }
}

private final class EventMonitor {
    private let token: Any

    init(token: Any) {
        self.token = token
    }

    deinit {
        NSEvent.removeMonitor(token)
    }
}
