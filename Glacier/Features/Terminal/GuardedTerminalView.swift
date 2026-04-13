// GuardedTerminalView.swift
// Subclass that prevents PTY death from zero-size frame updates.

import SwiftTerm
import AppKit

/// LocalProcessTerminalView subclass that guards against zero-size frame updates.
/// When SwiftUI removes a view from the hierarchy it sends setFrameSize(.zero),
/// which propagates through SwiftTerm as TIOCSWINSZ with 0 rows/cols — killing the PTY.
final class GuardedTerminalView: LocalProcessTerminalView {

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
}
