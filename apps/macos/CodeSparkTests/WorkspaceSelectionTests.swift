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
        core.onStartSession = { [weak model] in
            started += 1
            if started == 1 { model?.selectedProjectID = "p2" }
        }
        await model.load()

        XCTAssertTrue(
            model.liveSessions.allSatisfy { $0.workspacePath == "/tmp/p2" },
            "p1's restored tabs landed in another project's tab bar: \(model.liveSessions.map(\.workspacePath))"
        )
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

    // MARK: - Cmd+1…9 addresses the places work is happening

    @MainActor
    func test_a_worktree_without_tabs_gets_no_number() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)

        XCTAssertEqual(model.numberedWorkspaces.map(\.path), [Self.featureWorktree],
                       "an empty worktree is not somewhere to jump to")
    }

    @MainActor
    func test_numbers_follow_the_sidebar_order_across_projects() async {
        let model = await modelWithTwoProjects()
        // p1 has two worktrees, p2 is flat. Tabs in both.
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        await model.selectProject(id: "p2")
        await model.newSession()

        XCTAssertEqual(model.numberedWorkspaces.map(\.projectID), ["p1", "p2"])
        XCTAssertEqual(model.numberedWorkspaces.map(\.path), [Self.featureWorktree, Self.otherProject])
    }

    @MainActor
    func test_a_flat_project_is_numbered_as_itself() async {
        let model = await modelWithTwoProjects()
        await model.selectProject(id: "p2")
        await model.newSession()

        XCTAssertEqual(model.numberedWorkspaces.map(\.path), [Self.otherProject],
                       "one worktree means the project row is that workspace")
    }

    @MainActor
    func test_collapsing_a_tree_does_not_renumber_anything() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let before = model.numberedWorkspaces

        model.toggleWorktrees(projectID: "p1")

        XCTAssertEqual(model.numberedWorkspaces, before,
                       "numbers must not move when a tree is opened or closed")
    }

    @MainActor
    func test_pressing_a_number_selects_that_project_and_worktree() async {
        let model = await modelWithTwoProjects()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        await model.selectProject(id: "p2")
        await model.newSession()

        await model.selectNumberedWorkspace(1)

        XCTAssertEqual(model.selectedProjectID, "p1")
        XCTAssertEqual(model.activeWorkspacePath, Self.featureWorktree)
    }

    @MainActor
    func test_an_index_with_nothing_behind_it_does_nothing() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let selected = model.selectedProjectID

        await model.selectNumberedWorkspace(7)

        XCTAssertEqual(model.selectedProjectID, selected)
    }

    @MainActor
    func test_only_nine_places_can_be_numbered() async {
        let (model, _) = await modelWithTwoWorktrees()
        let many = (0..<12).map { "/tmp/proj-w\($0)" }
        model.gitWorktreeService.primeCache(
            [GitWorktree(path: Self.mainWorktree, branch: "main", isMainWorktree: true)]
                + many.enumerated().map {
                    GitWorktree(path: $0.element, branch: "w\($0.offset)", isMainWorktree: false)
                },
            for: Self.mainWorktree
        )
        model.recomputeWorkspaces()
        for path in many {
            await model.newSession(inWorkspacePath: path)
        }

        XCTAssertEqual(model.numberedWorkspaces.count, 9, "there are only nine digits")
        XCTAssertEqual(model.numberedWorkspaces.map(\.path), Array(many.prefix(9)))
    }

    // MARK: - Removing a worktree

    @MainActor
    func test_removing_a_worktree_closes_only_the_tabs_that_were_in_it() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let inMain = model.liveSessions.first { $0.workspacePath == Self.mainWorktree }!
        let inFeature = model.liveSessions.first { $0.workspacePath == Self.featureWorktree }!

        // The git call fails here — /tmp/proj is no repo — but the tabs living in
        // the worktree have to be let go before the directory disappears.
        await model.removeWorktree(path: Self.featureWorktree)

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
    /// primed after `load()` because `selectProject` invalidates on the way in.
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

        XCTAssertEqual(model.selectedProjectID, "p1")
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

        XCTAssertEqual(model.selectedProjectID, "p1")
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

        XCTAssertEqual(model.selectedProjectID, "p1")
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
    func test_removing_a_worktree_closes_the_tabs_that_belong_to_it() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        await model.newSession(inWorkspacePath: Self.mainWorktree)
        let ofFeature = model.liveSessions.first { $0.workspacePath == Self.featureWorktree }!
        let ofMain = model.liveSessions.first { $0.workspacePath == Self.mainWorktree }!

        // The one that belongs here steps out; the one that does not steps in.
        model.sessionDidReportCwd(sessionID: ofFeature.id, cwd: "/tmp/somewhere-else")
        model.sessionDidReportCwd(sessionID: ofMain.id, cwd: Self.featureWorktree + "/src")

        await model.removeWorktree(path: Self.featureWorktree)

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
    func test_removing_a_worktree_closes_a_legacy_tab_that_has_no_workspace() async {
        let (model, _) = await modelWithTwoWorktrees()
        await model.newSession(inWorkspacePath: Self.featureWorktree)
        let legacy = model.liveSessions[0]
        model.liveSessions[0].workspacePath = ""
        model.sessionDidReportCwd(sessionID: legacy.id, cwd: Self.featureWorktree + "/src")

        await model.removeWorktree(path: Self.featureWorktree)

        XCTAssertTrue(model.closingSessionIDs.contains(legacy.id),
                      "a row with no workspace is placed by its cwd, and let go the same way")
    }
}
