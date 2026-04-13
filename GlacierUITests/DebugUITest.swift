import XCTest
final class DebugUITest: XCTestCase {
    func testCheckEnvAndButtons() {
        let app = XCUIApplication()
        app.launchEnvironment = [:]
        app.launchArguments = ["-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        sleep(3)
        app.activate()

        // Count windows before
        let windowsBefore = app.windows.count
        XCTContext.runActivity(named: "Windows BEFORE Cmd+Shift+O: \(windowsBefore)") { _ in }

        // Trigger Open Folder via keyboard shortcut
        app.typeKey("o", modifierFlags: [.command, .shift])
        sleep(2)

        // Count windows after
        let windowsAfter = app.windows.count
        XCTContext.runActivity(named: "Windows AFTER Cmd+Shift+O: \(windowsAfter)") { _ in }

        // Does panel window exist?
        let panelWindow = app.windows.firstMatch
        if panelWindow.exists {
            XCTContext.runActivity(named: "Panel frame: \(panelWindow.frame)") { _ in }
            // Try to find Cancel button in panel
            let cancelBtn = panelWindow.buttons["Cancel"].firstMatch
            let openBtn = panelWindow.buttons["Open"].firstMatch
            XCTContext.runActivity(named: "Panel Cancel=\(cancelBtn.exists) Open=\(openBtn.exists)") { _ in }
        }

        app.typeKey(.escape, modifierFlags: [])
        XCTAssert(true)
        app.terminate()
    }
}
