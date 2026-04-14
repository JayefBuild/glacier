// TerminalSession.swift
// Lightweight model for a terminal tab. The actual NSView is held in TerminalViewCache.

import Foundation

final class TerminalSession: Identifiable, ObservableObject {
    let id = UUID()
    let workingDirectory: URL
    @Published var title: String
    @Published var fontSize: CGFloat

    init(workingDirectory: URL, fontSize: CGFloat = 15) {
        self.workingDirectory = workingDirectory
        self.title = workingDirectory.lastPathComponent
        self.fontSize = fontSize
    }
}
