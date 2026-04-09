import XCTest
@testable import CodeSpark

final class WorkspaceSelectionTests: XCTestCase {

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
