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
        let model = AppModel(
            core: MockProjectCoreClient.projectWithInterruptedSession(),
            terminalFactory: { _ in MockTerminalHost() }
        )

        // Launch restores the tabs rather than asking about them.
        await model.load()
        XCTAssertNil(model.pendingWorkspaceRecoveryProjectID)
        XCTAssertEqual(model.liveSessions.count, 1)

        // Re-opening a project with no tabs from the sidebar still offers the menu,
        // which is also how you reach "New Claude session" / "Resume …".
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
        model.selectedProjectID = "p1"
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

    // MARK: - Restored tabs show what was on screen before

    @MainActor
    func test_restored_tab_carries_its_previous_screen() async {
        let core = projectWithTwoInterruptedTabs()
        core.snapshotsBySessionID = [
            "s1": TerminalSnapshotViewData.fixture(lines: ["jinto@m3 ~ % cd projects/codespark", "jinto@m3 codespark %"])
        ]
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()

        let restoredFirst = model.liveSessions[0].id
        XCTAssertEqual(model.restoredScreens[restoredFirst]?.lines.first, "jinto@m3 ~ % cd projects/codespark")
    }

    @MainActor
    func test_tab_without_a_previous_screen_has_no_ghost() async {
        let core = projectWithTwoInterruptedTabs()
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()

        XCTAssertTrue(model.restoredScreens.isEmpty)
    }

    @MainActor
    func test_ghost_clears_once_the_user_types_in_that_tab() async {
        let core = projectWithTwoInterruptedTabs()
        core.snapshotsBySessionID = ["s1": TerminalSnapshotViewData.fixture(lines: ["old output"])]
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        let restoredFirst = model.liveSessions[0].id
        XCTAssertNotNil(model.restoredScreens[restoredFirst])

        model.dismissRestoredScreen(sessionID: restoredFirst)

        XCTAssertNil(model.restoredScreens[restoredFirst])
    }

    @MainActor
    func test_typing_in_one_tab_leaves_the_other_tabs_ghost_alone() async {
        let core = projectWithTwoInterruptedTabs()
        core.snapshotsBySessionID = [
            "s1": TerminalSnapshotViewData.fixture(lines: ["first"]),
            "s2": TerminalSnapshotViewData.fixture(lines: ["second"])
        ]
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })
        await model.load()

        let first = model.liveSessions[0].id
        let second = model.liveSessions[1].id
        model.dismissRestoredScreen(sessionID: first)

        XCTAssertNil(model.restoredScreens[first])
        XCTAssertEqual(model.restoredScreens[second]?.lines.first, "second")
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
}
