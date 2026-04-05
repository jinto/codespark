import XCTest

final class CodeSparkUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        // Wait for initial load — sidebar title should appear
        XCTAssertTrue(
            app.staticTexts["CodeSpark"].waitForExistence(timeout: 10),
            "App should launch and show sidebar title"
        )
    }

    // MARK: - Sidebar

    func test_sidebar_shows_app_title() {
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists)
    }

    // MARK: - Cmd+N: New Workspace

    func test_cmd_n_creates_new_workspace() {
        let workspaceNames = app.staticTexts.matching(identifier: "workspaceName")
        let before = workspaceNames.count
        app.typeKey("n", modifierFlags: .command)
        // Wait for the new workspace text to appear
        let newWorkspace = workspaceNames.element(boundBy: before)
        XCTAssertTrue(
            newWorkspace.waitForExistence(timeout: 5),
            "Cmd+N should add a workspace to sidebar (before: \(before))"
        )
    }

    // MARK: - Cmd+W: Close Session

    func test_cmd_w_shows_alert() {
        // Cmd+W should show some kind of close alert (session or workspace)
        app.typeKey("w", modifierFlags: .command)

        // macOS SwiftUI .alert can appear as alerts or sheets
        let alertExists = app.alerts.firstMatch.waitForExistence(timeout: 3)
        let sheetExists = app.sheets.firstMatch.waitForExistence(timeout: 1)
        let dialogExists = app.dialogs.firstMatch.waitForExistence(timeout: 1)

        XCTAssertTrue(
            alertExists || sheetExists || dialogExists,
            "Cmd+W should show a close confirmation (alert, sheet, or dialog)"
        )
    }

    func test_cmd_w_cancel_keeps_state() {
        app.typeKey("w", modifierFlags: .command)

        // Find whichever dialog type appeared
        let alert = app.alerts.firstMatch
        let sheet = app.sheets.firstMatch
        let dialog = app.dialogs.firstMatch

        var cancelTapped = false
        for container in [alert, sheet, dialog] {
            if container.waitForExistence(timeout: 2) {
                let cancelButton = container.buttons["Cancel"]
                if cancelButton.exists {
                    cancelButton.tap()
                    cancelTapped = true
                    break
                }
            }
        }

        XCTAssertTrue(cancelTapped, "Should find and tap Cancel button in close dialog")
    }

    // MARK: - Cmd+1: Workspace Switching

    func test_cmd_1_does_not_crash() {
        app.typeKey("1", modifierFlags: .command)
        sleep(1)
        // App should still be running
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists, "App should not crash on Cmd+1")
    }

    // MARK: - Cmd+Shift+T: Reopen Closed Session

    func test_cmd_shift_t_does_not_crash() {
        app.typeKey("t", modifierFlags: [.command, .shift])
        sleep(1)
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists, "App should not crash on Cmd+Shift+T")
    }
}
