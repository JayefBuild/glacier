import AppKit

enum CloseProtectionTarget {
    case terminal
    case project
    case application

    var title: String {
        switch self {
        case .terminal, .project:
            return "Are you sure you want to close?"
        case .application:
            return "Are you sure you want to quit Glacier?"
        }
    }

    var destructiveButtonTitle: String {
        switch self {
        case .terminal:
            return "Close Terminal"
        case .project:
            return "Close Project"
        case .application:
            return "Quit Glacier"
        }
    }

    func informativeText(processCount: Int) -> String {
        let sessionText = processCount == 1 ? "an open terminal session" : "\(processCount) open terminal sessions"
        let terminationText = processCount == 1 ? "it" : "them"

        switch self {
        case .terminal:
            return "You have \(sessionText). Closing this terminal will terminate \(terminationText)."
        case .project:
            return "You have \(sessionText). Closing this project will terminate \(terminationText)."
        case .application:
            return "You have \(sessionText). Quitting Glacier will terminate \(terminationText)."
        }
    }
}

@MainActor
func confirmProtectedClose(_ target: CloseProtectionTarget, processCount: Int) -> Bool {
    guard processCount > 0 else { return true }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = target.title
    alert.informativeText = target.informativeText(processCount: processCount)
    alert.addButton(withTitle: target.destructiveButtonTitle)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
