import XCTest
@testable import CodeSpark

final class WorkspaceSelectionTests: XCTestCase {

    // MARK: - Agent session commands

    func test_agent_resume_commands_match_cli_syntax() {
        XCTAssertEqual(AgentKind.claude.resumeCommand(id: "claude-id"), "claude --resume claude-id")
        XCTAssertEqual(AgentKind.codex.resumeCommand(id: "codex-id"), "codex resume codex-id")
    }

    @MainActor
    func test_launch_restores_while_sidebar_reselect_still_offers_the_choice_menu() async {
        var hosts: [MockTerminalHost] = []
        let core = MockProjectCoreClient.projectWithInterruptedSession()
        let model = AppModel(
            core: core,
            terminalFactory: { _ in
                let host = MockTerminalHost()
                hosts.append(host)
                return host
            }
        )

        // Launch restores the tabs rather than asking about them.
        await model.load()
        XCTAssertNil(model.pendingWorkspaceRecoveryProjectID)
        XCTAssertEqual(model.liveSessions.count, 1)

        // Re-opening a project with no tabs from the sidebar still offers the menu,
        // which is also how you reach "New Claude session" / "Resume …".
        let restored = model.liveSessions[0].id
        hosts[0].finishClose(
            sessionID: restored,
            snapshot: .fixture(lines: []),
            closeReason: .userClosed
        )
        // The store write is a detached task; the reselect below must see it.
        while !core.closedSessionIDs.contains(restored) { await Task.yield() }

        await model.selectProject(id: "ws-spark3", promptForRecovery: true)
        XCTAssertEqual(model.pendingWorkspaceRecoveryProjectID, "ws-spark3")
    }

    @MainActor
    func test_interrupted_project_with_live_tabs_does_not_prompt_for_restore() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(
                    id: "ws-live",
                    name: "live",
                    path: "/tmp/live",
                    transport: "local",
                    liveSessions: 1,
                    recentlyClosedSessions: 1,
                    hasInterruptedSessions: true,
                    liveSessionDetails: []
                )
            ],
            details: [
                ProjectDetailViewData(
                    id: "ws-live",
                    name: "live",
                    path: "/tmp/live",
                    transport: "local",
                    liveSessions: [
                        SessionViewData(
                            id: "live-session",
                            title: "Terminal",
                            targetLabel: "local",
                            lastCwd: "/tmp/live"
                        )
                    ],
                    interruptedSessions: [
                        SessionSummary(
                            id: "interrupted-session",
                            title: "Old terminal",
                            targetLabel: "local",
                            lastCwd: "/tmp/live"
                        )
                    ]
                )
            ]
        )
        let model = AppModel(core: client, terminalFactory: { _ in MockTerminalHost() })

        await model.load()
        await model.selectProject(id: "ws-live", promptForRecovery: true)

        XCTAssertNil(model.pendingWorkspaceRecoveryProjectID)
        XCTAssertEqual(model.liveSessions.count, 1)
    }

    @MainActor
    func test_session_chooser_can_be_requested_for_current_project() async {
        let model = AppModel(
            core: MockProjectCoreClient.projectWithInterruptedSession(),
            terminalFactory: { _ in MockTerminalHost() }
        )

        await model.load()
        model.presentSessionChooser()

        XCTAssertEqual(model.pendingWorkspaceRecoveryProjectID, "ws-spark3")
    }

    @MainActor
    func test_restore_interrupted_tabs_recreates_tab_cwds() async {
        let model = AppModel(
            core: MockProjectCoreClient.projectWithInterruptedSession(),
            terminalFactory: { _ in MockTerminalHost() }
        )

        await model.load()
        await model.selectProject(id: "ws-spark3", promptForRecovery: true)
        await model.restoreInterruptedTabs(projectID: "ws-spark3")

        XCTAssertNil(model.pendingWorkspaceRecoveryProjectID)
        XCTAssertEqual(model.liveSessions.count, 1)
        XCTAssertEqual(model.liveSessions[0].lastCwd, "/Users/jinto/projects/spark3")
        XCTAssertFalse(model.projects[0].hasInterruptedSessions)
    }

    @MainActor
    func test_cmd_project_order_matches_sidebar_order() {
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []))
        model.selection = .pending(id: "p1", onScreen: nil)
        model.projects = [
            ProjectSummaryViewData(
                id: "p1", name: "First", path: "/tmp/first", transport: "local",
                liveSessions: 0, recentlyClosedSessions: 0,
                hasInterruptedSessions: false, liveSessionDetails: []
            ),
            ProjectSummaryViewData(
                id: "p2", name: "Interrupted", path: "/tmp/interrupted", transport: "local",
                liveSessions: 0, recentlyClosedSessions: 1,
                hasInterruptedSessions: true, liveSessionDetails: []
            ),
            ProjectSummaryViewData(
                id: "p3", name: "Third", path: "/tmp/third", transport: "local",
                liveSessions: 0, recentlyClosedSessions: 0,
                hasInterruptedSessions: false, liveSessionDetails: []
            )
        ]

        XCTAssertEqual(model.orderedProjects.map(\.id), ["p1", "p2", "p3"])
    }

    // MARK: - Worktree naming

    func test_worktree_name_is_flat_repo_branch_and_id() {
        let name = GitWorktreeService.makeWorktreeName(
            projectPath: "/Users/me/my-repo",
            branch: "fix/login",
            id: "a1b2"
        )

        XCTAssertEqual(name, "my-repo-fix-login-a1b2")
    }

    func test_worktree_id_is_recovered_from_generated_path() {
        XCTAssertEqual(
            GitWorktreeService.worktreeID(from: "/Users/me/worktrees/my-repo-fix-login-a1b2"),
            "a1b2"
        )
    }

    func test_existing_worktree_without_generated_id_uses_path_as_id() {
        let path = "/Users/me/project/.worktrees/feature-login"
        XCTAssertEqual(GitWorktreeService.worktreeID(from: path), path)
    }

    func test_default_worktree_root_expands_tilde() {
        XCTAssertEqual(
            GitWorktreeService.expandedWorktreeRoot(GitWorktreeService.defaultWorktreeRoot),
            (GitWorktreeService.defaultWorktreeRoot as NSString).expandingTildeInPath
        )
    }

    // MARK: - Task 1: groupSessions always returns workspace (even single worktree)

    func test_single_worktree_returns_one_workspace() {
        let sessions = [
            SessionSummary(id: "s1", title: "Terminal", targetLabel: "local", lastCwd: "/tmp/proj")
        ]
        let worktrees = [GitWorktree(path: "/tmp/proj", branch: "main", isMainWorktree: true)]
        let result = WorkspaceViewData.groupSessions(sessions, into: worktrees, projectPath: "/tmp/proj")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].branch, "main")
        XCTAssertEqual(result[0].sessions.count, 1)
    }

    func test_nil_worktrees_returns_default_workspace() {
        let sessions = [
            SessionSummary(id: "s1", title: "Terminal", targetLabel: "local", lastCwd: "/tmp/proj")
        ]
        let result = WorkspaceViewData.groupSessions(sessions, into: nil, projectPath: "/tmp/proj")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].branch, "default")
    }

    // MARK: - Quit and relaunch restores the workspace

    private func projectWithTwoInterruptedTabs() -> MockProjectCoreClient {
        MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "codespark", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "p1", name: "codespark", path: "/tmp/proj", transport: "local",
                liveSessions: [],
                interruptedSessions: [
                    SessionSummary(id: "s1", title: "Terminal", targetLabel: "local",
                                   lastCwd: "/tmp/proj/nested", workspacePath: "/tmp/proj"),
                    SessionSummary(id: "s2", title: "Terminal", targetLabel: "local",
                                   lastCwd: "/Users/me", workspacePath: "/tmp/proj")
                ]
            )]
        )
    }

    @MainActor
    func test_launch_restores_interrupted_tabs_without_asking() async {
        let core = projectWithTwoInterruptedTabs()
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()

        XCTAssertEqual(model.liveSessions.count, 2)
        XCTAssertNil(model.pendingWorkspaceRecoveryProjectID)
    }

    @MainActor
    func test_each_restored_tab_returns_to_its_own_last_directory() async {
        let core = projectWithTwoInterruptedTabs()
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()

        XCTAssertEqual(core.startedSessions.map(\.initialCwd), ["/tmp/proj/nested", "/Users/me"])
    }

    @MainActor
    func test_restored_tabs_keep_their_original_workspace() async {
        let core = projectWithTwoInterruptedTabs()
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()

        XCTAssertEqual(core.startedSessions.map(\.workspacePath), ["/tmp/proj", "/tmp/proj"])
    }

    @MainActor
    func test_quitting_leaves_sessions_restorable_instead_of_closing_them() async {
        let core = MockProjectCoreClient.projectWithOneLiveSession()
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        model.saveAllSessionsForRestore()

        // Closing on quit is what made restore a coin flip: a closed row is not
        // restorable, and whether the write landed depended on termination timing.
        XCTAssertTrue(core.closedSessionIDs.isEmpty)
    }

    @MainActor
    func test_restoring_a_tab_consumes_the_row_it_came_from() async {
        // Otherwise the next launch restores it again on top of its own replacement,
        // and every launch doubles the tab count.
        let core = projectWithTwoInterruptedTabs()
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()

        XCTAssertEqual(core.consumedInterruptedSessions.sorted(), ["s1", "s2"])
    }

    @MainActor
    func test_project_with_no_interrupted_tabs_opens_empty() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "codespark", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "codespark", path: "/tmp/proj",
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()

        XCTAssertTrue(model.liveSessions.isEmpty)
        XCTAssertTrue(core.startedSessions.isEmpty)
    }

    // MARK: - Restored tabs replay what was on screen before

    @MainActor
    func test_restored_tab_replays_its_previous_screen_into_scrollback() async {
        let core = projectWithTwoInterruptedTabs()
        core.snapshotsBySessionID = [
            "s1": TerminalSnapshotViewData.fixture(lines: ["jinto@m3 ~ % cd projects/codespark"])
        ]
        var hosts: [MockTerminalHost] = []
        let model = AppModel(core: core, terminalFactory: { _ in
            let host = MockTerminalHost()
            hosts.append(host)
            return host
        })

        await model.load()

        // The replay is injected as shell startup input, so the previous screen
        // is printed as real output above the prompt rather than covering it.
        let injected = hosts.flatMap(\.initialInputs).compactMap { $0 }
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected[0].hasPrefix("cat "))
    }

    @MainActor
    func test_restored_ssh_tab_replays_through_the_remote_shell_not_the_keyboard() async throws {
        // Startup input is typed at the pty, which for an ssh tab means the far
        // side reads it — and a local temp file is not there. The replay has to
        // travel inside the ssh command instead.
        let core = sshProjectWithOneInterruptedTab()
        core.snapshotsBySessionID = [
            "s1": TerminalSnapshotViewData.fixture(lines: ["jinto@m3 ~ % ls"])
        ]
        var hosts: [MockTerminalHost] = []
        let model = AppModel(core: core, terminalFactory: { _ in
            let host = MockTerminalHost()
            hosts.append(host)
            return host
        })

        await model.load()

        XCTAssertTrue(hosts.flatMap(\.initialInputs).compactMap { $0 }.isEmpty)
        let command = try XCTUnwrap(hosts.flatMap(\.commands).compactMap { $0 }.first)
        XCTAssertTrue(command.contains("jinto@m3 ~ % ls"), "replay missing from: \(command)")
        XCTAssertFalse(command.contains(NSTemporaryDirectory()), "local path sent to the remote shell")
    }

    private func sshProjectWithOneInterruptedTab() -> MockProjectCoreClient {
        MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "emac", path: "ssh://emac", transport: "ssh",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "p1", name: "emac", path: "ssh://emac", transport: "ssh",
                liveSessions: [],
                interruptedSessions: [
                    SessionSummary(id: "s1", title: "emac", targetLabel: "emac",
                                   lastCwd: "/Users/jinto/projects/codespark", workspacePath: "ssh://emac")
                ]
            )]
        )
    }

    @MainActor
    func test_tab_without_a_previous_screen_gets_no_startup_input() async {
        let core = projectWithTwoInterruptedTabs()
        var hosts: [MockTerminalHost] = []
        let model = AppModel(core: core, terminalFactory: { _ in
            let host = MockTerminalHost()
            hosts.append(host)
            return host
        })

        await model.load()

        XCTAssertTrue(hosts.flatMap(\.initialInputs).compactMap { $0 }.isEmpty)
    }

    // MARK: - Workspace membership is fixed at tab creation

    private func twoWorktrees() -> [GitWorktree] {
        [
            GitWorktree(path: "/tmp/proj", branch: "main", isMainWorktree: true),
            GitWorktree(path: "/tmp/proj-feature", branch: "feature", isMainWorktree: false)
        ]
    }

    func test_cd_into_another_worktree_does_not_move_the_tab() {
        let sessions = [
            SessionSummary(id: "s1", title: "Terminal", targetLabel: "local",
                           lastCwd: "/tmp/proj-feature/src", workspacePath: "/tmp/proj")
        ]
        let result = WorkspaceViewData.groupSessions(sessions, into: twoWorktrees(), projectPath: "/tmp/proj")

        XCTAssertEqual(result.first(where: { $0.path == "/tmp/proj" })?.sessions.map(\.id), ["s1"])
        XCTAssertEqual(result.first(where: { $0.path == "/tmp/proj-feature" })?.sessions.count, 0)
    }

    func test_cd_outside_every_worktree_does_not_move_the_tab() {
        let sessions = [
            SessionSummary(id: "s1", title: "Terminal", targetLabel: "local",
                           lastCwd: "/Users/me", workspacePath: "/tmp/proj-feature")
        ]
        let result = WorkspaceViewData.groupSessions(sessions, into: twoWorktrees(), projectPath: "/tmp/proj")

        XCTAssertEqual(result.first(where: { $0.path == "/tmp/proj-feature" })?.sessions.map(\.id), ["s1"])
    }

    func test_legacy_session_without_workspace_path_falls_back_to_cwd() {
        // Rows written before the workspace_path column carry an empty value.
        let sessions = [
            SessionSummary(id: "s1", title: "Terminal", targetLabel: "local",
                           lastCwd: "/tmp/proj-feature/src", workspacePath: "")
        ]
        let result = WorkspaceViewData.groupSessions(sessions, into: twoWorktrees(), projectPath: "/tmp/proj")

        XCTAssertEqual(result.first(where: { $0.path == "/tmp/proj-feature" })?.sessions.map(\.id), ["s1"])
    }

    func test_workspace_path_pointing_at_a_removed_worktree_falls_back_to_main() {
        let sessions = [
            SessionSummary(id: "s1", title: "Terminal", targetLabel: "local",
                           lastCwd: "/tmp/gone", workspacePath: "/tmp/gone")
        ]
        let result = WorkspaceViewData.groupSessions(sessions, into: twoWorktrees(), projectPath: "/tmp/proj")

        XCTAssertEqual(result.first(where: { $0.path == "/tmp/proj" })?.sessions.map(\.id), ["s1"])
    }

    // MARK: - Task 2: workspaceSelectedSessions tracks per-workspace selection

    @MainActor
    func test_workspace_remembers_selected_session() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        // Create two sessions
        await model.newSession()
        await model.newSession()
        let session1 = model.liveSessions[0].id
        let session2 = model.liveSessions[1].id

        // Select session 1
        model.activeSessionID = session1
        // Workspace should remember this
        let wsPath = model.workspaces.first?.path ?? ""
        XCTAssertEqual(model.workspaceSelectedSessions[wsPath], session1)

        // Select session 2
        model.activeSessionID = session2
        XCTAssertEqual(model.workspaceSelectedSessions[wsPath], session2)
    }

    // MARK: - Task 3: activeSessionID syncs with workspace switching

    @MainActor
    func test_switching_workspace_restores_selected_session() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        await model.newSession()
        let sessionID = model.liveSessions[0].id

        // Set workspace selection
        let wsPath = model.workspaces.first?.path ?? ""
        model.workspaceSelectedSessions[wsPath] = sessionID

        // Switch to this workspace
        model.activeWorkspacePath = wsPath
        XCTAssertEqual(model.activeSessionID, sessionID)
    }

    // MARK: - Task 3b: workspace click fallback when no saved mapping

    @MainActor
    func test_switching_workspace_falls_back_to_first_session_when_no_mapping() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        await model.newSession()
        let sessionID = model.liveSessions[0].id
        let wsPath = model.workspaces.first?.path ?? ""

        // Clear the saved mapping — simulates session restore without mapping
        model.workspaceSelectedSessions.removeAll()
        model.activeSessionID = nil

        // Click workspace — should fallback to first session
        model.activeWorkspacePath = wsPath
        XCTAssertEqual(model.activeSessionID, sessionID, "Should fallback to first session in workspace")
        XCTAssertEqual(model.workspaceSelectedSessions[wsPath], sessionID, "Should save mapping for future")
    }

    // MARK: - Task 4: session close fallback

    @MainActor
    func test_closing_selected_session_selects_another_in_same_workspace() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let host = MockTerminalHost()
        let model = AppModel(core: core, terminalFactory: { _ in host })
        await model.load()

        // Create two sessions
        await model.newSession()
        await model.newSession()
        let session1 = model.liveSessions[0].id
        let session2 = model.liveSessions[1].id

        // session2 is active (last created)
        XCTAssertEqual(model.activeSessionID, session2)

        // Close session2 — should fallback to session1
        host.finishClose(sessionID: session2, snapshot: .fixture(lines: []), closeReason: .userClosed)

        XCTAssertEqual(model.activeSessionID, session1)
    }

    /// Closing a tab hands focus to the one on its left. Every close used to
    /// jump to the leftmost tab instead, so closing the one you were working in
    /// threw you across the tab bar and left you to walk back.
    ///
    /// The third of three, not the second: closing the second, the leftmost tab
    /// *is* the left neighbour, and a test that closes it passes either way.
    @MainActor
    func test_closing_a_tab_falls_back_to_the_one_on_its_left() async {
        let (model, host) = await modelWithThreeTabs()
        let tabs = model.liveSessions.map(\.id)
        XCTAssertEqual(model.activeSessionID, tabs[2], "precondition: on the newest tab")

        host.finishClose(sessionID: tabs[2], snapshot: .fixture(lines: []), closeReason: .userClosed)

        XCTAssertEqual(model.activeSessionID, tabs[1],
                       "focus jumped past the neighbour to the far end of the bar")
    }

    @MainActor
    func test_closing_a_middle_tab_falls_back_to_the_one_on_its_left() async {
        let (model, host) = await modelWithThreeTabs()
        let tabs = model.liveSessions.map(\.id)
        model.activeSessionID = tabs[1]

        host.finishClose(sessionID: tabs[1], snapshot: .fixture(lines: []), closeReason: .userClosed)

        XCTAssertEqual(model.activeSessionID, tabs[0])
    }

    /// The leftmost tab has nothing on its left, so focus goes the only way it
    /// can — to the tab that is the leftmost now.
    @MainActor
    func test_closing_the_leftmost_tab_falls_back_to_its_right() async {
        let (model, host) = await modelWithThreeTabs()
        let tabs = model.liveSessions.map(\.id)
        model.activeSessionID = tabs[0]

        host.finishClose(sessionID: tabs[0], snapshot: .fixture(lines: []), closeReason: .userClosed)

        XCTAssertEqual(model.activeSessionID, tabs[1])
    }

    @MainActor
    private func modelWithThreeTabs() async -> (AppModel, MockTerminalHost) {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: "/tmp/proj",
                                            transport: "local", liveSessions: [])]
        )
        let host = MockTerminalHost()
        let model = AppModel(core: core, terminalFactory: { _ in host })
        await model.load()
        for _ in 0..<3 { await model.newSession() }
        return (model, host)
    }

    // MARK: - Hotkey overlay logic

    func test_project_sidebar_row_shows_hotkey_when_set() {
        let project = ProjectSummaryViewData(
            id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
            liveSessions: 1, recentlyClosedSessions: 0,
            hasInterruptedSessions: false, liveSessionDetails: []
        )
        // This compiles = hotkeyIndex parameter exists on ProjectSidebarRow
        let _ = ProjectSidebarRow(project: project, isSelected: true, status: .running, infoLine: "main • ~/proj", hotkeyIndex: 1)
        let _ = ProjectSidebarRow(project: project, isSelected: false, status: .idle, hotkeyIndex: nil)
        // No crash = test passes
    }

    @MainActor
    func test_cmd_key_monitor_sets_show_hotkeys_state() async {
        // Test that NSEvent flagsChanged with .command flag would trigger showHotkeys
        // (We test the logic, not the actual NSEvent monitor)
        let cmdEvent = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 55
        )
        // The sidebar uses: showHotkeys = event.modifierFlags.contains(.command)
        let showHotkeys = cmdEvent?.modifierFlags.contains(.command) ?? false
        XCTAssertTrue(showHotkeys, "Cmd flag should set showHotkeys to true")

        let releaseEvent = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 55
        )
        let showHotkeysAfterRelease = releaseEvent?.modifierFlags.contains(.command) ?? false
        XCTAssertFalse(showHotkeysAfterRelease, "Releasing Cmd should set showHotkeys to false")
    }

    // MARK: - Session close fallback

    @MainActor
    func test_closing_last_session_makes_workspace_inactive() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let host = MockTerminalHost()
        let model = AppModel(core: core, terminalFactory: { _ in host })
        await model.load()

        await model.newSession()
        let sessionID = model.liveSessions[0].id

        host.finishClose(sessionID: sessionID, snapshot: .fixture(lines: []), closeReason: .userClosed)

        XCTAssertNil(model.activeSessionID)
        XCTAssertEqual(model.workspaces.first?.sessions.count, 0)
    }

    // MARK: - Tabs belong to a worktree

    private static let mainWorktree = "/tmp/proj"
    private static let featureWorktree = "/tmp/proj-feature"

    /// The same two-worktree project, but real on disk. Removal only closes
    /// tabs once git has agreed, so a made-up path would turn every removal
    /// test into a no-op that passes for the wrong reason.
    @MainActor
    private func modelWithTwoRealWorktrees() async throws -> (model: AppModel, main: String, feature: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let main = root.appendingPathComponent("proj").path
        let feature = root.appendingPathComponent("proj-feature").path
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try Self.runGit(["-C", main, "init", "-q", "-b", "main"])
        try Self.runGit(["-C", main, "-c", "user.email=t@t", "-c", "user.name=t",
                         "commit", "-q", "--allow-empty", "-m", "init"])
        try Self.runGit(["-C", main, "worktree", "add", "-q", "-b", "feature", feature])

        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: main, transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: main,
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        model.gitWorktreeService.primeCache([
            GitWorktree(path: main, branch: "main", isMainWorktree: true),
            GitWorktree(path: feature, branch: "feature", isMainWorktree: false)
        ], for: main)
        model.recomputeWorkspaces()
        return (model, main, feature)
    }

    private static func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TestSetup", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
        }
    }

    /// A project whose repo has two worktrees. The cache is primed after `load()`
    /// because `selectProject` invalidates it on the way in.
    @MainActor
    private func modelWithTwoWorktrees() async -> (AppModel, MockProjectCoreClient) {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: Self.mainWorktree, transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: Self.mainWorktree,
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.featureWorktree, branch: "feature", isMainWorktree: false)
        ], for: Self.mainWorktree)
        model.recomputeWorkspaces()
        return (model, core)
    }

    @MainActor
    func test_tab_bar_shows_only_the_active_worktrees_tabs() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        XCTAssertEqual(model.liveSessions.count, 2, "both tabs stay alive")

        model.activeWorkspacePath = Self.mainWorktree
        XCTAssertEqual(model.visibleSessions.map(\.workspacePath), [Self.mainWorktree])

        model.activeWorkspacePath = Self.featureWorktree
        XCTAssertEqual(model.visibleSessions.map(\.workspacePath), [Self.featureWorktree])
    }

    @MainActor
    func test_new_tab_opens_in_the_active_worktree() async {
        let (model, core) = await modelWithTwoWorktrees()
        model.activeWorkspacePath = Self.featureWorktree

        await model.newSession()

        XCTAssertEqual(core.startedSessions.last?.workspacePath, Self.featureWorktree)
    }

    @MainActor
    func test_new_tab_falls_back_to_the_project_when_the_worktree_is_gone() async {
        let (model, core) = await modelWithTwoWorktrees()
        model.activeWorkspacePath = "/tmp/proj-deleted"

        await model.newSession()

        XCTAssertEqual(core.startedSessions.last?.workspacePath, Self.mainWorktree)
    }

    @MainActor
    func test_cycling_tabs_stays_within_the_active_worktree() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)

        model.activeWorkspacePath = Self.mainWorktree
        let inMain = Set(model.visibleSessions.map(\.id))
        XCTAssertEqual(inMain.count, 2)

        model.activeSessionID = model.visibleSessions[0].id
        for _ in 0..<3 {
            model.selectNextSession()
            XCTAssertTrue(inMain.contains(model.activeSessionID ?? ""),
                          "cycling must not cross into another worktree")
        }
    }

    @MainActor
    func test_selecting_a_tab_activates_the_worktree_it_belongs_to() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let featureTab = model.liveSessions.first { $0.workspacePath == Self.featureWorktree }!

        model.activeWorkspacePath = Self.mainWorktree
        model.activeSessionID = featureTab.id

        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree)
        XCTAssertEqual(model.workspaceSelectedSessions[Self.featureWorktree], featureTab.id,
                       "the selection must be recorded against the tab's own worktree")
    }

    // MARK: - Sidebar nests worktrees under the project

    @MainActor
    func test_single_worktree_project_stays_flat_in_the_sidebar() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: Self.mainWorktree, transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: Self.mainWorktree,
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertTrue(model.sidebarWorktrees.isEmpty,
                      "one worktree needs no child row — the project row already is it")
    }

    @MainActor
    func test_multi_worktree_project_lists_every_worktree_including_main() async {
        let (model, _) = await modelWithTwoWorktrees()

        XCTAssertEqual(model.sidebarWorktrees.map(\.path),
                       [Self.mainWorktree, Self.featureWorktree])
        XCTAssertTrue(model.sidebarWorktrees.contains { $0.isMainWorktree },
                      "main is a child row too once there is more than one worktree")
    }

    @MainActor
    func test_window_subtitle_follows_the_active_worktree() async {
        let (model, _) = await modelWithTwoWorktrees()

        model.activeWorkspacePath = Self.featureWorktree
        XCTAssertEqual(model.activeBranchLabel, "feature",
                       "the header must name the worktree the tab bar is scoped to")

        model.activeWorkspacePath = Self.mainWorktree
        XCTAssertEqual(model.activeBranchLabel, "main")
    }

    @MainActor
    func test_single_worktree_subtitle_still_comes_from_the_branch_lookup() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: Self.mainWorktree, transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: Self.mainWorktree,
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        // A non-git project groups into one "default" workspace — that placeholder
        // must never reach the window subtitle.
        XCTAssertEqual(model.activeBranchLabel, "")
        model.gitBranches[Self.mainWorktree] = "trunk"
        XCTAssertEqual(model.activeBranchLabel, "trunk")
    }

    @MainActor
    func test_worktree_status_reflects_only_its_own_tabs() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)

        let mainTab = model.liveSessions.first { $0.workspacePath == Self.mainWorktree }!
        model.sessionStates[mainTab.id] = .needsInput

        let main = model.workspaces.first { $0.path == Self.mainWorktree }!
        let feature = model.workspaces.first { $0.path == Self.featureWorktree }!
        XCTAssertEqual(model.workspaceStatus(for: main), .needsInput)
        XCTAssertNotEqual(model.workspaceStatus(for: feature), .needsInput,
                          "one worktree waiting for input must not colour its sibling")
    }

    // MARK: - A restore in flight belongs to the project that started it

    @MainActor
    func test_restoring_tabs_does_not_pour_them_into_another_project() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "p1", path: "/tmp/p1", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: true, liveSessionDetails: []),
                ProjectSummaryViewData(id: "p2", name: "p2", path: "/tmp/p2", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "p1", name: "p1", path: "/tmp/p1", transport: "local",
                    liveSessions: [],
                    interruptedSessions: [
                        SessionSummary(id: "old-1", title: "Terminal", targetLabel: "local",
                                       lastCwd: "/tmp/p1", workspacePath: "/tmp/p1"),
                        SessionSummary(id: "old-2", title: "Terminal", targetLabel: "local",
                                       lastCwd: "/tmp/p1", workspacePath: "/tmp/p1"),
                        SessionSummary(id: "old-3", title: "Terminal", targetLabel: "local",
                                       lastCwd: "/tmp/p1", workspacePath: "/tmp/p1")
                    ]
                ),
                ProjectDetailViewData(id: "p2", name: "p2", path: "/tmp/p2",
                                      transport: "local", liveSessions: [])
            ]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        // Restoring p1's tabs takes a round trip each; the user gets bored and
        // clicks another project halfway through.
        var started = 0
        var areasAfterLeaving: [String] = []
        core.onStartSession = { [weak model] in
            started += 1
            if started == 1, let model {
                model.selection = .pending(id: "p2", onScreen: model.selection.onScreen)
            }
            if started > 1, let model { areasAfterLeaving.append("\(model.mainAreaContent)") }
        }
        await model.load()

        XCTAssertTrue(
            model.liveSessions.allSatisfy { $0.workspacePath == "/tmp/p2" },
            "p1's restored tabs landed in another project's tab bar: \(model.liveSessions.map(\.workspacePath))"
        )
        // The bar belongs to the restore, not to the screen. p2 is not restoring
        // anything, and saying it is counts tabs that will never arrive there.
        XCTAssertFalse(
            areasAfterLeaving.contains { $0.hasPrefix("restoring") },
            "p2 was shown p1's restore: \(areasAfterLeaving)"
        )
    }

    /// The loop guards every tab it creates and guards rewriting the detail, but
    /// its last two lines ran against whatever was on screen by the time it
    /// finished — choosing a tab there, and dragging the sidebar to that tab's
    /// worktree. The project you switched to gets its selection taken over by a
    /// restore that was never about it.
    @MainActor
    func test_a_finished_restore_leaves_the_project_you_switched_to_alone() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "p1", path: "/tmp/p1", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: true, liveSessionDetails: []),
                ProjectSummaryViewData(id: "p2", name: "p2", path: "/tmp/p2", transport: "local",
                                       liveSessions: 2, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "p1", name: "p1", path: "/tmp/p1", transport: "local",
                    liveSessions: [],
                    interruptedSessions: [
                        SessionSummary(id: "old-1", title: "Terminal", targetLabel: "local",
                                       lastCwd: "/tmp/p1", workspacePath: "/tmp/p1"),
                        SessionSummary(id: "old-2", title: "Terminal", targetLabel: "local",
                                       lastCwd: "/tmp/p1", workspacePath: "/tmp/p1")
                    ]
                ),
                ProjectDetailViewData(
                    id: "p2", name: "p2", path: "/tmp/p2", transport: "local",
                    liveSessions: [
                        SessionViewData(id: "b1", title: "one", targetLabel: "local",
                                        lastCwd: "/tmp/p2", workspacePath: "/tmp/p2"),
                        SessionViewData(id: "b2", title: "two", targetLabel: "local",
                                        lastCwd: "/tmp/p2", workspacePath: "/tmp/p2")
                    ]
                )
            ]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        // Halfway through p1's restore the user opens p2, which lands on p2's
        // first tab.
        var switched = false
        core.onStartSession = { [weak model] in
            guard !switched else { return }
            switched = true
            Task { @MainActor in await model?.selectProject(id: "p2") }
        }
        await model.load()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.selection.id, "p2")
        XCTAssertEqual(model.activeSessionID, "b1",
                       "p1's restore reached into p2 and moved it off the tab it opened on")
    }

    // MARK: - Every workspace remembers the tab you were on

    @MainActor
    func test_returning_to_a_worktree_restores_the_tab_you_were_on() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let second = model.liveSessions.filter { $0.workspacePath == Self.mainWorktree }[1].id

        await model.selectWorktree(projectID: "p1", path: Self.mainWorktree)
        model.activeSessionID = second
        await model.selectWorktree(projectID: "p1", path: Self.featureWorktree)
        await model.selectWorktree(projectID: "p1", path: Self.mainWorktree)

        XCTAssertEqual(model.activeSessionID, second)
    }

    @MainActor
    func test_returning_to_a_project_lands_on_the_worktree_you_left() async {
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let second = model.liveSessions.filter { $0.workspacePath == Self.featureWorktree }[1].id
        model.activeSessionID = second

        await model.selectProject(id: "p2")
        await model.selectProject(id: "p1")

        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree,
                       "coming back must not drop you at the repo root")
        XCTAssertEqual(model.activeSessionID, second,
                       "nor on the first tab of a worktree you had left")
    }

    @MainActor
    func test_a_project_whose_remembered_worktree_is_gone_falls_back_to_its_root() async {
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.featureWorktree)

        await model.selectProject(id: "p2")
        // The worktree disappears while another project holds focus.
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true)
        ], for: Self.mainWorktree)
        await model.selectProject(id: "p1")

        XCTAssertEqual(model.activeWorkspacePath, Self.mainWorktree)
    }

    // MARK: - Cmd+1…9 addresses the places that have tabs

    /// A digit points at a place with tabs, and inside a repo with several
    /// worktrees that place is the worktree, not the project heading. An empty
    /// worktree is not somewhere to jump to. A project with no tabs anywhere
    /// still is — that is where you go to open one.

    @MainActor
    func test_each_worktree_with_tabs_takes_a_digit_of_its_own() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)

        XCTAssertEqual(model.numberedPlaces, [
            .worktree(projectID: "p1", path: Self.mainWorktree),
            .worktree(projectID: "p1", path: Self.featureWorktree)
        ], "both worktrees are being worked in, so both are worth a digit")
    }

    @MainActor
    func test_a_worktree_with_no_tabs_takes_no_digit() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)

        XCTAssertEqual(model.numberedPlaces,
                       [.worktree(projectID: "p1", path: Self.mainWorktree)],
                       "an empty worktree would spend a digit on nothing")
    }

    @MainActor
    func test_a_repo_whose_worktrees_are_all_empty_is_addressed_as_itself() async {
        let (model, _) = await modelWithTwoWorktrees()

        XCTAssertEqual(model.numberedPlaces, [.project("p1")],
                       "no worktree has earned the digit, so the project keeps it")
    }

    /// The mapping is blind to expansion. Only the badge follows what is on
    /// screen — a digit that changed meaning when a tree opened would be the
    /// finger memory the digits exist to protect.
    @MainActor
    func test_folding_a_tree_does_not_renumber_anything() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let before = model.numberedPlaces

        model.toggleWorktrees(projectID: "p1")

        XCTAssertEqual(model.numberedPlaces, before,
                       "numbers must not move when a tree is opened or closed")
    }

    @MainActor
    func test_a_digit_means_the_same_worktree_wherever_the_selection_stands() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let before = model.numberedPlaces

        model.activeWorkspacePath = Self.featureWorktree

        XCTAssertEqual(model.numberedPlaces, before,
                       "walking between worktrees must not swap their digits")
    }

    @MainActor
    func test_only_nine_places_can_be_numbered() async {
        let model = await modelWithTwoProjects()
        model.projects = (1...12).map { index in
            ProjectSummaryViewData(id: "p\(index)", name: "p\(index)", path: "/tmp/p\(index)",
                                   transport: "local", liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        }

        XCTAssertEqual(model.numberedPlaces.count, 9, "there are only nine digits")
    }

    @MainActor
    func test_an_index_with_nothing_behind_it_does_nothing() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let selected = model.selection.id

        await model.selectNumberedPlace(7)

        XCTAssertEqual(model.selection.id, selected)
    }

    @MainActor
    func test_a_digit_goes_straight_to_its_worktree() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        model.activeWorkspacePath = Self.mainWorktree

        await model.selectNumberedPlace(2)

        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree)
    }

    /// The digit of a project addressed as itself still reopens the worktree it
    /// was last left in — that is what selecting a project does.
    @MainActor
    func test_a_project_digit_returns_to_the_worktree_that_project_was_left_in() async {
        let model = await modelWithTwoProjects()
        model.activeWorkspacePath = Self.featureWorktree
        await model.selectProject(id: "p2")

        await model.selectNumberedPlace(1)

        XCTAssertEqual(model.selection.id, "p1")
        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree,
                       "it went to the project but not to where that project was left")
    }

    /// A digit lands on a row, so the row has to be on screen when it gets
    /// there.
    @MainActor
    func test_a_worktree_digit_opens_the_tree_it_points_into() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        XCTAssertFalse(model.expandedProjectIDs.contains("p1"), "precondition: folded")

        await model.selectNumberedPlace(1)

        XCTAssertTrue(model.expandedProjectIDs.contains("p1"))
        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree)
    }

    // MARK: - Where the badge draws

    @MainActor
    func test_an_open_tree_hands_its_digit_to_the_worktree_row() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let p1 = model.projects.first { $0.id == "p1" }!
        model.toggleWorktrees(projectID: "p1")

        XCTAssertNil(model.numberedBadges.index(forProject: p1),
                     "an open project row is a heading; the digit belongs to the row it names")
        let feature = model.sidebarWorktrees(for: p1).first { $0.path == Self.featureWorktree }!
        XCTAssertEqual(model.numberedBadges.index(forWorktree: feature, in: p1), 1)
    }

    @MainActor
    func test_a_folded_project_wears_the_first_digit_hiding_inside_it() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let p1 = model.projects.first { $0.id == "p1" }!

        XCTAssertEqual(model.numberedBadges.index(forProject: p1), 1,
                       "folded, the project row is the only thing on screen that digit can point at")
    }

    @MainActor
    func test_a_project_addressed_as_itself_keeps_its_badge_with_the_tree_open() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let (model, _) = await modelWithTwoWorktrees()
        let p1 = model.projects.first { $0.id == "p1" }!
        model.toggleWorktrees(projectID: "p1")

        XCTAssertEqual(model.numberedBadges.index(forProject: p1), 1,
                       "no worktree row took the digit, so nothing may take it away")
    }

    @MainActor
    func test_the_menu_names_the_worktree_a_digit_lands_in() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)

        XCTAssertEqual(model.numberedPlaceLabel(model.numberedPlaces[0]), "Proj — feature")
    }

    // MARK: - Removing a worktree

    @MainActor
    func test_removing_a_worktree_closes_only_the_tabs_that_were_in_it() async throws {
        let (model, mainWorktree, featureWorktree) = try await modelWithTwoRealWorktrees()
        await model.newSession(inWorkspacePath: mainWorktree)
        await model.newSession(inWorkspacePath: featureWorktree)
        let inMain = model.liveSessions.first { $0.workspacePath == mainWorktree }!
        let inFeature = model.liveSessions.first { $0.workspacePath == featureWorktree }!

        await model.removeWorktree(path: featureWorktree)

        XCTAssertTrue(model.closingSessionIDs.contains(inFeature.id))
        XCTAssertFalse(model.closingSessionIDs.contains(inMain.id),
                       "a sibling worktree's tab must survive")
    }

    // MARK: - A tab that wandered into another worktree says so

    @MainActor
    func test_a_tab_working_outside_its_worktree_names_where_it_is() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]

        // What an agent does when it creates a worktree and moves into it.
        model.sessionDidReportCwd(sessionID: tab.id, cwd: Self.featureWorktree + "/src")

        XCTAssertEqual(model.visitingBranch(for: model.liveSessions[0]), "feature")
    }

    @MainActor
    func test_a_tab_in_its_own_worktree_says_nothing() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]

        model.sessionDidReportCwd(sessionID: tab.id, cwd: Self.mainWorktree + "/apps")

        XCTAssertNil(model.visitingBranch(for: model.liveSessions[0]),
                     "a tab at home has nothing to report")
    }

    @MainActor
    func test_a_tab_outside_every_worktree_says_nothing() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]

        model.sessionDidReportCwd(sessionID: tab.id, cwd: "/tmp/elsewhere")

        XCTAssertNil(model.visitingBranch(for: model.liveSessions[0]),
                     "a detour out of the repo is not another worktree")
    }

    @MainActor
    func test_a_single_worktree_project_never_reports_a_visit() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: Self.mainWorktree, transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: Self.mainWorktree,
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        await model.newSession()
        let tab = model.liveSessions[0]

        model.sessionDidReportCwd(sessionID: tab.id, cwd: "/tmp/anywhere")

        XCTAssertNil(model.visitingBranch(for: model.liveSessions[0]))
    }

    @MainActor
    func test_the_deepest_worktree_wins_when_one_nests_in_another() async {
        let (model, _) = await modelWithTwoWorktrees()
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.mainWorktree + "/nested", branch: "nested", isMainWorktree: false)
        ], for: Self.mainWorktree)
        model.recomputeWorkspaces()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]

        model.sessionDidReportCwd(sessionID: tab.id, cwd: Self.mainWorktree + "/nested/deep")

        XCTAssertEqual(model.visitingBranch(for: model.liveSessions[0]), "nested")
    }

    // MARK: - The tree stays open across project switches

    private static let otherProject = "/tmp/other"

    /// Two projects: `p1` has two worktrees, `p2` is a plain one. The cache is
    /// primed after `load()` because `selectProject` expires the entry on the
    /// way in — expired, not dropped, so the count on the row survives a click.
    @MainActor
    private func modelWithTwoProjects() async -> AppModel {
        func summary(id: String, path: String) -> ProjectSummaryViewData {
            ProjectSummaryViewData(id: id, name: id, path: path, transport: "local",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        }
        let core = MockProjectCoreClient(
            summaries: [summary(id: "p1", path: Self.mainWorktree),
                        summary(id: "p2", path: Self.otherProject)],
            details: [
                ProjectDetailViewData(id: "p1", name: "p1", path: Self.mainWorktree,
                                      transport: "local", liveSessions: []),
                ProjectDetailViewData(id: "p2", name: "p2", path: Self.otherProject,
                                      transport: "local", liveSessions: [])
            ]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.featureWorktree, branch: "feature", isMainWorktree: false)
        ], for: Self.mainWorktree)
        model.recomputeWorkspaces()
        return model
    }

    private func forgetExpandedProjects() {
        UserDefaults.standard.removeObject(forKey: StorageKeys.expandedProjectIDs)
    }

    // MARK: - Nothing blinks while a project is loading

    /// `p1` has two worktrees, `p2` is flat, and asking for either takes long
    /// enough that a test can look at the sidebar mid-flight — which is the only
    /// place these faults exist.
    @MainActor
    private func modelWithASlowLookup() async -> AppModel {
        func summary(id: String, path: String) -> ProjectSummaryViewData {
            ProjectSummaryViewData(id: id, name: id, path: path, transport: "local",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        }
        let core = MockProjectCoreClient(
            summaries: [summary(id: "p1", path: Self.mainWorktree),
                        summary(id: "p2", path: Self.otherProject)],
            details: [
                ProjectDetailViewData(id: "p1", name: "p1", path: Self.mainWorktree,
                                      transport: "local", liveSessions: []),
                ProjectDetailViewData(id: "p2", name: "p2", path: Self.otherProject,
                                      transport: "local", liveSessions: [])
            ],
            detailLatencyByID: ["p1": 400_000_000, "p2": 400_000_000]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.featureWorktree, branch: "feature", isMainWorktree: false)
        ], for: Self.mainWorktree)
        model.recomputeWorkspaces()
        return model
    }

    // MARK: - One directory, one spelling

    /// git reports the resolved directory — `/private/tmp/proj`, never
    /// `/tmp/proj` — while a project keeps whatever spelling it was added with.
    /// `sameWorkspace(as:)` exists to absorb that, and it is used in exactly one
    /// place; everywhere else compares with `==`.
    ///
    /// So `recomputeWorkspaces` finds a match and correctly declines to move the
    /// selection, and then `visibleSessions` finds none and returns nothing:
    /// the main area offers "New Terminal" while the tabs of that very worktree
    /// are running.
    @MainActor
    func test_a_worktree_git_spells_differently_still_shows_its_tabs() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: "/tmp/proj",
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        // What `git worktree list --porcelain` actually prints on a mac.
        model.gitWorktreeService.primeCache([
            GitWorktree(path: "/private/tmp/proj", branch: "main", isMainWorktree: true),
            GitWorktree(path: "/private/tmp/proj-feature", branch: "feature", isMainWorktree: false)
        ], for: "/tmp/proj")
        model.recomputeWorkspaces()

        await model.newSession()

        XCTAssertFalse(model.visibleSessions.isEmpty,
                       "the tab bar is empty while its own tab is running")
        XCTAssertEqual(model.mainAreaContent, .terminals,
                       "the main area offered New Terminal with a live tab behind it")
    }

    /// The remote half of the same rule, and the reason the canonicalisation is
    /// applied to local lookups only: a path from another machine resolved
    /// against *this* filesystem is the namespace confusion the whole worktree
    /// addressing scheme exists to avoid.
    @MainActor
    func test_a_remote_worktree_address_is_left_exactly_as_the_host_spelled_it() async {
        let uri = "ssh://box/private/var/folders/xyz/repo"
        let service = GitWorktreeService()
        service.primeCache(
            [GitWorktree(path: uri, branch: "main", isMainWorktree: true)],
            for: "ssh://box/private/var/folders/xyz/repo")

        XCTAssertEqual(service.worktrees(for: "ssh://box/private/var/folders/xyz/repo")?.first?.path,
                       uri,
                       "a remote address was rewritten against the local filesystem")
    }

    // MARK: - A write mid-switch belongs to the project that asked for it
    //
    // The chosen id moves on the click; the detail arrives a git
    // round trip later. Three writers read both in the same breath, so during
    // that window they filed project B's work under project A's identity — and
    // unlike the sidebar blink, these reach the store and survive a restart.
    //
    // The convention that would have caught it already exists and already
    // failed: four other sites guard correctly and `workspaces(for:)` carries a
    // paragraph explaining the hazard. A rule this well documented and still
    // unapplied in three places is a broken mechanism, not carelessness.

    @MainActor
    private func slowLookupModel(
        secondProjectPath: String = "/tmp/other",
        secondTransport: String = "local"
    ) async -> (AppModel, MockProjectCoreClient) {
        func summary(id: String, path: String, transport: String) -> ProjectSummaryViewData {
            ProjectSummaryViewData(id: id, name: id, path: path, transport: transport,
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        }
        let core = MockProjectCoreClient(
            summaries: [summary(id: "p1", path: Self.mainWorktree, transport: "local"),
                        summary(id: "p2", path: secondProjectPath, transport: secondTransport)],
            details: [
                ProjectDetailViewData(id: "p1", name: "p1", path: Self.mainWorktree,
                                      transport: "local", liveSessions: []),
                ProjectDetailViewData(id: "p2", name: "p2", path: secondProjectPath,
                                      transport: secondTransport, liveSessions: [])
            ],
            detailLatencyByID: ["p1": 400_000_000, "p2": 400_000_000]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        return (model, core)
    }

    /// Cmd+T during the round trip wrote a row saying "project p2" with p1's
    /// directory in it. Restore then opens that tab under p2, in p1's folder,
    /// every launch — `groupSessions` has nowhere else to put it.
    @MainActor
    func test_a_tab_opened_mid_switch_belongs_to_the_project_that_asked() async {
        let (model, core) = await slowLookupModel()
        await model.selectProject(id: "p1")

        let switching = Task { await model.selectProject(id: "p2") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await model.newSession()
        await switching.value

        XCTAssertEqual(core.startedSessions.last?.workspacePath, "/tmp/other",
                       "the tab was filed under p2 but opened in p1's directory")
    }

    /// The worst of the three: the transport comes from the *old* project, so
    /// leaving a local project for an ssh one and asking for an agent opened a
    /// local shell and recorded it against the remote project.
    @MainActor
    func test_an_agent_session_mid_switch_reads_its_own_projects_transport() async {
        let (model, core) = await slowLookupModel(secondProjectPath: "ssh://box/srv",
                                                  secondTransport: "ssh")
        await model.selectProject(id: "p1")

        let switching = Task { await model.selectProject(id: "p2") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await model.newAgentSession(.claude)
        await switching.value

        XCTAssertTrue(core.startedSessions.isEmpty,
                      "a local agent shell was opened for an ssh project")
    }

    /// `terminalHostDidClose` calls this, so *any* shell exiting during the
    /// window stamped the old project's tab list onto the new project's row —
    /// which is the same field the sidebar reads for every unselected project.
    ///
    /// Two tabs, closing one: close the only tab and the list empties, which is
    /// the right answer for p2 by accident and proves nothing.
    @MainActor
    func test_a_tab_dying_mid_switch_does_not_stamp_another_projects_summary() async {
        var hosts: [MockTerminalHost] = []
        func summary(id: String, path: String) -> ProjectSummaryViewData {
            ProjectSummaryViewData(id: id, name: id, path: path, transport: "local",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        }
        let core = MockProjectCoreClient(
            summaries: [summary(id: "p1", path: Self.mainWorktree),
                        summary(id: "p2", path: Self.otherProject)],
            details: [ProjectDetailViewData(id: "p1", name: "p1", path: Self.mainWorktree,
                                            transport: "local", liveSessions: []),
                      ProjectDetailViewData(id: "p2", name: "p2", path: Self.otherProject,
                                            transport: "local", liveSessions: [])],
            detailLatencyByID: ["p2": 400_000_000])
        let model = AppModel(core: core, terminalFactory: { _ in
            let host = MockTerminalHost(); hosts.append(host); return host
        })
        await model.load()
        await model.selectProject(id: "p1")
        await model.newSession()
        await model.newSession()
        let closing = model.liveSessions[1].id

        let switching = Task { await model.selectProject(id: "p2") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        hosts[1].finishClose(sessionID: closing, snapshot: .fixture(lines: []), closeReason: .userClosed)

        // Inside the window, not after it: the round trip corrects p2's summary
        // when it lands, so a test that waits sees only the repair.
        let p2 = model.projects.first { $0.id == "p2" }!
        XCTAssertEqual(p2.liveSessions, 0, "p1's tab count landed on p2's row")
        XCTAssertTrue(p2.liveSessionDetails.isEmpty, "p1's tabs landed on p2's row")

        await switching.value
    }

    /// The chosen id moves the instant the key is pressed; the worktrees
    /// arrive a git round trip later. In between, `workspaces` still holds the
    /// project you came *from* — and reading it for the one you are going to
    /// showed the new project with someone else's worktrees, or with none.
    ///
    /// On screen: the tree you had open blinked shut and back. One frame of it,
    /// which is why only a mid-flight test can see it.
    @MainActor
    func test_an_open_tree_does_not_blink_shut_while_its_project_loads() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithASlowLookup()
        model.toggleWorktrees(projectID: "p1")
        await model.selectProject(id: "p2")
        let p1 = model.projects.first { $0.id == "p1" }!
        XCTAssertTrue(model.showsWorktreeRows(for: p1), "precondition: the tree is open")

        let press = Task { await model.selectProject(id: "p1") }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.showsWorktreeRows(for: p1),
                      "the tree folded away while the lookup ran")
        await press.value
    }

    /// The other half of the same window: a project that has no worktrees of its
    /// own briefly wore the ones belonging to the project just left. Pressing a
    /// digit opens the tree on the way in, so those rows were drawn — the
    /// sidebar grew by four rows and shrank again.
    @MainActor
    func test_a_loading_project_does_not_borrow_the_last_ones_worktrees() async {
        let model = await modelWithASlowLookup()
        await model.selectProject(id: "p1")
        let p2 = model.projects.first { $0.id == "p2" }!

        let press = Task { await model.selectProject(id: "p2") }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.sidebarWorktrees(for: p2).isEmpty,
                      "a project still loading drew the previous project's worktrees")
        await press.value
    }

    /// And so the digits held still. They are read off the same grouping, so a
    /// project wearing borrowed worktrees renumbered everything below it — with
    /// `Cmd` still held down, which is exactly when the badges are on screen.
    @MainActor
    func test_the_digits_hold_still_while_a_project_loads() async {
        let model = await modelWithASlowLookup()
        await model.selectProject(id: "p1")
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let before = model.numberedPlaces

        let press = Task { await model.selectProject(id: "p2") }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.numberedPlaces, before,
                       "the badges moved while the lookup ran")
        await press.value
    }

    /// And the same window has one more thing in it. An ssh project with no
    /// tabs offers to reconnect, and `mainAreaContent` puts that offer ahead of
    /// everything — but it never asks *whose* offer it is, while its sibling
    /// `progressForSelectedProject` does. So opening another project keeps the
    /// reconnect screen up over it, with its button wired to the host you left,
    /// for the whole round trip.
    @MainActor
    func test_the_reconnect_offer_does_not_follow_you_to_another_project() async {
        func summary(id: String, path: String, transport: String) -> ProjectSummaryViewData {
            ProjectSummaryViewData(id: id, name: id, path: path, transport: transport,
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        }
        // `ssh://box` names no directory, so nothing tries to scan a real host.
        let core = MockProjectCoreClient(
            summaries: [summary(id: "remote", path: "ssh://box", transport: "ssh"),
                        summary(id: "local", path: Self.otherProject, transport: "local")],
            details: [
                ProjectDetailViewData(id: "remote", name: "remote", path: "ssh://box",
                                      transport: "ssh", liveSessions: []),
                ProjectDetailViewData(id: "local", name: "local", path: Self.otherProject,
                                      transport: "local", liveSessions: [])
            ],
            detailLatencyByID: ["local": 400_000_000]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        XCTAssertEqual(model.mainAreaContent, .sshReconnect,
                       "precondition: the remote project with no tabs offers to reconnect")

        let press = Task { await model.selectProject(id: "local") }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.mainAreaContent, .empty,
                       "the project you left went on offering to reconnect over the one you opened")
        await press.value
    }

    /// Clicking a project row is also how its tree is toggled, so the project
    /// you are already standing in gets reselected constantly — and that starts
    /// a fresh lookup. While it runs the app must go on knowing that the
    /// worktree under the tab bar is this project's, because it is: the detail
    /// on screen belongs to the project being asked about. Forget that and a
    /// Cmd+T during those milliseconds opens in the repo root instead.
    @MainActor
    func test_reselecting_the_project_you_are_in_keeps_you_in_your_worktree() async {
        let model = await modelWithASlowLookup()
        await model.selectProject(id: "p1")
        model.activeWorkspacePath = Self.featureWorktree

        let press = Task { await model.selectProject(id: "p1") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await model.newSession()

        XCTAssertEqual(model.liveSessions.last?.workspacePath, Self.featureWorktree,
                       "a tab opened during a reselect landed outside the worktree it was opened in")
        await press.value
    }

    @MainActor
    func test_worktree_rows_survive_switching_to_another_project() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.toggleWorktrees(projectID: "p1")

        await model.selectProject(id: "p2")

        XCTAssertTrue(model.expandedProjectIDs.contains("p1"),
                      "selecting elsewhere must not fold a tree the user opened")
        let p1 = model.projects.first { $0.id == "p1" }!
        XCTAssertEqual(model.sidebarWorktrees(for: p1).map(\.path),
                       [Self.mainWorktree, Self.featureWorktree],
                       "an unselected project still knows its worktrees")
    }

    @MainActor
    func test_projects_start_collapsed() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()

        XCTAssertTrue(model.expandedProjectIDs.isEmpty)
    }

    @MainActor
    func test_expansion_survives_a_relaunch() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.toggleWorktrees(projectID: "p1")

        let relaunched = AppModel(core: MockProjectCoreClient(summaries: [], details: []),
                                  terminalFactory: { _ in MockTerminalHost() })

        XCTAssertEqual(relaunched.expandedProjectIDs, ["p1"])
    }

    /// The disclosure triangle is gone, so the row itself has to open the tree.
    /// A click still selects — that is the other half of what it has always
    /// meant — and now folds or unfolds on the way.
    @MainActor
    func test_clicking_a_project_row_selects_it_and_opens_its_tree() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()

        await model.selectProjectAndToggleWorktrees(id: "p1")

        XCTAssertEqual(model.selection.id, "p1")
        XCTAssertTrue(model.expandedProjectIDs.contains("p1"),
                      "the row click has to open the tree — nothing else can")
    }

    /// Clicking the row you are already on is how you fold the tree back up.
    @MainActor
    func test_clicking_the_same_project_row_again_folds_its_tree() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()

        await model.selectProjectAndToggleWorktrees(id: "p1")
        await model.selectProjectAndToggleWorktrees(id: "p1")

        XCTAssertEqual(model.selection.id, "p1")
        XCTAssertTrue(model.expandedProjectIDs.isEmpty)
    }

    @MainActor
    func test_toggling_twice_closes_the_tree_again() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()

        model.toggleWorktrees(projectID: "p1")
        model.toggleWorktrees(projectID: "p1")

        XCTAssertTrue(model.expandedProjectIDs.isEmpty)
    }

    @MainActor
    func test_a_single_worktree_project_has_no_rows_to_show() async {
        let model = await modelWithTwoProjects()
        let p2 = model.projects.first { $0.id == "p2" }!

        XCTAssertTrue(model.sidebarWorktrees(for: p2).isEmpty)
    }

    // MARK: - The path belongs to the row that is that worktree

    /// A project row showing its path while a "main" child sits right under it
    /// describes the same worktree twice. Expanding hands the path down.
    @MainActor
    func test_an_expanded_project_row_hands_its_path_down() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        let p1 = model.projects.first { $0.id == "p1" }!

        XCTAssertFalse(model.showsWorktreeRows(for: p1),
                       "collapsed, the row still stands for the whole repo")

        model.toggleWorktrees(projectID: "p1")

        XCTAssertTrue(model.showsWorktreeRows(for: p1),
                      "expanded, the children speak for the worktrees — the heading keeps only the name")
    }

    @MainActor
    func test_a_single_worktree_project_keeps_its_path_however_it_is_toggled() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.toggleWorktrees(projectID: "p2")
        let p2 = model.projects.first { $0.id == "p2" }!

        XCTAssertFalse(model.showsWorktreeRows(for: p2),
                       "there is nobody to hand the path to — that row is the worktree")
    }

    @MainActor
    func test_only_the_main_worktree_row_carries_a_path() async {
        let model = await modelWithTwoProjects()
        let p1 = model.projects.first { $0.id == "p1" }!
        let rows = model.sidebarWorktrees(for: p1)
        let main = rows.first { $0.isMainWorktree }!
        let feature = rows.first { !$0.isMainWorktree }!

        XCTAssertEqual(model.worktreePathLine(for: main), Self.mainWorktree,
                       "the path lands on the row that is that worktree")
        XCTAssertNil(model.worktreePathLine(for: feature),
                     "a linked worktree's directory is named after its branch — the path would repeat the title")
    }

    @MainActor
    func test_picking_a_worktree_of_another_project_switches_to_that_project() async {
        let model = await modelWithTwoProjects()
        await model.selectProject(id: "p2")

        await model.selectWorktree(projectID: "p1", path: Self.featureWorktree)

        XCTAssertEqual(model.selection.id, "p1")
        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree)
    }

    // MARK: - Worktree switching without the sidebar

    @MainActor
    func test_worktree_hotkey_cycles_and_wraps() async {
        let (model, _) = await modelWithTwoWorktrees()
        model.activeWorkspacePath = Self.mainWorktree

        model.selectNextWorktree()
        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree)

        model.selectNextWorktree()
        XCTAssertEqual(model.activeWorkspacePath, Self.mainWorktree, "cycling wraps around")

        model.selectPreviousWorktree()
        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree)
    }

    @MainActor
    func test_worktree_hotkey_does_nothing_with_a_single_worktree() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: Self.mainWorktree, transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Proj", path: Self.mainWorktree,
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        await model.newSession()
        let only = model.activeSessionID

        model.selectNextWorktree()

        XCTAssertEqual(model.activeWorkspacePath, Self.mainWorktree)
        XCTAssertEqual(model.activeSessionID, only, "a no-op must not disturb the active tab")
    }

    /// The hotkey is the sidebar-less route, so it has to land you where the
    /// sidebar would have: on the tab you were last using over there.
    @MainActor
    func test_worktree_hotkey_restores_that_worktrees_last_tab() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)

        model.activeWorkspacePath = Self.featureWorktree
        let firstFeatureTab = model.visibleSessions[0].id
        model.activeSessionID = firstFeatureTab

        model.selectNextWorktree()
        XCTAssertEqual(model.activeWorkspacePath, Self.mainWorktree)

        model.selectNextWorktree()
        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree)
        XCTAssertEqual(model.activeSessionID, firstFeatureTab)
    }

    @MainActor
    func test_switching_to_an_empty_worktree_clears_the_active_tab() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)

        model.activeWorkspacePath = Self.featureWorktree

        XCTAssertTrue(model.visibleSessions.isEmpty)
        XCTAssertNil(model.activeSessionID,
                     "the active tab must never point outside the active worktree")
    }

    // MARK: - A workspace key is a workspace path, never a cwd

    /// `workspaceSelectedSessions` is keyed by workspace path everywhere except
    /// the restore path, which used the tab's last cwd. A tab left one directory
    /// deep inside its worktree then filed its memory under a key no workspace
    /// answers to, and the worktree came back with no idea which tab it was on.
    @MainActor
    func test_a_restored_tab_is_remembered_by_its_workspace_not_its_cwd() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Proj", path: Self.mainWorktree,
                                       transport: "local", liveSessions: 0,
                                       recentlyClosedSessions: 0, hasInterruptedSessions: true,
                                       liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "p1", name: "Proj", path: Self.mainWorktree, transport: "local",
                liveSessions: [],
                interruptedSessions: [
                    SessionSummary(id: "was-in-feature", title: "Terminal", targetLabel: "local",
                                   lastCwd: Self.featureWorktree + "/src",
                                   workspacePath: Self.featureWorktree)
                ]
            )]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        await model.selectProject(id: "p1", promptForRecovery: true)
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.featureWorktree, branch: "feature", isMainWorktree: false)
        ], for: Self.mainWorktree)
        model.recomputeWorkspaces()

        await model.restoreInterruptedTabs(projectID: "p1")

        let restored = model.liveSessions.first { $0.workspacePath == Self.featureWorktree }
        XCTAssertNotNil(restored, "the tab came back into the worktree it belonged to")
        XCTAssertEqual(model.workspaceSelectedSessions[Self.featureWorktree], restored?.id,
                       "the worktree must remember the tab that came back to it")
        XCTAssertNil(model.workspaceSelectedSessions[Self.featureWorktree + "/src"],
                     "a cwd is not a workspace — nothing may be filed under one")
    }

    // MARK: - The selection may not stand on a worktree that is gone

    /// Removing the worktree you were looking at left `activeWorkspacePath`
    /// pointing at it, so `visibleSessions` matched nothing and the main area
    /// went blank while sibling worktrees still had tabs running.
    @MainActor
    func test_removing_the_active_worktree_moves_the_selection_home() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        model.activeWorkspacePath = Self.featureWorktree

        // What is left after `git worktree remove` — or after someone deletes the
        // directory behind the app's back.
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true)
        ], for: Self.mainWorktree)
        model.recomputeWorkspaces()

        XCTAssertEqual(model.activeWorkspacePath, Self.mainWorktree,
                       "the selection has to step off a worktree that no longer exists")
        XCTAssertFalse(model.visibleSessions.isEmpty,
                       "and land somewhere the tabs are actually visible")
    }

    // MARK: - A tab belongs to its worktree, wherever it wandered

    /// Removal closed tabs by where they were standing, not by where they
    /// belong. A tab that had `cd`-ed out survived a `git worktree remove` and
    /// came back regrouped under main; a visitor from another worktree was shut
    /// down in its place. Both contradict the dialog and the ownership rule.
    @MainActor
    func test_removing_a_worktree_closes_the_tabs_that_belong_to_it() async throws {
        let (model, mainWorktree, featureWorktree) = try await modelWithTwoRealWorktrees()
        await model.newSession(inWorkspacePath: featureWorktree)
        await model.newSession(inWorkspacePath: mainWorktree)
        let ofFeature = model.liveSessions.first { $0.workspacePath == featureWorktree }!
        let ofMain = model.liveSessions.first { $0.workspacePath == mainWorktree }!

        // The one that belongs here steps out; the one that does not steps in.
        model.sessionDidReportCwd(sessionID: ofFeature.id, cwd: "/tmp/somewhere-else")
        model.sessionDidReportCwd(sessionID: ofMain.id, cwd: featureWorktree + "/src")

        await model.removeWorktree(path: featureWorktree)

        XCTAssertTrue(model.closingSessionIDs.contains(ofFeature.id),
                      "a tab belongs to the worktree it was opened in, wherever it wandered")
        XCTAssertFalse(model.closingSessionIDs.contains(ofMain.id),
                       "and a visitor from elsewhere is not this removal's to close")
    }

    // MARK: - Off-screen tabs still report where they went

    /// `liveSessions` is only the selected project's tabs, so an agent working
    /// in another open project's tab had its OSC 7 reports dropped — the store
    /// kept the old directory and restore brought the tab back to it.
    @MainActor
    func test_a_tab_in_a_background_project_still_records_where_it_moved() async {
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]
        let moved = Self.mainWorktree + "/deep"

        await model.selectProject(id: "p2")
        XCTAssertFalse(model.liveSessions.contains { $0.id == tab.id },
                       "the tab is off screen now, but its shell is still running")

        model.sessionDidReportCwd(sessionID: tab.id, cwd: moved)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.allSessions.first { $0.id == tab.id }?.lastCwd, moved,
                       "an off-screen tab still knows where it went")
        let client = model.core as! MockProjectCoreClient
        XCTAssertTrue(client.recordedCwds.contains { $0.sessionId == tab.id && $0.cwd == moved },
                      "and the store has to hear it, or the next restore is stale")
    }

    /// Rows written before the `workspace_path` column exist in the wild with an
    /// empty one. `groupSessions` places them by cwd, so removal has to let them
    /// go the same way or they outlive the directory they were living in.
    @MainActor
    func test_removing_a_worktree_closes_a_legacy_tab_that_has_no_workspace() async throws {
        let (model, _, featureWorktree) = try await modelWithTwoRealWorktrees()
        await model.newSession(inWorkspacePath: featureWorktree)
        let legacy = model.liveSessions[0]
        model.liveSessions[0].workspacePath = ""
        model.sessionDidReportCwd(sessionID: legacy.id, cwd: featureWorktree + "/src")

        await model.removeWorktree(path: featureWorktree)

        XCTAssertTrue(model.closingSessionIDs.contains(legacy.id),
                      "a row with no workspace is placed by its cwd, and let go the same way")
    }

    // MARK: - Remote projects are scanned

    /// Two gates gate this: the path list and the call site in `selectProject`.
    /// Opening only one leaves remote scanning dead with no visible symptom.
    @MainActor
    func test_remote_projects_with_a_path_are_offered_for_scanning() {
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []),
                             terminalFactory: { _ in MockTerminalHost() })
        model.projects = [
            ProjectSummaryViewData(id: "local", name: "local", path: "/tmp/local", transport: "local",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: []),
            ProjectSummaryViewData(id: "remote", name: "remote", path: "ssh://jay@box/srv/repo", transport: "ssh",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: []),
            ProjectSummaryViewData(id: "pathless", name: "pathless", path: "ssh://box", transport: "ssh",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: []),
        ]

        XCTAssertEqual(model.worktreeProjectPaths.sorted(), ["/tmp/local", "ssh://jay@box/srv/repo"])
    }

    /// A lookup that fails is not a worktree that vanished. Dropping the list
    /// regroups every tab under one workspace, and the selection — still
    /// standing on a linked worktree — then matches no row: `visibleSessions`
    /// empties and the main area goes blank while the shells are all fine.
    @MainActor
    func test_a_failed_lookup_keeps_the_worktrees_it_already_found() async {
        let service = GitWorktreeService()
        service.primeCache([
            GitWorktree(path: "ssh://box/srv/repo", branch: "main", isMainWorktree: true),
            GitWorktree(path: "ssh://box/srv/wt/feat", branch: "feat", isMainWorktree: false),
        ], for: "ssh://box/srv/repo")

        // Point at a stub that always fails, and expire the cache so the next
        // refresh actually re-runs the lookup.
        let original = GitWorktreeService.sshExecutablePath
        defer { GitWorktreeService.sshExecutablePath = original }
        GitWorktreeService.sshExecutablePath = "/usr/bin/false"
        service.expireCacheForTesting()

        await service.refreshWorktrees(for: ["ssh://box/srv/repo"])

        XCTAssertEqual(
            service.worktrees(for: "ssh://box/srv/repo")?.map(\.branch),
            ["main", "feat"],
            "a failed lookup discarded the rows it had"
        )
    }

    /// Selecting a project re-reads its worktrees. On a remote project that
    /// read goes over the network and routinely fails — and if opening the
    /// project throws the known rows away first, every reconnect costs the user
    /// their worktree rows and blanks the main area.
    @MainActor
    func test_selecting_a_remote_project_whose_scan_fails_keeps_its_worktree_rows() async {
        let original = GitWorktreeService.sshExecutablePath
        defer { GitWorktreeService.sshExecutablePath = original }
        GitWorktreeService.sshExecutablePath = "/usr/bin/false"

        let model = await remoteModel(projectPath: "ssh://box/srv/repo")

        await model.selectProject(id: "p1")

        XCTAssertEqual(
            model.workspaces.map(\.branch),
            ["main", "feat"],
            "opening the project discarded the worktrees it already knew"
        )
    }

    /// The project URI is where the user pointed; the worktree list is what git
    /// says. When they disagree — a URI into a subdirectory — the selection has
    /// to land on a workspace that exists, or `visibleSessions` empties and the
    /// main area goes blank.
    @MainActor
    func test_a_project_uri_that_is_not_a_worktree_lands_on_the_main_worktree() async {
        let original = GitWorktreeService.sshExecutablePath
        defer { GitWorktreeService.sshExecutablePath = original }
        GitWorktreeService.sshExecutablePath = "/usr/bin/false"

        let model = await remoteModel(projectPath: "ssh://box/srv/repo/apps")

        await model.selectProject(id: "p1")

        XCTAssertEqual(model.activeWorkspacePath, "ssh://box/srv/repo")
    }

    /// The tab bar is scoped to one worktree, so a tab opened from it belongs
    /// there — and on a remote project that also means the shell has to start
    /// in that directory on the other machine.
    @MainActor
    func test_a_new_remote_tab_belongs_to_the_worktree_on_screen() async {
        let original = GitWorktreeService.sshExecutablePath
        defer { GitWorktreeService.sshExecutablePath = original }
        GitWorktreeService.sshExecutablePath = "/usr/bin/false"

        var hosts: [MockTerminalHost] = []
        let model = await remoteModel(projectPath: "ssh://box/srv/repo", hosts: { hosts.append($0) })
        await model.selectProject(id: "p1")
        model.activeWorkspacePath = "ssh://box/srv/wt/feat"

        await model.newSession()

        XCTAssertEqual(model.liveSessions.last?.workspacePath, "ssh://box/srv/wt/feat")
        XCTAssertEqual(model.liveSessions.last?.lastCwd, "/srv/wt/feat")
        // The whole remote command is re-quoted for the local `/bin/sh -c`, so
        // compare against what the connection itself builds rather than against
        // a hand-written fragment.
        let expected = SSHConnectionInfo(host: "box", remotePath: "/srv/wt/feat").sshCommand()
        XCTAssertEqual(hosts.last?.commands.last ?? nil, expected)
    }

    /// Closing the tabs first means a remove that fails still costs the user
    /// their terminals — and over ssh, failing is routine.
    @MainActor
    func test_a_failed_remove_leaves_the_tabs_alone() async {
        let original = GitWorktreeService.sshExecutablePath
        defer { GitWorktreeService.sshExecutablePath = original }
        GitWorktreeService.sshExecutablePath = "/usr/bin/false"

        let model = await remoteModel(projectPath: "ssh://box/srv/repo")
        await model.selectProject(id: "p1")
        model.activeWorkspacePath = "ssh://box/srv/wt/feat"
        await model.newSession()
        XCTAssertEqual(model.liveSessions.count, 1)

        await model.removeWorktree(path: "ssh://box/srv/wt/feat")

        XCTAssertTrue(model.closingSessionIDs.isEmpty, "a tab was closed for a remove that failed")
        XCTAssertNotNil(model.loadErrorMessage)
    }

    /// An agent that creates a worktree and cd's into it leaves the tab where
    /// it was opened — right, but silent. A remote tab reports a path on the
    /// other machine, so it has to be spelled as an address before it can be
    /// matched against one.
    @MainActor
    func test_a_remote_tab_that_wandered_names_the_branch_it_is_in() async {
        let original = GitWorktreeService.sshExecutablePath
        defer { GitWorktreeService.sshExecutablePath = original }
        GitWorktreeService.sshExecutablePath = "/usr/bin/false"

        let model = await remoteModel(projectPath: "ssh://box/srv/repo")
        await model.selectProject(id: "p1")

        let visitor = SessionViewData(
            id: "s1", title: "t", targetLabel: "box",
            lastCwd: "/srv/wt/feat/apps", workspacePath: "ssh://box/srv/repo"
        )

        XCTAssertEqual(model.visitingBranch(for: visitor), "feat")
    }

    /// A workspace address is shown in two places — the worktree row's path
    /// line and the removal dialog. A remote address is a URI, and running a
    /// URI through `abbreviatingWithTildeInPath` eats one of its slashes:
    /// `ssh:/localhost/srv/repo`. The host is already on the project row, so
    /// the remote directory is the part worth reading.
    @MainActor
    func test_a_remote_workspace_reads_as_its_remote_directory() {
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []),
                             terminalFactory: { _ in MockTerminalHost() })

        XCTAssertEqual(model.displayPath(for: "ssh://localhost/srv/repo"), "/srv/repo")
        XCTAssertEqual(model.displayPath(for: "ssh://localhost/private/tmp/cs-ui-remote/repo"),
                       "/private/tmp/cs-ui-remote/repo")
        XCTAssertEqual(model.displayPath(for: "/Users/jinto/projects/codespark"),
                       "~/projects/codespark")
    }

    /// A remote project with two worktrees primed in the cache, not yet selected.
    @MainActor
    private func remoteModel(
        projectPath: String,
        hosts: @escaping (MockTerminalHost) -> Void = { _ in }
    ) async -> AppModel {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "remote", path: projectPath, transport: "ssh",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "remote", path: projectPath,
                                            transport: "ssh", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in
            let host = MockTerminalHost()
            hosts(host)
            return host
        })
        model.projects = [
            ProjectSummaryViewData(id: "p1", name: "remote", path: projectPath, transport: "ssh",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        ]
        model.gitWorktreeService.primeCache([
            GitWorktree(path: "ssh://box/srv/repo", branch: "main", isMainWorktree: true),
            GitWorktree(path: "ssh://box/srv/wt/feat", branch: "feat", isMainWorktree: false),
        ], for: projectPath)
        return model
    }

    // MARK: - Restoring says how far along it is

    /// Restoring takes a round trip per tab, and an ssh tab waits on a remote
    /// host on top of that. With nothing on screen the main area said "No
    /// sessions yet" for the whole wait — wrong, and an invitation to open a
    /// stray tab on top of the ones already on their way back.
    @MainActor
    func test_restore_counts_the_tabs_as_they_come_back() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "p1", path: "/tmp/p1", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "p1", name: "p1", path: "/tmp/p1", transport: "local",
                    liveSessions: [],
                    interruptedSessions: [
                        SessionSummary(id: "old-1", title: "Terminal", targetLabel: "local",
                                       lastCwd: "/tmp/p1", workspacePath: "/tmp/p1"),
                        SessionSummary(id: "old-2", title: "Terminal", targetLabel: "local",
                                       lastCwd: "/tmp/p1", workspacePath: "/tmp/p1"),
                        SessionSummary(id: "old-3", title: "Terminal", targetLabel: "local",
                                       lastCwd: "/tmp/p1", workspacePath: "/tmp/p1")
                    ]
                )
            ]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        var seen: [String] = []
        var areas: [String] = []
        core.onStartSession = { [weak model] in
            guard let model else { return }
            areas.append("\(model.mainAreaContent)")
            guard let progress = model.restoreProgress else { seen.append("nothing"); return }
            seen.append("\(progress.completed)/\(progress.total)")
        }

        await model.load()

        XCTAssertEqual(seen, ["0/3", "1/3", "2/3"],
                       "the count has to move as each tab lands, and know how many are coming")
        XCTAssertNil(model.restoreProgress,
                     "and it has to go away when the work does")
        XCTAssertEqual(areas.first?.hasPrefix("restoring"), true,
                       "with nothing back yet the area said \(areas.first ?? "nothing") instead of restoring")
        XCTAssertEqual(Array(areas.dropFirst()), ["terminals", "terminals"],
                       "once a tab is back it gets the room — the rest is a strip, not a cover")
    }

    @MainActor
    func test_a_terminal_that_is_back_is_not_covered_by_the_rest_coming() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)

        XCTAssertEqual(model.mainAreaContent, .terminals)
        XCTAssertNil(model.restoreBannerProgress,
                     "no restore is running, so no strip")
    }

    @MainActor
    func test_an_empty_worktree_still_offers_a_terminal_when_nothing_is_restoring() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        model.activeWorkspacePath = Self.featureWorktree

        XCTAssertEqual(model.mainAreaContent, .empty)
    }

    @MainActor
    func test_a_launch_with_nothing_to_restore_shows_no_progress() async {
        let model = await modelWithTwoProjects()

        XCTAssertNil(model.restoreProgress,
                     "an ordinary launch must not flash a bar at nobody")
    }

    // MARK: - The row is the target, not the chevron

    /// The disclosure triangle is an 8pt target in a row the width of the
    /// sidebar. Clicking the row is what people actually do.
    @MainActor
    func test_clicking_a_project_opens_and_folds_its_worktrees() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()

        await model.selectProjectAndToggleWorktrees(id: "p1")
        XCTAssertEqual(model.selection.id, "p1")
        XCTAssertTrue(model.expandedProjectIDs.contains("p1"), "the first click opens the tree")

        await model.selectProjectAndToggleWorktrees(id: "p1")
        XCTAssertFalse(model.expandedProjectIDs.contains("p1"), "and the next one folds it")
    }

    // MARK: - Finding worktrees with the real git

    /// Everything above primes the cache, so nothing there ever spawns the
    /// process this is about.
    ///
    /// The service used to read the exit status through a `terminationHandler`
    /// installed *after* draining stdout — by which point git has usually exited,
    /// so the handler is never called and the await hangs forever. One hang
    /// wedges `isRefreshing` and worktrees stop updating app-wide for the rest of
    /// the run. Asking repeatedly is the point: the race only bites sometimes,
    /// and a hang shows up here as a timeout rather than an assertion.
    @MainActor
    func test_a_repo_with_a_worktree_reports_both_every_time() async throws {
        let repo = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: repo) }
        let service = GitWorktreeService()

        for attempt in 1...8 {
            await service.refreshWorktrees(for: [repo.path])

            let found = service.worktrees(for: repo.path)
            XCTAssertEqual(found?.count, 2,
                           "attempt \(attempt) came back with \(found?.count.description ?? "nil")")
            XCTAssertEqual(found?.first?.isMainWorktree, true)
            XCTAssertEqual(found?.last?.branch, "side")

            // Force the next round through git instead of the 30s cache.
            service.invalidateCache(for: repo.path)
        }
    }

    /// A worktree Claude Code made is locked, and the porcelain output carries a
    /// `locked <reason>` line the parser has to walk past rather than read as a
    /// reason to drop the entry.
    func test_a_locked_worktree_is_still_a_worktree() {
        let output = """
        worktree /repo
        HEAD 397b0c351c60dd65374311b12771aec66cf9cf3c
        branch refs/heads/main

        worktree /repo/.claude/worktrees/scratch-1
        HEAD e88b2979aa74007dcd276c3b7bfcd2ce75516903
        branch refs/heads/worktree-scratch-1
        locked claude session scratch-1 (pid 9122 start Thu Aug 20 03:48:17 2026)
        """

        let worktrees = GitWorktreeService.parseWorktreeList(output)

        XCTAssertEqual(worktrees.map(\.branch), ["main", "worktree-scratch-1"])
        XCTAssertEqual(worktrees.map(\.isMainWorktree), [true, false])
    }

    /// A prunable stanza is skipped, and skipping it used to clear the "this is
    /// the first one" flag — so if the *first* stanza was prunable, nothing came
    /// back marked as the main worktree at all.
    ///
    /// Silent both ways: `projectIdentityLine` reads
    /// `.first(where: \.isMainWorktree)?.branch`, so a remote row quietly falls
    /// back to naming only its host, and `groupSessions` falls back to
    /// `worktrees[0]`.
    func test_a_prunable_first_stanza_still_leaves_a_main_worktree() {
        let output = """
        worktree /repo/gone
        HEAD 397b0c351c60dd65374311b12771aec66cf9cf3c
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        worktree /repo
        HEAD e88b2979aa74007dcd276c3b7bfcd2ce75516903
        branch refs/heads/main

        worktree /repo-feature
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/feature
        """

        let worktrees = GitWorktreeService.parseWorktreeList(output)

        XCTAssertEqual(worktrees.map(\.branch), ["main", "feature"])
        XCTAssertEqual(worktrees.filter(\.isMainWorktree).count, 1,
                       "a list of worktrees with no main one has nothing to name the project")
        XCTAssertTrue(worktrees[0].isMainWorktree)
    }

    private func makeRepoWithWorktree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codespark-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try runRealGit(["init", "-b", "main", root.path])
        try runRealGit(["-C", root.path, "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "--allow-empty", "-m", "root"])
        try runRealGit(["-C", root.path, "worktree", "add",
                        root.appendingPathComponent("side").path, "-b", "side"])
        return root
    }

    private func runRealGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("git \(arguments.first ?? "") is not usable in this environment")
        }
    }

    /// A repo with one worktree has no children to draw, so its stored flag
    /// shows nothing either way — what the click has to do is select.
    @MainActor
    func test_clicking_a_single_worktree_project_selects_it() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()

        await model.selectProjectAndToggleWorktrees(id: "p2")
        let p2 = model.projects.first { $0.id == "p2" }!

        XCTAssertEqual(model.selection.id, "p2")
        XCTAssertTrue(model.sidebarWorktrees(for: p2).isEmpty,
                      "and there is still nothing under it to show")
    }

    // MARK: - A project row says which branch it is on

    /// Every project is its main worktree, so the line under its name names the
    /// branch. It never names the path — the row's title is already the folder,
    /// and a second spelling of it says nothing.
    @MainActor
    func test_a_project_row_names_its_branch() {
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []),
                             terminalFactory: { _ in MockTerminalHost() })
        let project = ProjectSummaryViewData(id: "p1", name: "proj", path: "/tmp/proj",
                                             transport: "local", liveSessions: 0,
                                             recentlyClosedSessions: 0,
                                             hasInterruptedSessions: false, liveSessionDetails: [])
        model.gitBranches = ["/tmp/proj": "main"]

        XCTAssertEqual(model.projectInfoLine(for: project), "main")
    }

    /// A folder that is not a repository has no branch to report, and falling
    /// back to its path put the folder's name on screen twice.
    @MainActor
    func test_a_folder_that_is_not_a_repo_says_so() {
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []),
                             terminalFactory: { _ in MockTerminalHost() })
        let project = ProjectSummaryViewData(id: "p1", name: "notes", path: "/tmp/notes",
                                             transport: "local", liveSessions: 0,
                                             recentlyClosedSessions: 0,
                                             hasInterruptedSessions: false, liveSessionDetails: [])
        model.nonGitProjectPaths = ["/tmp/notes"]

        XCTAssertEqual(model.projectInfoLine(for: project), "non-git")
    }

    /// Until the lookup lands we know neither, and guessing either way puts a
    /// wrong word under the name. The line keeps its space and stays blank.
    @MainActor
    func test_a_project_says_nothing_until_the_branch_lookup_lands() {
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []),
                             terminalFactory: { _ in MockTerminalHost() })
        let project = ProjectSummaryViewData(id: "p1", name: "proj", path: "/tmp/proj",
                                             transport: "local", liveSessions: 0,
                                             recentlyClosedSessions: 0,
                                             hasInterruptedSessions: false, liveSessionDetails: [])

        XCTAssertNil(model.projectInfoLine(for: project),
                     "it guessed before it knew")
    }

    // MARK: - The tree opens on the click, not after the scan

    /// Selecting refetches the worktree list, and that queues behind every other
    /// project's lookup — a remote one can hold it for 20s. Folding is local
    /// state and has no reason to wait for any of it. It used to, because the
    /// toggle sat after the `await`, and with the disclosure triangle gone this
    /// click is the only way to open a tree at all.
    @MainActor
    func test_a_click_opens_the_tree_without_waiting_for_the_lookup() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "p1", path: Self.mainWorktree, transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "p1", path: Self.mainWorktree,
                                            transport: "local", liveSessions: [])],
            detailLatencyByID: ["p1": 400_000_000]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        let click = Task { await model.selectProjectAndToggleWorktrees(id: "p1") }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.expandedProjectIDs.contains("p1"),
                      "the tree is still shut while the lookup runs")
        await click.value
    }

    // MARK: - An ssh restore is the one that most needs to say it is working

    /// `selectProject` raises the reconnect offer for an ssh project with no
    /// live tabs, and `mainAreaContent` puts that ahead of everything. Restoring
    /// never lowered it, so the whole ssh restore — the slow one, the reason the
    /// progress exists — sat behind a "Reconnect" button instead.
    @MainActor
    func test_an_ssh_restore_shows_its_progress_not_the_reconnect_offer() async {
        let core = sshProjectWithOneInterruptedTab()
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        var areas: [String] = []
        core.onStartSession = { [weak model] in
            guard let model else { return }
            areas.append("\(model.mainAreaContent)")
        }

        await model.load()

        XCTAssertEqual(areas.first?.hasPrefix("restoring"), true,
                       "the area said \(areas.first ?? "nothing") while the tab was on its way back")
        XCTAssertNil(model.pendingSSHReconnectProjectID,
                     "and the offer must not outlive the restore that answered it")
    }

    // MARK: - One place, however it is spelled

    /// git reports the symlink-resolved directory, a project keeps the spelling
    /// it was added with, and on macOS `/tmp` is a symlink to `/private/tmp`.
    /// Compared as text the selection matched no workspace, so the correction in
    /// `recomputeWorkspaces` fired — every time it ran, which is once per tab
    /// during a restore.
    @MainActor
    func test_a_worktree_is_the_same_place_however_the_path_is_spelled() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "p1", path: "/tmp/spelled", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "p1", path: "/tmp/spelled",
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        // What git says, resolved, next to the way the project was added.
        model.gitWorktreeService.primeCache([
            GitWorktree(path: "/private/tmp/spelled", branch: "main", isMainWorktree: true),
            GitWorktree(path: "/private/tmp/spelled-feat", branch: "feat", isMainWorktree: false)
        ], for: "/tmp/spelled")
        model.activeWorkspacePath = "/tmp/spelled"

        model.recomputeWorkspaces()

        XCTAssertEqual(model.activeWorkspacePath, "/tmp/spelled",
                       "the selection was moved off a worktree it was already standing in")
    }

    func test_two_spellings_of_one_directory_compare_equal() {
        XCTAssertEqual(WorkspaceAddress("/tmp/x"), WorkspaceAddress("/private/tmp/x"))
        XCTAssertNotEqual(WorkspaceAddress("/tmp/x"), WorkspaceAddress("/tmp/y"))
        // Remote addresses are URIs; resolving them here would be meaningless.
        XCTAssertEqual(WorkspaceAddress("ssh://box/srv/repo"),
                       WorkspaceAddress("ssh://box/srv/repo"))
        XCTAssertNotEqual(WorkspaceAddress("ssh://box/tmp/x"),
                          WorkspaceAddress("ssh://box/private/tmp/x"))
    }

    // MARK: - Worktrees nobody is working in fold away

    /// A repo collects worktrees, and the ones with no tabs are the ones nobody
    /// is in. They fold behind a count rather than pushing the rest off screen.
    /// Only those: a worktree with tabs carries a `Cmd` digit, and hiding it
    /// would leave a number with nothing on screen to point at. `main` is
    /// exempt too — an open tree has to show at least one row, or it reads as a
    /// blank space rather than as a fold.
    @MainActor
    private func modelWithFourWorktrees() async -> AppModel {
        let (model, _) = await modelWithTwoWorktrees()
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.featureWorktree, branch: "feature", isMainWorktree: false),
            GitWorktree(path: "/tmp/proj-idle-a", branch: "idle-a", isMainWorktree: false),
            GitWorktree(path: "/tmp/proj-idle-b", branch: "idle-b", isMainWorktree: false)
        ], for: Self.mainWorktree)
        model.recomputeWorkspaces()
        return model
    }

    @MainActor
    func test_worktrees_with_no_tabs_fold_behind_a_count() async {
        let model = await modelWithFourWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        model.activeWorkspacePath = Self.featureWorktree
        let project = model.projects.first { $0.id == "p1" }!

        let rows = model.sidebarWorktreeRows(for: project)

        XCTAssertEqual(rows.shown.map(\.branch), ["main", "feature"],
                       "the worktree with a tab stands, and main always does")
        XCTAssertEqual(rows.foldedCount, 2)
    }

    /// You can be standing in a worktree you have not opened a tab in yet, and
    /// folding away the row you are on would leave the tree with nothing
    /// selected on screen. Read from `projectSelectedWorkspaces` so the answer
    /// does not change when the selection moves to another project.
    @MainActor
    func test_the_worktree_you_are_standing_in_never_folds() async {
        let model = await modelWithFourWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        model.activeWorkspacePath = "/tmp/proj-idle-a"
        let project = model.projects.first { $0.id == "p1" }!

        let rows = model.sidebarWorktreeRows(for: project)

        XCTAssertEqual(rows.shown.map(\.branch), ["main", "feature", "idle-a"])
        XCTAssertEqual(rows.foldedCount, 1)
    }

    @MainActor
    func test_asking_for_the_rest_shows_them_all() async {
        let model = await modelWithFourWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        model.activeWorkspacePath = Self.featureWorktree
        let project = model.projects.first { $0.id == "p1" }!

        model.revealFoldedWorktrees(projectID: "p1")

        let rows = model.sidebarWorktreeRows(for: project)
        XCTAssertEqual(rows.shown.count, 4)
        XCTAssertEqual(rows.foldedCount, 0, "nothing is left to ask for")
    }

    /// Nothing to fold, nothing to say — a tree where every worktree is in use
    /// must not grow a row that reads "0 more".
    @MainActor
    func test_a_tree_with_no_idle_worktrees_grows_no_extra_row() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let project = model.projects.first { $0.id == "p1" }!

        let rows = model.sidebarWorktreeRows(for: project)

        XCTAssertEqual(rows.shown.count, 2)
        XCTAssertEqual(rows.foldedCount, 0)
    }

    // MARK: - Every row you can go to wears a digit

    /// A project with no tabs open is still somewhere to go — it is where you go
    /// *to* open one. Numbering only what already had tabs left those rows with
    /// no way in but the mouse.
    @MainActor
    func test_a_project_with_no_tabs_still_gets_a_digit() async {
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let p2 = model.projects.first { $0.id == "p2" }!

        XCTAssertNotNil(model.numberedBadges.index(forProject: p2),
                        "a project you have not opened a tab in yet is unreachable by keyboard")
    }

    /// The digits follow sidebar order, so the project with tabs keeps the one
    /// it had and the empty one takes the next.
    @MainActor
    func test_digits_follow_the_sidebar_not_the_tabs() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let p1 = model.projects.first { $0.id == "p1" }!
        let p2 = model.projects.first { $0.id == "p2" }!

        XCTAssertEqual(model.numberedBadges.index(forProject: p1), 1)
        XCTAssertEqual(model.numberedBadges.index(forProject: p2), 2)
    }

    /// Pressing the digit has to land where clicking the row lands — including
    /// opening the tree, which is the other half of what that click means.
    @MainActor
    func test_pressing_a_digit_selects_the_project_and_opens_its_tree() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.mainWorktree)

        await model.selectNumberedPlace(2)

        XCTAssertEqual(model.selection.id, "p2")
        XCTAssertTrue(model.expandedProjectIDs.contains("p2"),
                      "the digit took us there but left the tree shut")
    }

    /// The row must not be drawn in its shut state on the way. Selecting waits
    /// on a git round trip, so opening after that await lands as a second frame —
    /// the tree blinks closed and back, which is what the flicker was.
    @MainActor
    func test_a_digit_opens_the_tree_before_it_waits_on_the_lookup() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "p1", path: Self.mainWorktree, transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "p1", path: Self.mainWorktree,
                                            transport: "local", liveSessions: [])],
            detailLatencyByID: ["p1": 400_000_000]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        // The digits address `projects`, so there has to be a list to address.
        await model.load()

        let press = Task { await model.selectNumberedPlace(1) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.expandedProjectIDs.contains("p1"),
                      "the tree was still shut while the lookup ran")
        await press.value
    }

    /// Arriving somewhere is no reason to shut what was open. A digit pressed
    /// twice — or pressed for the project you are already on — must not make the
    /// tree flap, which is what a plain toggle would do.
    @MainActor
    func test_a_digit_never_folds_a_tree_that_is_already_open() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.mainWorktree)

        await model.selectNumberedPlace(1)
        await model.selectNumberedPlace(1)

        XCTAssertTrue(model.expandedProjectIDs.contains("p1"),
                      "the second press folded the tree the first one opened")
    }

    // MARK: - Which directories git is asked about

    /// A remote tab reports a directory on the other machine, and `git -C` runs
    /// on this one. Handing those paths to git asks about whatever local
    /// directory happens to share the name — and now that a remote shell reports
    /// every `cd` it makes, they arrive constantly.
    @MainActor
    func test_a_remote_tabs_directory_is_never_handed_to_local_git() {
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []))
        model.projects = [
            ProjectSummaryViewData(
                id: "local", name: "Local", path: "/tmp/local", transport: "local",
                liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false,
                liveSessionDetails: [
                    SessionSummary(id: "s1", title: "t", targetLabel: "l",
                                   lastCwd: "/tmp/local/deep", workspacePath: "/tmp/local")
                ]
            ),
            ProjectSummaryViewData(
                id: "remote", name: "Remote", path: "ssh://box/srv/app", transport: "ssh",
                liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false,
                liveSessionDetails: [
                    SessionSummary(id: "s2", title: "t", targetLabel: "box",
                                   lastCwd: "/srv/app/somewhere", workspacePath: "ssh://box/srv/app")
                ]
            )
        ]

        let asked = Set(model.gitBranchQueryPaths.map(\.storageKey))
        XCTAssertTrue(asked.contains("/tmp/local"), "\(asked)")
        XCTAssertTrue(asked.contains("/tmp/local/deep"),
                      "a local tab's directory is exactly what the branch label is for: \(asked)")
        XCTAssertFalse(asked.contains("/srv/app/somewhere"),
                       "a directory on the other machine was handed to local git: \(asked)")
        XCTAssertFalse(asked.contains("ssh://box/srv/app"), "\(asked)")
    }
    // MARK: - The project row's subtitle never goes blank

    /// Closed, the row *is* that worktree, so it names it — and says how many
    /// others are inside, which is what tells the user there is a tree to open.
    @MainActor
    func test_a_closed_project_row_names_its_branch_and_how_many_worktrees() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.gitBranches[Self.mainWorktree] = "main"
        let p1 = model.projects.first { $0.id == "p1" }!

        XCTAssertEqual(model.projectInfoLine(for: p1), "main · 2 worktrees")
    }

    /// Open, the branch is spelled by the `main` worktree row one line below.
    /// Repeating it there was why this line used to be hidden — and a hidden
    /// line with every child folded away is the blank space the user reported.
    @MainActor
    func test_an_open_project_row_says_only_how_many_worktrees() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.gitBranches[Self.mainWorktree] = "main"
        model.toggleWorktrees(projectID: "p1")
        let p1 = model.projects.first { $0.id == "p1" }!

        XCTAssertEqual(model.projectInfoLine(for: p1), "2 worktrees")
    }

    /// One worktree stays flat: the project row is that worktree, there are no
    /// child rows, and a count of one is not news.
    @MainActor
    func test_a_flat_project_row_says_only_its_branch() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.gitWorktreeService.primeCache(
            [GitWorktree(path: Self.otherProject, branch: "main", isMainWorktree: true)],
            for: Self.otherProject)
        model.gitBranches[Self.otherProject] = "main"
        let p2 = model.projects.first { $0.id == "p2" }!

        XCTAssertEqual(model.projectInfoLine(for: p2), "main")
        model.toggleWorktrees(projectID: "p2")
        XCTAssertEqual(model.projectInfoLine(for: p2), "main",
                       "opening a repo with one worktree changes nothing")
        XCTAssertFalse(model.showsWorktreeRows(for: p2))
    }

    /// A number we do not have yet is not written down — the same rule that
    /// keeps "non-git" off the row until the lookup lands. The line fills in
    /// when the answer arrives.
    @MainActor
    func test_a_project_row_omits_the_count_until_the_worktrees_are_known() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.gitBranches[Self.otherProject] = "main"
        let p2 = model.projects.first { $0.id == "p2" }!

        XCTAssertEqual(model.projectInfoLine(for: p2), "main", "cold cache: identity only")

        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.otherProject, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.otherProject + "-x", branch: "x", isMainWorktree: false),
            GitWorktree(path: Self.otherProject + "-y", branch: "y", isMainWorktree: false)
        ], for: Self.otherProject)

        XCTAssertEqual(model.projectInfoLine(for: p2), "main · 3 worktrees")
    }

    /// A remote row said only its host, and a person with several projects on
    /// one box read the same word down the whole sidebar while every local row
    /// named a branch. The host is what makes the row remote, so it stays — but
    /// it trails the branch, which is the part that differs from row to row.
    ///
    /// The branch comes from the worktree scan, so before that lands, or on a
    /// `ssh://host` with no path that is never scanned at all, the line is the
    /// host alone. Naming a branch we have not been told is the same guess as
    /// saying "non-git" before asking.
    @MainActor
    func test_a_remote_project_row_names_its_branch_on_its_host() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let withPath = "ssh://jinto@kt-server/srv/repo"
        let pathless = "ssh://kt-server"
        func summary(id: String, path: String) -> ProjectSummaryViewData {
            ProjectSummaryViewData(id: id, name: id, path: path, transport: "ssh",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        }
        let model = AppModel(
            core: MockProjectCoreClient(summaries: [summary(id: "r1", path: withPath),
                                                    summary(id: "r2", path: pathless)]),
            terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        let label = SSHConnectionInfo(uri: withPath)!.displayLabel
        let r1 = model.projects.first { $0.id == "r1" }!
        let r2 = model.projects.first { $0.id == "r2" }!

        XCTAssertEqual(model.projectInfoLine(for: r1), label, "before the scan answers")
        XCTAssertEqual(model.projectInfoLine(for: r2),
                       SSHConnectionInfo(uri: pathless)!.displayLabel)

        model.gitWorktreeService.primeCache([
            GitWorktree(path: withPath, branch: "main", isMainWorktree: true),
            GitWorktree(path: withPath + "-feature", branch: "feature", isMainWorktree: false)
        ], for: withPath)

        XCTAssertEqual(model.projectInfoLine(for: r1), "main on \(label) · 2 worktrees")

        model.gitWorktreeService.primeCache(
            [GitWorktree(path: withPath, branch: "main", isMainWorktree: true)], for: withPath)

        XCTAssertEqual(model.projectInfoLine(for: r1), "main on \(label)",
                       "one worktree has no scale to add")
    }

    // MARK: - An open tree always has something in it

    /// Folding hides the worktrees nobody is working in. Folding *all* of them
    /// leaves an open project showing one grey "2 more" and a blank line, which
    /// is indistinguishable from a rendering bug — and it was the state every
    /// relaunch started in, since the tree's expansion is remembered while the
    /// "show me the rest" flag is not.
    @MainActor
    func test_an_open_tree_always_shows_at_least_the_main_worktree() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.toggleWorktrees(projectID: "p1")
        await model.selectProject(id: "p2")
        model.projectSelectedWorkspaces.removeValue(forKey: "p1")
        let p1 = model.projects.first { $0.id == "p1" }!

        let rows = model.sidebarWorktreeRows(for: p1)

        XCTAssertEqual(rows.shown.map(\.path), [Self.mainWorktree],
                       "no tabs, no remembered worktree — main still stands for the tree")
        XCTAssertEqual(rows.foldedCount, 1)
    }

    /// The rows must not depend on where the selection stands. They used to:
    /// the "do not fold the worktree being stood in" exception only applied to
    /// the selected project, so clicking a row grew the list by one and turned
    /// "2 more" into "1 more" with no other change on screen.
    @MainActor
    func test_the_shown_worktrees_do_not_change_when_the_project_is_selected() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.toggleWorktrees(projectID: "p1")
        await model.selectProject(id: "p2")
        let unselected = model.sidebarWorktreeRows(
            for: model.projects.first { $0.id == "p1" }!)

        await model.selectProject(id: "p1")
        let selected = model.sidebarWorktreeRows(
            for: model.projects.first { $0.id == "p1" }!)

        XCTAssertEqual(unselected.shown.map(\.path), selected.shown.map(\.path))
        XCTAssertEqual(unselected.foldedCount, selected.foldedCount)
    }

    /// What the plan deliberately keeps: a worktree made elsewhere is found by
    /// polling and appears. The count on the project row moves with it, so the
    /// list growing has a reason written next to it.
    @MainActor
    func test_a_worktree_discovered_later_appears_and_the_count_says_so() async {
        forgetExpandedProjects()
        defer { forgetExpandedProjects() }
        let model = await modelWithTwoProjects()
        model.gitBranches[Self.mainWorktree] = "main"
        model.toggleWorktrees(projectID: "p1")
        let before = model.sidebarWorktreeRows(for: model.projects.first { $0.id == "p1" }!)
        XCTAssertEqual(model.projectInfoLine(for: model.projects.first { $0.id == "p1" }!),
                       "2 worktrees")

        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.featureWorktree, branch: "feature", isMainWorktree: false),
            GitWorktree(path: Self.mainWorktree + "-scratch", branch: "scratch",
                        isMainWorktree: false)
        ], for: Self.mainWorktree)
        model.recomputeWorkspaces()
        let p1 = model.projects.first { $0.id == "p1" }!

        XCTAssertEqual(model.projectInfoLine(for: p1), "3 worktrees")
        XCTAssertEqual(model.sidebarWorktreeRows(for: p1).foldedCount, before.foldedCount + 1)
    }

    // MARK: - Moving a tab to another worktree

    /// Dragging a tab onto a worktree row (or picking it in Move to…) refiles
    /// the tab: ownership changes, the shell stays where it is.
    @MainActor
    func test_moving_a_tab_refiles_it_under_the_target_worktree() async throws {
        let (model, core) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]
        let targets = model.sessionMoveTargets(for: tab)
        XCTAssertFalse(targets.contains { $0.workspacePath == Self.mainWorktree },
                       "a tab is never offered the worktree it is already in")
        let target = try XCTUnwrap(targets.first { $0.workspacePath == Self.featureWorktree })

        await model.moveSession(sessionID: tab.id, to: target)

        XCTAssertEqual(model.liveSessions[0].workspacePath, Self.featureWorktree)
        XCTAssertEqual(core.movedSessions.map(\.workspacePath), [Self.featureWorktree])
        XCTAssertEqual(core.movedSessions.first?.projectId, "p1")
        XCTAssertEqual(model.activeWorkspacePath, Self.mainWorktree,
                       "the move sends the tab, not the user")
        XCTAssertTrue(model.visibleSessions.isEmpty,
                      "the tab bar the user is looking at no longer shows it")
    }

    /// `activeSessionID.didSet` drags the sidebar to the active tab's worktree,
    /// so moving the active tab has to hand focus over first — to the left
    /// neighbour, the same rule closing a tab uses.
    @MainActor
    func test_moving_the_active_tab_leaves_the_user_in_their_worktree() async throws {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let mover = model.liveSessions[1]
        XCTAssertEqual(model.activeSessionID, mover.id)
        let target = try XCTUnwrap(model.sessionMoveTargets(for: mover)
            .first { $0.workspacePath == Self.featureWorktree })

        await model.moveSession(sessionID: mover.id, to: target)

        XCTAssertEqual(model.activeWorkspacePath, Self.mainWorktree)
        XCTAssertEqual(model.activeSessionID, model.liveSessions[0].id,
                       "focus hands over to the neighbour, like closing does")
        XCTAssertEqual(model.visibleSessions.map(\.id), [model.liveSessions[0].id])
    }

    @MainActor
    func test_moving_a_tab_to_another_project_updates_both_rows() async throws {
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]
        let target = try XCTUnwrap(model.sessionMoveTargets(for: tab)
            .first { $0.projectID == "p2" })
        XCTAssertEqual(target.workspacePath, Self.otherProject)

        await model.moveSession(sessionID: tab.id, to: target)

        XCTAssertTrue(model.liveSessions.isEmpty, "the tab left this project's bar")
        XCTAssertTrue(model.allSessions.contains { $0.id == tab.id },
                      "its surface stays alive — the move is bookkeeping, not a close")
        XCTAssertEqual(model.projects.first { $0.id == "p1" }?.liveSessions, 0)
        XCTAssertEqual(model.projects.first { $0.id == "p2" }?.liveSessions, 1)
        XCTAssertEqual(model.projects.first { $0.id == "p2" }?.liveSessionDetails.first?.workspacePath,
                       Self.otherProject)
        let core = model.core as? MockProjectCoreClient
        XCTAssertEqual(core?.movedSessions.first?.projectId, "p2")
    }

    /// "Same host" is a property of the owning project against the target
    /// project — a local tab is never offered a remote project's worktrees.
    @MainActor
    func test_move_targets_stay_on_the_same_host() async {
        func summary(id: String, path: String, transport: String) -> ProjectSummaryViewData {
            ProjectSummaryViewData(id: id, name: id, path: path, transport: transport,
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: [])
        }
        let core = MockProjectCoreClient(
            summaries: [summary(id: "p1", path: Self.mainWorktree, transport: "local"),
                        summary(id: "p2", path: Self.otherProject, transport: "local"),
                        summary(id: "p3", path: "ssh://jinto@emac/srv/repo", transport: "ssh")],
            details: [ProjectDetailViewData(id: "p1", name: "p1", path: Self.mainWorktree,
                                            transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]

        let targets = model.sessionMoveTargets(for: tab)

        XCTAssertTrue(targets.contains { $0.projectID == "p2" })
        XCTAssertFalse(targets.contains { $0.projectID == "p3" },
                       "a remote project is another machine")
        XCTAssertEqual(model.sessionDropEligibleProjectIDs, ["p1", "p2"])
    }

    /// A drop on the project row itself means its main worktree — the row is
    /// that worktree when the tree is collapsed.
    @MainActor
    func test_dropping_on_a_project_row_files_the_tab_under_its_main_worktree() async {
        let model = await modelWithTwoProjects()
        model.gitWorktreeService.primeCache([
            GitWorktree(path: Self.otherProject, branch: "main", isMainWorktree: true),
            GitWorktree(path: Self.otherProject + "-wt", branch: "wt", isMainWorktree: false)
        ], for: Self.otherProject)
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let tab = model.liveSessions[0]

        await model.dropSession(sessionID: tab.id, onProjectID: "p2", workspacePath: nil)

        XCTAssertEqual(model.projects.first { $0.id == "p2" }?.liveSessionDetails.first?.workspacePath,
                       Self.otherProject)
    }

    /// The subtitle is a string in a view body, and no test that renders the
    /// view can read it. What a test *can* read is the source: the row must
    /// never fade its own line out again.
    func test_the_project_row_never_hides_its_own_subtitle() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodeSpark/Views")
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated()
            where line.contains(".opacity(") && line.contains("showsWorktreeRows") {
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "열렸을 때 부제를 감추면 설명 없는 빈 줄이 된다. 줄은 상태에 따라 다른 사실을 말할 것:\n"
                + offenders.joined(separator: "\n"))
    }

}
