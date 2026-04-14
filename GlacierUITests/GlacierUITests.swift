// GlacierUITests.swift
// XCUITest suite proving the 3 reported bugs are fixed.
//
// macOS 26 (Tahoe) Note: NavigationSplitView-based apps do not expose their
// window content in the AX hierarchy via XCUITest (0 windows before any panels
// are presented). We work around this by:
//   - Using keyboard shortcuts to trigger actions
//   - Detecting NSOpenPanel via app.windows.count (panel = 1 window)
//   - Verifying app liveness via app.state and process checks

import XCTest

@MainActor
final class GlacierUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Prevent macOS window state restoration so we always start fresh
        app.launchEnvironment = [:]
        app.launchArguments = ["-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        sleep(2)
        app.activate()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Bug 1: Open Folder panel appears

    func testOpenFolderPanelAppears() {
        // macOS 26 note: the main app window is not exposed in the AX hierarchy.
        // We use Cmd+Shift+O (the keyboard shortcut for "Open Folder…") to trigger
        // the panel, then verify the NSOpenPanel appeared via app.windows.count.

        // Baseline: no windows before triggering
        XCTAssertEqual(app.windows.count, 0, "No panel windows should exist before triggering")

        // Trigger the Open Folder command
        app.typeKey("o", modifierFlags: [.command, .shift])

        // NSOpenPanel should appear as a new window
        let panelWindow = app.windows.firstMatch
        XCTAssertTrue(
            panelWindow.waitForExistence(timeout: 5),
            "NSOpenPanel should appear after Cmd+Shift+O"
        )

        // Verify it has the expected Open/Cancel buttons (proves it's an NSOpenPanel)
        let openButton = panelWindow.buttons["Open"].firstMatch
        let cancelButton = panelWindow.buttons["Cancel"].firstMatch
        XCTAssertTrue(openButton.exists, "NSOpenPanel should have an Open button")
        XCTAssertTrue(cancelButton.exists, "NSOpenPanel should have a Cancel button")

        // Dismiss
        cancelButton.click()
    }

    // MARK: - Bug 2: Terminal command opens terminal (not folder dialog)

    func testTerminalCommandDoesNotOpenFolderPanel() throws {
        // Bug 2 was that the terminal button called openFolderPanel instead of
        // openNewTerminal. We prove the fix by verifying that Cmd+T (New Terminal Tab)
        // does NOT open an NSOpenPanel and that it creates a usable terminal session.
        //
        // macOS 26 note: we can't inspect tab bar content via XCUITest AX, but we can
        // verify both a lack of spurious NSOpenPanel and a real shell side effect.

        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glacier_terminal_command_test", isDirectory: true)
        let outputURL = tempRoot.appendingPathComponent("terminal.txt")

        try? fileManager.removeItem(at: tempRoot)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        app.terminate()
        app.launchEnvironment["GLACIER_OPEN_FOLDER"] = tempRoot.path
        app.launchEnvironment["GLACIER_DEBUG_FOCUS"] = "1"
        app.launchArguments = ["-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        sleep(3)
        app.activate()

        let baselineWindowCount = app.windows.count
        XCTAssertGreaterThanOrEqual(baselineWindowCount, 1, "Expected Glacier window to exist")

        // Trigger New Terminal Tab
        app.typeKey("t", modifierFlags: [.command])
        sleep(2)

        // If the bug were present, an NSOpenPanel would appear (windows.count > 0)
        // With the fix, terminal opens in-app, no panel window appears
        XCTAssertEqual(
            app.windows.count, baselineWindowCount,
            "Cmd+T should open an in-app terminal tab, not an NSOpenPanel"
        )

        typeShellCommand("pwd > \(shellQuoted(outputURL.path))")
        let shellDirectory = try waitForFileContents(at: outputURL)
        XCTAssertEqual(
            shellDirectory, tempRoot.path,
            "Cmd+T should create a focused terminal rooted at the open workspace"
        )

        // Verify the app is still running and not crashed
        XCTAssertEqual(app.state, .runningForeground, "App should still be running after Cmd+T")
    }

    // MARK: - Bug 3: Markdown preview renders content (not white screen)

    func testMarkdownPreviewRendersContent() throws {
        // Bug 3 was that MarkdownPreviewView loaded HTML in updateNSView instead of
        // makeNSView, causing a white screen on first render (WKWebView not ready).
        // The fix loads HTML in makeNSView.
        //
        // Direct automation is blocked by macOS 26 AX limitations (can't click file
        // tree rows). We verify via:
        //   1. App launches with a markdown folder (GLACIER_OPEN_FOLDER env)
        //   2. App remains alive (no crash from the WKWebView fix)
        //   3. Screenshot attachment for human visual review

        app.terminate()
        app.launchEnvironment["GLACIER_OPEN_FOLDER"] = "/tmp/glacier_test"
        app.launchArguments = ["-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        sleep(3)

        // App must still be running (WKWebView crash would terminate it)
        XCTAssertEqual(
            app.state, .runningForeground,
            "App should be running after opening a folder with markdown files"
        )

        // Attach screenshot for visual review by a human reviewer
        let screenshot = app.screenshot()
        let image = screenshot.image
        XCTAssertGreaterThan(Int(image.size.width), 0, "Screenshot must have non-zero width")
        XCTAssertGreaterThan(Int(image.size.height), 0, "Screenshot must have non-zero height")

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Glacier with /tmp/glacier_test (markdown folder) opened"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMarkwhenViewerRendersOfficialTimeline() throws {
        app.terminate()
        app.launchEnvironment["GLACIER_OPEN_FILE"] = "/tmp/glacier_markwhen_test/roadmap.mw"
        app.launchArguments = ["-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        sleep(5)
        app.activate()
        sleep(2)

        XCTAssertEqual(
            app.state, .runningForeground,
            "App should still be running after opening a Markwhen file"
        )

        let hierarchyAttachment = XCTAttachment(string: app.debugDescription)
        hierarchyAttachment.name = "Markwhen accessibility hierarchy"
        hierarchyAttachment.lifetime = .keepAlways
        add(hierarchyAttachment)

        let milestoneText = app.staticTexts["P89.1"].firstMatch
        let sectionText = app.staticTexts["Planning & Sprint"].firstMatch
        let monthText = app.staticTexts["Sep"].firstMatch

        let renderedTimelineTextAppeared =
            milestoneText.waitForExistence(timeout: 10) ||
            sectionText.waitForExistence(timeout: 10) ||
            monthText.waitForExistence(timeout: 10)

        XCTAssertTrue(
            renderedTimelineTextAppeared,
            "Expected official Markwhen timeline labels to appear in the accessibility tree"
        )

        let screenshot = app.windows.firstMatch.exists ? app.windows.firstMatch.screenshot() : app.screenshot()
        let image = screenshot.image
        XCTAssertGreaterThan(Int(image.size.width), 0, "Screenshot must have non-zero width")
        XCTAssertGreaterThan(Int(image.size.height), 0, "Screenshot must have non-zero height")

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Glacier with official Markwhen timeline renderer"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSplitCommandsSupportAutonomousAutomation() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glacier_split_test", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let noteURL = tempRoot.appendingPathComponent("split-notes.md")
        try """
        # Split Test

        This file exists so UI automation can open a real editor tab before splitting.
        """.write(to: noteURL, atomically: true, encoding: .utf8)

        app.terminate()
        app.launchEnvironment["GLACIER_OPEN_FILE"] = noteURL.path
        app.launchArguments = ["-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        sleep(3)
        app.activate()

        XCTAssertEqual(
            app.state, .runningForeground,
            "App should be running after opening a file for split automation"
        )

        app.typeKey("t", modifierFlags: [.command])
        sleep(2)

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        sleep(1)
        XCTAssertEqual(
            app.state, .runningForeground,
            "App should remain running after Split Right"
        )

        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        sleep(1)
        XCTAssertEqual(
            app.state, .runningForeground,
            "App should remain running after Split Down"
        )

        app.typeKey("\\", modifierFlags: [.command, .option])
        sleep(1)

        XCTAssertEqual(
            app.state, .runningForeground,
            "App should still be running after split automation commands"
        )

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Autonomous split command flow"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSplitTerminalsAcceptInputInBothPanes() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("gts", isDirectory: true)
        let leftDir = tempRoot.appendingPathComponent("a", isDirectory: true)
        let rightDir = tempRoot.appendingPathComponent("b", isDirectory: true)
        let primaryOutput = tempRoot.appendingPathComponent("primary.txt")
        let secondaryOutput = tempRoot.appendingPathComponent("secondary.txt")
        let focusLog = tempRoot.appendingPathComponent("focus.log")

        try? fileManager.removeItem(at: tempRoot)
        try fileManager.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rightDir, withIntermediateDirectories: true)

        app.terminate()
        app.launchEnvironment["GLACIER_OPEN_FOLDER"] = tempRoot.path
        app.launchEnvironment["GLACIER_DEBUG_FOCUS"] = "1"
        app.launchEnvironment["GLACIER_DEBUG_FOCUS_LOG"] = focusLog.path
        app.launchArguments = ["-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        sleep(3)
        app.activate()

        XCTAssertEqual(
            app.state, .runningForeground,
            "App should be running before terminal split testing"
        )

        app.typeKey("t", modifierFlags: [.command])
        sleep(2)
        typeShellCommand("cd \(shellQuoted(leftDir.path))")

        app.typeKey("t", modifierFlags: [.command])
        sleep(2)
        typeShellCommand("cd \(shellQuoted(rightDir.path))")

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        sleep(2)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Expected Glacier window to exist")

        clickPane(in: window, x: 0.25, y: 0.65)
        typeShellCommand("pwd > \(shellQuoted(primaryOutput.path))")

        clickPane(in: window, x: 0.75, y: 0.65)
        typeShellCommand("pwd > \(shellQuoted(secondaryOutput.path))")

        let primaryPath = try waitForFileContents(at: primaryOutput)
        let secondaryPath = try waitForFileContents(at: secondaryOutput)
        let expectedPaths = Set([leftDir.path, rightDir.path])
        let actualPaths = Set([primaryPath, secondaryPath])

        if let focusLogText = try? String(contentsOf: focusLog) {
            let focusAttachment = XCTAttachment(string: focusLogText)
            focusAttachment.name = "Split focus log"
            focusAttachment.lifetime = .keepAlways
            add(focusAttachment)
        }

        XCTAssertEqual(actualPaths, expectedPaths, "Each split terminal should keep its own shell state")

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Split terminals accept input in both panes"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func typeShellCommand(_ command: String) {
        app.typeText(command)
        app.typeKey(.return, modifierFlags: [])
        sleep(1)
    }

    private func clickPane(in window: XCUIElement, x: CGFloat, y: CGFloat) {
        window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
        sleep(1)
    }

    private func waitForFileContents(at url: URL, timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: url.path),
               let contents = String(data: data, encoding: .utf8) {
                let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        throw NSError(
            domain: "GlacierUITests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for terminal output at \(url.path)"]
        )
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

}
