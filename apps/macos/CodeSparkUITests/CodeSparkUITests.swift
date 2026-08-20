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

    // MARK: - Remote folder picker

    /// The unit suite can prove the picker *works*; only a running app can prove
    /// the New SSH Project sheet ever offers it.
    func test_the_new_ssh_sheet_offers_to_browse_the_host() {
        openNewSSHSheet()

        let browse = app.buttons["newSSHProjectBrowse"]
        XCTAssertTrue(wait { browse.exists }, "the sheet has no Browse button")
        XCTAssertFalse(browse.isEnabled, "there is no host to browse yet")

        typeHost("localhost")

        XCTAssertTrue(wait { browse.isEnabled }, "Browse stayed disabled after a host was named")
    }

    /// End to end: browse a real host, choose a folder, and watch it land in the
    /// field that becomes the project's remote path.
    func test_choosing_a_folder_fills_in_the_remote_path() throws {
        try XCTSkipUnless(canSSHToLocalhost(), "sshd not running on localhost")
        openNewSSHSheet()
        typeHost("localhost")

        app.buttons["newSSHProjectBrowse"].click()
        XCTAssertTrue(
            wait(upTo: 20) { self.app.buttons["remoteFolderPickerChoose"].isEnabled },
            "the picker never finished listing the home directory"
        )
        app.buttons["remoteFolderPickerChoose"].click()

        let remotePath = app.textFields["newSSHProjectRemotePath"]
        XCTAssertTrue(
            wait { (remotePath.value as? String)?.isEmpty == false },
            "the chosen folder never reached the remote path field"
        )
        XCTAssertTrue(
            ((remotePath.value as? String) ?? "").hasPrefix("/"),
            "expected an absolute remote path, got \(String(describing: remotePath.value))"
        )
    }

    /// Selecting a row is what saves the user a trip into the folder. The model
    /// knows what a selection means; only the running app can say whether a
    /// click ever produces one.
    func test_clicking_a_folder_picks_it_without_walking_into_it() throws {
        try XCTSkipUnless(canSSHToLocalhost(), "sshd not running on localhost")
        openNewSSHSheet()
        typeHost("localhost")

        app.buttons["newSSHProjectBrowse"].click()
        XCTAssertTrue(
            wait(upTo: 20) { self.app.buttons["remoteFolderPickerChoose"].isEnabled },
            "the picker never finished listing the home directory"
        )
        // The runner has its own sandboxed home, so the remote home is whatever
        // the picker itself is showing.
        let remoteHome = (app.textFields["remoteFolderPickerPath"].value as? String) ?? ""
        XCTAssertTrue(remoteHome.hasPrefix("/"), "the picker never showed a path")

        let row = firstFolderRow()
        try XCTSkipIf(row == nil, "the home directory has no visible folders to click")
        row?.click()
        app.buttons["remoteFolderPickerChoose"].click()

        let chosen = (app.textFields["newSSHProjectRemotePath"].value as? String) ?? ""
        XCTAssertTrue(
            chosen.hasPrefix(remoteHome + "/"),
            "expected a folder inside \(remoteHome), got \(chosen)"
        )
    }

    /// SwiftUI's List lands as a table or an outline depending on the platform's
    /// mood; ask for both rather than pin the test to one.
    private func firstFolderRow() -> XCUIElement? {
        for container in [app.tables, app.outlines] {
            let cell = container.firstMatch.cells.firstMatch
            if cell.exists { return cell }
        }
        return nil
    }

    private func openNewSSHSheet() {
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            wait { self.app.textFields["newSSHProjectHost"].exists },
            "the New SSH Project sheet never appeared"
        )
    }

    private func typeHost(_ host: String) {
        let field = app.textFields["newSSHProjectHost"]
        field.click()
        field.typeText(host)
    }

    private func canSSHToLocalhost() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2",
                             "-o", "StrictHostKeyChecking=no", "localhost", "echo", "ok"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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

        // Expansion is remembered across launches, so the tree may already be
        // open — from a neighbouring test, or from the last time this one ran.
        // Clicking blind would close it and test the opposite of the point.
        if branchRows.count == 0 { disclosure.click() }
        XCTAssertTrue(wait { branchRows.count > 0 }, "the tree did not open")
        let opened = branchRows.count

        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(
            wait { branchRows.count >= opened },
            "selecting another project folded a tree the user had opened"
        )
    }

    // MARK: - The path belongs to the row that is that worktree

    /// A collapsed project row shows its path; opening the tree puts a "main"
    /// row right under it, and the two would then name the same directory one
    /// line apart. The handoff is decided in the sidebar's view body, so only a
    /// running app can prove the path actually moved.
    func test_opening_a_tree_moves_the_path_onto_the_main_worktree_row() throws {
        let disclosures = app.buttons.matching(identifier: "worktreeDisclosure")
        try XCTSkipUnless(
            disclosures.firstMatch.waitForExistence(timeout: 10),
            "no multi-worktree project in this store"
        )
        let disclosure = disclosures.allElementsBoundByIndex.last!
        let infoLines = app.staticTexts.matching(identifier: "projectInfoLine")
        let worktreePaths = app.staticTexts.matching(identifier: "worktreePath")

        // The tree may already be open from a previous run — this asserts the
        // handoff in whichever direction the click takes it.
        let infoLinesBefore = infoLines.count
        let pathsBefore = worktreePaths.count

        disclosure.click()

        XCTAssertTrue(wait { worktreePaths.count != pathsBefore },
                      "clicking the disclosure moved no path at all")
        let opened = worktreePaths.count > pathsBefore
        XCTAssertTrue(
            wait { infoLines.count == infoLinesBefore + (opened ? -1 : 1) },
            opened
                ? "the expanded project row kept a path its main worktree row now shows"
                : "the collapsed project row never took its path back"
        )
    }

    // MARK: - The main area follows the tab bar, not the project

    /// A worktree with no tabs of its own left the pane blank whenever a sibling
    /// worktree still had one: the empty state keyed off the project's tabs, so
    /// the button that would have made a tab here vanished exactly when it was
    /// needed. The unit suite proves the model empties `visibleSessions`
    /// (`test_switching_to_an_empty_worktree_clears_the_active_tab`); which view
    /// that picks needs the running app.
    func test_a_worktree_with_no_tabs_offers_to_make_one() throws {
        let disclosures = app.buttons.matching(identifier: "worktreeDisclosure")
        try XCTSkipUnless(
            disclosures.firstMatch.waitForExistence(timeout: 10),
            "no multi-worktree project in this store"
        )
        let disclosure = disclosures.allElementsBoundByIndex.last!
        let branchRows = app.staticTexts.matching(identifier: "worktreeBranch")
        let treeWasOpen = branchRows.count > 0
        if !treeWasOpen { disclosure.click() }
        XCTAssertTrue(wait { branchRows.count >= 2 }, "the tree did not open")

        let newTerminal = app.buttons["New Terminal"]
        let rows = branchRows.allElementsBoundByIndex
        rows[0].click()
        if newTerminal.waitForExistence(timeout: 3) {
            newTerminal.click()
            XCTAssertTrue(wait { !newTerminal.exists }, "the first worktree never got a tab")
        }

        // The badge counts a worktree's tabs, and it is the only signal here that
        // does not come from the empty state itself — asking the empty state
        // whether the worktree is empty would answer "no" from the very bug this
        // is trying to catch. One badge means the tab just made is the only one,
        // so the row about to be clicked is genuinely standing empty.
        let badges = app.staticTexts.matching(identifier: "worktreeSessionCount")
        try XCTSkipUnless(wait { badges.count == 1 },
                          "every worktree here already has tabs — nothing empty to select")

        rows[1].click()

        XCTAssertTrue(
            newTerminal.waitForExistence(timeout: 5),
            "a worktree with no tabs showed a blank pane instead of offering one"
        )

        // Hand the sidebar back exactly as it was found. Tests after this one
        // open a terminal into whatever is selected — parking on the empty
        // worktree would hand them the very state this test needs to find — and
        // one of them toggles this same disclosure, which a tree left open turns
        // into a collapse.
        rows[0].click()
        if !treeWasOpen { disclosure.click() }
    }
}
