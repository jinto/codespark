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

    private var branchRows: XCUIElementQuery {
        app.staticTexts.matching(identifier: "worktreeBranch")
    }

    /// Selecting a project with no live tabs raises the "Choose session" dialog,
    /// which blocks the window until it is answered. The disclosure triangle
    /// never selected anything, so the old tests never met it — opening a tree
    /// by clicking its row does, on every project that has tabs to recover.
    private func dismissSessionChooserIfPresent() {
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 1) { cancel.click() }
    }

    /// Returns a project row that actually has a tree, left open.
    ///
    /// The disclosure triangle is gone, so the row itself folds and unfolds —
    /// and every row now takes the click, whether or not it has anything to
    /// show. That removes the free filter the triangle used to give us, so the
    /// only way to find a multi-worktree project is to click and watch: a row
    /// with a tree changes the branch-row count, a row without one does not.
    ///
    /// Expansion is remembered across launches, so a click can just as easily
    /// fold a tree an earlier test left open. That still identifies the row —
    /// we just click again to hand it back open.
    private func projectRowWithATree() throws -> XCUIElement {
        // Generous: the tests that run before this one leave tabs behind, and a
        // launch that restores several replays their screens before the sidebar
        // settles. Ten seconds was enough until it wasn't.
        XCTAssertTrue(
            wait(upTo: 25, until: { self.projectRows.count > 0 }),
            "no projects in this store"
        )
        // Last first, so callers that press Cmd+1 land on a different project.
        for row in projectRows.allElementsBoundByIndex.reversed() {
            let before = branchRows.count
            row.click()
            dismissSessionChooserIfPresent()
            guard wait(until: { self.branchRows.count != before }) else {
                // No tree here — but the click stored an expansion flag all the
                // same (it toggles before knowing whether there is a tree, see
                // `selectProjectAndToggleWorktrees`). Flip it straight back, or
                // the probe leaves droppings for every test that follows.
                row.click()
                dismissSessionChooserIfPresent()
                continue
            }
            if branchRows.count < before {
                // This row has a tree, and the click just folded one an earlier
                // test left open. Reopening puts the count back at `before` —
                // never above it — so wait against the folded count, not `before`.
                let folded = branchRows.count
                row.click()
                dismissSessionChooserIfPresent()
                XCTAssertTrue(
                    wait(until: { self.branchRows.count > folded }),
                    "the tree would not reopen"
                )
            }
            return row
        }
        throw XCTSkip("no multi-worktree project in this store")
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

    // The three sidebar tests need a project with more than one worktree, and a
    // checkout usually has exactly one — so they skip, and a skip reads as a
    // pass. They cannot make the worktree themselves: the runner is sandboxed
    // and `/usr/bin/git` is a shim over `xcrun`, which refuses there outright
    // ("cannot be used within an App Sandbox"). The pre-push hook lends the
    // repository one before it runs this suite, and takes it back after.

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
        _ = try projectRowWithATree()
        XCTAssertTrue(wait { self.branchRows.count > 0 }, "the tree did not open")
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
        let infoLines = app.staticTexts.matching(identifier: "projectInfoLine")
        let worktreePaths = app.staticTexts.matching(identifier: "worktreePath")
        let row = try projectRowWithATree()
        let pathsOpen = worktreePaths.count
        let infoLinesOpen = infoLines.count

        // Fold it back up: the path has to travel the other way too.
        row.click()
        dismissSessionChooserIfPresent()

        XCTAssertTrue(
            wait { worktreePaths.count < pathsOpen },
            "folding the tree left the path on a worktree row that is gone"
        )
        XCTAssertTrue(
            wait { infoLines.count == infoLinesOpen + 1 },
            "the collapsed project row never took its path back"
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
        _ = try projectRowWithATree()
        XCTAssertTrue(wait { self.branchRows.count >= 2 }, "the tree did not open")

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

        // Hand the sidebar back with a non-empty worktree selected. Tests after
        // this one open a terminal into whatever is selected, and parking on the
        // empty worktree would hand them the very state this test needs to find.
        // The tree itself can stay open — `projectRowWithATree` opens whatever
        // it is given, either way round.
        rows[0].click()
    }

    // MARK: - Two gestures on one row

    /// The row carries a single click (select, and fold or unfold) and a double
    /// click (select, and open the session chooser). While the single click only
    /// selected, both firing was harmless. Now that it flips state, a double
    /// click moves the sidebar on the way to a sheet nobody asked it to move
    /// for.
    func test_double_clicking_a_project_row_leaves_its_tree_alone() throws {
        let row = try projectRowWithATree()
        let opened = branchRows.count
        // Without rows on screen the assertion below would hold for the wrong
        // reason: nothing can fold when nothing is showing.
        XCTAssertGreaterThan(opened, 0, "the tree never opened, so this proves nothing")

        row.doubleClick()
        dismissSessionChooserIfPresent()

        XCTAssertEqual(branchRows.count, opened,
                       "the double click folded or unfolded the tree on its way to the chooser")
    }
}
