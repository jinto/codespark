import XCTest

/// What the unit suite structurally cannot see.
///
/// `AppShortcut` tests prove a chord *should* survive `KeyEventRouter`, but not
/// that it was ever wired to a menu item, nor that pressing it does anything.
/// Those need a running app, which is what these cover.
///
/// Deliberately absent: Cmd+N (opens an NSOpenPanel and blocks the runner) and
/// Cmd+W (closes a session or project in the dev store).
final class CodeSparkUITests: XCTestCase {
    let app = XCUIApplication()

    private var projectRows: XCUIElementQuery {
        app.staticTexts.matching(identifier: "projectName")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 20),
            "app window never appeared"
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func wait(
        upTo timeout: TimeInterval = 5,
        until condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    // MARK: - Sidebar

    func test_sidebar_lists_projects() {
        XCTAssertTrue(
            wait { self.projectRows.count > 0 },
            "sidebar showed no project rows"
        )
    }

    // MARK: - Shortcuts reach the menu and fire

    /// The regression this whole layer exists for: `Cmd+Ctrl+S` had a working
    /// action and a menu item, and every unit test passed, but the router handed
    /// the chord to the terminal so the sidebar never toggled — the shell just
    /// printed `15;5u`.
    ///
    /// A terminal has to exist for this to reproduce at all. `performKeyEquivalent`
    /// walks the window's view tree, so with no session there is no Ghostty
    /// surface to intercept the chord and the bug hides.
    func test_cmd_ctrl_s_toggles_the_sidebar_with_a_terminal_open() {
        ensureTerminalOpen()

        XCTAssertTrue(wait { self.projectRows.count > 0 }, "sidebar should start visible")

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(
            wait { self.projectRows.count == 0 },
            "Cmd+Ctrl+S did not hide the sidebar — the terminal swallowed the chord"
        )

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(
            wait { self.projectRows.count > 0 },
            "Cmd+Ctrl+S did not bring the sidebar back"
        )
    }

    /// Works from either starting state: the empty-state button is present only
    /// when no session is open, so its absence already means a terminal is up.
    ///
    /// The session this may create is deliberately left running. Restore replaces
    /// an interrupted tab one-for-one, so the dev store settles at one session
    /// instead of stacking a new one every run.
    private func ensureTerminalOpen() {
        let newTerminal = app.buttons["New Terminal"]
        if newTerminal.waitForExistence(timeout: 5) {
            newTerminal.click()
        }
        XCTAssertTrue(
            wait(upTo: 20) { !self.app.buttons["New Terminal"].exists },
            "no terminal surface in the window — the chord cannot be intercepted"
        )
    }

    /// A chord can be declared in `AppShortcut` and still be attached to no
    /// Button at all, which the unit suite cannot detect.
    func test_declared_commands_are_wired_to_menu_items() {
        for title in [
            "Toggle Sidebar",
            "Select Next Tab",
            "Select Previous Tab",
            "Select Next Worktree",
            "Select Previous Worktree",
        ] {
            XCTAssertTrue(
                app.menuBars.menuItems[title].exists,
                "\(title) is declared but missing from the menu"
            )
        }
    }

    func test_cmd_1_selects_a_project_without_crashing() {
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(
            wait { self.projectRows.count > 0 },
            "app stopped responding after Cmd+1"
        )
    }

    // MARK: - The worktree tree belongs to the user, not to the selection

    /// Worktree rows used to be drawn only under the selected project, so Cmd+1
    /// folded away the tree you had open. The unit suite cannot see it — the
    /// condition lives in the sidebar's view body.
    func test_an_open_worktree_tree_survives_selecting_another_project() throws {
        let disclosures = app.buttons.matching(identifier: "worktreeDisclosure")
        try XCTSkipUnless(
            disclosures.firstMatch.waitForExistence(timeout: 10),
            "no multi-worktree project in this store"
        )
        // The last one, so Cmd+1 lands on a different project than the tree.
        let disclosure = disclosures.allElementsBoundByIndex.last!
        let branchRows = app.staticTexts.matching(identifier: "worktreeBranch")

        disclosure.click()
        XCTAssertTrue(wait { branchRows.count > 0 }, "the tree did not open")
        let opened = branchRows.count

        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(
            wait { branchRows.count >= opened },
            "selecting another project folded a tree the user had opened"
        )
    }
}
