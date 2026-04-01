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
