// GitGraphScreenshotTests.swift
// Takes a screenshot of the Git Graph view to support iterative visual design work.

import XCTest

@MainActor
final class GitGraphScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-NSQuitAlwaysKeepsWindows", "NO"]
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    /// Opens a real git repo and auto-switches to the Git Graph tab,
    /// then captures a full-app screenshot for visual review.
    /// Uses GLACIER_OPEN_GIT_GRAPH=1 so no UI clicks are required — this
    /// lets the test run on a headless Mac mini session where app
    /// activation may fail.
    func testCaptureGitGraphScreenshot() throws {
        // Use a synthetic fixture repo whose refs/commits mirror the target Cursor
        // design — stable between runs and free of noisy untracked files.
        let repoPath = ProcessInfo.processInfo.environment["GLACIER_GIT_GRAPH_REPO"]
            ?? "/tmp/git-graph-fixture"
        app.launchEnvironment["GLACIER_OPEN_FOLDER"] = repoPath
        app.launchEnvironment["GLACIER_OPEN_GIT_GRAPH"] = "1"
        app.launchEnvironment["GLACIER_ENABLE_TEST_HOOKS"] = "1"
        app.launch()
        // Poll for the graph content by looking for the "Loading Git History…"
        // label disappearing — if the commits rendered, the loader is done.
        let loading = app.staticTexts["Loading Git History…"]
        // Allow up to 45s for git log to finish on a cold SwiftUI launch.
        let started = Date()
        while loading.exists && Date().timeIntervalSince(started) < 45 {
            usleep(500_000)
        }
        // Let the graph finish painting + references render.
        sleep(1)

        // Always dump AX tree so we can see what actually rendered.
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = "AX-hierarchy"
        dump.lifetime = .keepAlways
        add(dump)

        let screenshot = app.windows.firstMatch.exists
            ? app.windows.firstMatch.screenshot()
            : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Git Graph View"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
