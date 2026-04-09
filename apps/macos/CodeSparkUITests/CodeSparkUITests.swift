import XCTest

final class CodeSparkUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(
            app.staticTexts["CodeSpark"].waitForExistence(timeout: 10),
            "App should launch with sidebar title"
        )
    }

    // MARK: - Sidebar

    func test_sidebar_shows_app_title() {
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists)
    }

    func test_sidebar_shows_project_names() {
        // Projects should be visible as static text with accessibilityIdentifier "projectName"
        let projectNames = app.staticTexts.matching(identifier: "projectName")
        // At least one project should exist (app creates one on first launch or has saved projects)
        XCTAssertGreaterThan(projectNames.count, 0,
                              "Sidebar should display at least one project name")
    }

    func test_sidebar_has_no_workspace_rows() {
        // After sidebar flatten, no workspace/branch rows should exist
        // WorkspaceSidebarRow was deleted — verify no branch icons remain
        let branchIcons = app.images.matching(identifier: "arrow.triangle.branch")
        XCTAssertEqual(branchIcons.count, 0,
                        "Sidebar should not show workspace branch rows after flatten")
    }

    func test_sidebar_project_click_selects() {
        let projectNames = app.staticTexts.matching(identifier: "projectName")
        guard projectNames.count > 0 else { return }
        let first = projectNames.element(boundBy: 0)
        first.click()
        sleep(1)
        // App should still be running after click
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists)
    }

    // MARK: - Keyboard Shortcuts (stability — no crash)

    func test_cmd_1_does_not_crash() {
        app.typeKey("1", modifierFlags: .command)
        sleep(1)
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists)
    }

    func test_cmd_shift_t_does_not_crash() {
        app.typeKey("t", modifierFlags: [.command, .shift])
        sleep(1)
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists)
    }

    func test_cmd_n_does_not_crash() {
        app.typeKey("n", modifierFlags: .command)
        sleep(1)
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists)
    }

    func test_cmd_w_does_not_crash() {
        app.typeKey("w", modifierFlags: .command)
        sleep(1)
        XCTAssertTrue(app.staticTexts["CodeSpark"].exists)
    }
}
