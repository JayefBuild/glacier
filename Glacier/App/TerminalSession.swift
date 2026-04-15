// TerminalSession.swift
// Models terminal tabs and split panes. The actual NSView instances live in TerminalViewCache.

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

enum TerminalTabSplitOrientation {
    case vertical
    case horizontal
}

indirect enum TerminalSplitNode {
    case leaf(UUID)
    case split(
        id: UUID,
        orientation: TerminalTabSplitOrientation,
        fraction: CGFloat,
        first: TerminalSplitNode,
        second: TerminalSplitNode
    )

    var firstLeafID: UUID {
        switch self {
        case .leaf(let id):
            return id
        case .split(_, _, _, let first, _):
            return first.firstLeafID
        }
    }

    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, _, let first, let second):
            return first.leafIDs + second.leafIDs
        }
    }

    func minimumSize(
        minPaneWidth: CGFloat = TerminalPaneLayout.minimumPaneWidth,
        minPaneHeight: CGFloat = TerminalPaneLayout.minimumPaneHeight,
        dividerThickness: CGFloat = TerminalPaneLayout.dividerThickness
    ) -> CGSize {
        switch self {
        case .leaf:
            return CGSize(width: minPaneWidth, height: minPaneHeight)
        case .split(_, let orientation, _, let first, let second):
            let firstSize = first.minimumSize(
                minPaneWidth: minPaneWidth,
                minPaneHeight: minPaneHeight,
                dividerThickness: dividerThickness
            )
            let secondSize = second.minimumSize(
                minPaneWidth: minPaneWidth,
                minPaneHeight: minPaneHeight,
                dividerThickness: dividerThickness
            )

            switch orientation {
            case .vertical:
                return CGSize(
                    width: firstSize.width + dividerThickness + secondSize.width,
                    height: max(firstSize.height, secondSize.height)
                )
            case .horizontal:
                return CGSize(
                    width: max(firstSize.width, secondSize.width),
                    height: firstSize.height + dividerThickness + secondSize.height
                )
            }
        }
    }

    func splitLeaf(_ target: UUID, orientation: TerminalTabSplitOrientation, inserting newLeaf: UUID) -> TerminalSplitNode? {
        switch self {
        case .leaf(let id):
            guard id == target else { return nil }
            return .split(
                id: UUID(),
                orientation: orientation,
                fraction: 0.5,
                first: .leaf(id),
                second: .leaf(newLeaf)
            )
        case .split(let splitID, let currentOrientation, let fraction, let first, let second):
            if let updatedFirst = first.splitLeaf(target, orientation: orientation, inserting: newLeaf) {
                return .split(
                    id: splitID,
                    orientation: currentOrientation,
                    fraction: fraction,
                    first: updatedFirst,
                    second: second
                )
            }

            if let updatedSecond = second.splitLeaf(target, orientation: orientation, inserting: newLeaf) {
                return .split(
                    id: splitID,
                    orientation: currentOrientation,
                    fraction: fraction,
                    first: first,
                    second: updatedSecond
                )
            }

            return nil
        }
    }

    func updatingFraction(_ targetSplitID: UUID, to newFraction: CGFloat) -> TerminalSplitNode? {
        switch self {
        case .leaf:
            return nil
        case .split(let splitID, let orientation, let fraction, let first, let second):
            if splitID == targetSplitID {
                return .split(
                    id: splitID,
                    orientation: orientation,
                    fraction: newFraction,
                    first: first,
                    second: second
                )
            }

            if let updatedFirst = first.updatingFraction(targetSplitID, to: newFraction) {
                return .split(
                    id: splitID,
                    orientation: orientation,
                    fraction: fraction,
                    first: updatedFirst,
                    second: second
                )
            }

            if let updatedSecond = second.updatingFraction(targetSplitID, to: newFraction) {
                return .split(
                    id: splitID,
                    orientation: orientation,
                    fraction: fraction,
                    first: first,
                    second: updatedSecond
                )
            }

            return nil
        }
    }

    func removingLeaf(_ target: UUID) -> (node: TerminalSplitNode?, fallbackFocusID: UUID?, removed: Bool) {
        switch self {
        case .leaf(let id):
            guard id == target else { return (self, nil, false) }
            return (nil, nil, true)
        case .split(let splitID, let orientation, let fraction, let first, let second):
            let firstRemoval = first.removingLeaf(target)
            if firstRemoval.removed {
                if let updatedFirst = firstRemoval.node {
                    let updated = TerminalSplitNode.split(
                        id: splitID,
                        orientation: orientation,
                        fraction: fraction,
                        first: updatedFirst,
                        second: second
                    )
                    return (updated, firstRemoval.fallbackFocusID ?? updatedFirst.firstLeafID, true)
                }

                return (second, second.firstLeafID, true)
            }

            let secondRemoval = second.removingLeaf(target)
            if secondRemoval.removed {
                if let updatedSecond = secondRemoval.node {
                    let updated = TerminalSplitNode.split(
                        id: splitID,
                        orientation: orientation,
                        fraction: fraction,
                        first: first,
                        second: updatedSecond
                    )
                    return (updated, secondRemoval.fallbackFocusID ?? updatedSecond.firstLeafID, true)
                }

                return (first, first.firstLeafID, true)
            }

            return (self, nil, false)
        }
    }
}

private enum TerminalPaneLayout {
    static let minimumPaneWidth: CGFloat = 220
    static let minimumPaneHeight: CGFloat = 140
    static let dividerThickness: CGFloat = 8
}

struct TerminalTabCloseResult {
    let removedSessionID: UUID
    let replacementSessionID: UUID?

    var shouldCloseTab: Bool {
        replacementSessionID == nil
    }
}

@MainActor
final class TerminalTabState: Identifiable, ObservableObject {
    let id = UUID()
    private var sessions: [UUID: TerminalSession]

    @Published var title: String
    @Published private(set) var root: TerminalSplitNode
    @Published private(set) var focusedSessionID: UUID

    init(workingDirectory: URL, fontSize: CGFloat = 15) {
        let session = TerminalSession(workingDirectory: workingDirectory, fontSize: fontSize)
        self.sessions = [session.id: session]
        self.title = workingDirectory.lastPathComponent
        self.root = .leaf(session.id)
        self.focusedSessionID = session.id
    }

    var allSessionIDs: [UUID] {
        root.leafIDs
    }

    var sessionCount: Int {
        allSessionIDs.count
    }

    func session(for id: UUID) -> TerminalSession? {
        sessions[id]
    }

    func focusSession(_ id: UUID) {
        guard sessions[id] != nil else { return }
        focusedSessionID = id
    }

    func splitFocusedSession(_ orientation: TerminalTabSplitOrientation) -> TerminalSession? {
        splitSession(focusedSessionID, orientation: orientation)
    }

    func splitSession(_ id: UUID, orientation: TerminalTabSplitOrientation) -> TerminalSession? {
        guard let source = sessions[id] else { return nil }

        let newSession = TerminalSession(
            workingDirectory: source.workingDirectory,
            fontSize: source.fontSize
        )

        guard let updatedRoot = root.splitLeaf(id, orientation: orientation, inserting: newSession.id) else {
            return nil
        }

        sessions[newSession.id] = newSession
        root = updatedRoot
        focusedSessionID = newSession.id
        return newSession
    }

    func closeFocusedSession() -> TerminalTabCloseResult? {
        closeSession(focusedSessionID)
    }

    func closeSession(_ id: UUID) -> TerminalTabCloseResult? {
        guard sessions[id] != nil else { return nil }

        let removal = root.removingLeaf(id)
        guard removal.removed else { return nil }

        sessions.removeValue(forKey: id)

        if let updatedRoot = removal.node {
            root = updatedRoot
            focusedSessionID = removal.fallbackFocusID ?? updatedRoot.firstLeafID
            return TerminalTabCloseResult(
                removedSessionID: id,
                replacementSessionID: focusedSessionID
            )
        }

        return TerminalTabCloseResult(
            removedSessionID: id,
            replacementSessionID: nil
        )
    }

    func adjustFontSize(by delta: CGFloat) {
        for session in sessions.values {
            session.fontSize = max(8, min(36, session.fontSize + delta))
        }
    }

    func resetFontSize(to size: CGFloat) {
        for session in sessions.values {
            session.fontSize = size
        }
    }

    func updateSplitFraction(_ splitID: UUID, to fraction: CGFloat) {
        let clampedFraction = max(0.1, min(0.9, fraction))
        guard let updatedRoot = root.updatingFraction(splitID, to: clampedFraction) else { return }
        root = updatedRoot
    }
}
