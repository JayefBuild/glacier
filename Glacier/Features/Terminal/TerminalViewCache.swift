// TerminalViewCache.swift
// Singleton cache holding strong references to terminal views outside SwiftUI's lifecycle.

import Foundation

/// Keeps GuardedTerminalView instances alive across SwiftUI view re-renders.
/// Without this, SwiftUI can deallocate the NSView when switching tabs.
final class TerminalViewCache: @unchecked Sendable {
    static let shared = TerminalViewCache()

    private var cache: [UUID: GuardedTerminalView] = [:]
    private let lock = NSLock()

    private init() {}

    func get(_ id: UUID) -> GuardedTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    func set(_ id: UUID, view: GuardedTerminalView) {
        lock.lock()
        defer { lock.unlock() }
        cache[id] = view
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: id)
    }
}
