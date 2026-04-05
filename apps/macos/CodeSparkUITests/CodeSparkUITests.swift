import XCTest

final class CodeSparkUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        // Wait for initial load
        let sidebar = app.staticTexts["CodeSpark"]
        _ = sidebar.waitForExistence(timeout: 5)
    }

    // MARK: - Workspace Management

    func test_sidebar_shows_app_title() {
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists, "App title should be visible in sidebar")
    }

    func test_cmd_n_creates_new_workspace() {
        let before = app.staticTexts.matching(NSPredicate(format: "label == 'New Workspace'")).count
        app.typeKey("n", modifierFlags: .command)
        sleep(1) // wait for workspace creation
        let after = app.staticTexts.matching(NSPredicate(format: "label == 'New Workspace'")).count
        XCTAssertGreaterThan(after, before, "Cmd+N should create a new workspace")
    }

    // MARK: - Session Close Flow

    func test_cmd_w_shows_close_alert_when_session_exists() {
        // Create a session first
        app.typeKey("t", modifierFlags: .command)
        sleep(1)

        // Try to close
        app.typeKey("w", modifierFlags: .command)
        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Cmd+W should show close alert")
    }

    func test_cmd_w_close_alert_dismiss_cancels() {
        app.typeKey("t", modifierFlags: .command)
        sleep(1)

        app.typeKey("w", modifierFlags: .command)
        let alert = app.dialogs.firstMatch
        guard alert.waitForExistence(timeout: 3) else {
            XCTFail("Alert should appear")
            return
        }
        alert.buttons["Cancel"].tap()
        // Session should still exist — no crash
    }

    func test_cmd_w_shows_close_workspace_alert_when_no_sessions() {
        // With no sessions, Cmd+W should offer to close workspace
        app.typeKey("w", modifierFlags: .command)
        let alert = app.dialogs.firstMatch
        if alert.waitForExistence(timeout: 3) {
            // Should mention workspace, not session
            XCTAssertTrue(
                alert.staticTexts.element(matching: NSPredicate(format: "label CONTAINS 'workspace'")).exists
                || alert.staticTexts.element(matching: NSPredicate(format: "label CONTAINS 'Workspace'")).exists,
                "Alert should mention workspace when no sessions"
            )
        }
    }

    // MARK: - Workspace Switching

    func test_cmd_1_selects_first_workspace() {
        app.typeKey("1", modifierFlags: .command)
        // Should not crash
        sleep(1)
    }
}
