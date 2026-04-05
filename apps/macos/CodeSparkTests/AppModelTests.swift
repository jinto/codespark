import XCTest
@testable import CodeSpark

final class AppModelTests: XCTestCase {
    @MainActor
    func test_loads_workspace_summaries_and_the_selected_note() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-release", name: "release", liveSessions: 1, recentlyClosedSessions: 1, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-release",
                name: "release",
                noteBody: "check prod logs",
                liveSessions: [],
                closedSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()

        XCTAssertEqual(model.workspaces.map(\.name), ["release"])
        XCTAssertEqual(model.selectedWorkspace?.noteBody, "check prod logs")
        XCTAssertEqual(model.selectedWorkspaceID, "ws-release")
        XCTAssertNil(model.loadErrorMessage)
    }

    @MainActor
    func test_select_workspace_loads_requested_detail() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-release", name: "release", liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                WorkspaceSummaryViewData(id: "ws-spark3", name: "spark3", liveSessions: 0, recentlyClosedSessions: 1, hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [
                WorkspaceDetailViewData(
                    id: "ws-release",
                    name: "release",
                    noteBody: "check prod logs",
                    liveSessions: [],
                    closedSessions: []
                ),
                WorkspaceDetailViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    noteBody: "resume after crash",
                    liveSessions: [],
                    closedSessions: []
                )
            ]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.selectWorkspace(id: "ws-spark3")

        XCTAssertEqual(model.selectedWorkspace?.id, "ws-spark3")
        XCTAssertEqual(model.noteDraft, "resume after crash")
        XCTAssertEqual(model.selectedWorkspaceID, "ws-spark3")
        XCTAssertNil(model.loadErrorMessage)
    }

    @MainActor
    func test_latest_workspace_selection_wins_when_detail_requests_finish_out_of_order() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-release", name: "release", liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                WorkspaceSummaryViewData(id: "ws-spark3", name: "spark3", liveSessions: 0, recentlyClosedSessions: 1, hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [
                WorkspaceDetailViewData(
                    id: "ws-release",
                    name: "release",
                    noteBody: "check prod logs",
                    liveSessions: [],
                    closedSessions: []
                ),
                WorkspaceDetailViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    noteBody: "resume after crash",
                    liveSessions: [],
                    closedSessions: []
                )
            ],
            detailLatencyByID: ["ws-release": 200_000_000]
        )
        let model = AppModel(core: client)

        await model.load()

        let firstSelection = Task { await model.selectWorkspace(id: "ws-release") }
        let secondSelection = Task { await model.selectWorkspace(id: "ws-spark3") }
        await firstSelection.value
        await secondSelection.value

        XCTAssertEqual(model.selectedWorkspaceID, "ws-spark3")
        XCTAssertEqual(model.selectedWorkspace?.id, "ws-spark3")
        XCTAssertEqual(model.noteDraft, "resume after crash")
    }

    @MainActor
    func test_detail_fetch_failure_clears_stale_detail_state() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-release", name: "release", liveSessions: 1, recentlyClosedSessions: 1, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-release",
                name: "release",
                noteBody: "check prod logs",
                liveSessions: [],
                closedSessions: []
            )],
            detailErrorsByID: ["ws-release": CocoaError(.fileReadUnknown)]
        )
        let model = AppModel(core: client)
        model.selectedWorkspaceID = "stale-workspace"
        model.selectedWorkspace = WorkspaceDetailViewData(
            id: "stale-workspace",
            name: "stale",
            noteBody: "stale note",
            liveSessions: [],
            closedSessions: []
        )
        model.noteDraft = "stale note"
        model.liveSessions = [.fixture()]
        model.closedSessions = [
            ClosedSessionViewData(
                id: "stale-session",
                title: "stale shell",
                targetLabel: "local",
                lastCwd: "/tmp",
                closeReason: .appCrashed,
                snapshotPreview: .fixture(lines: ["stale"]),
                restoreRecipe: RestoreRecipeViewData(launchCommand: "zsh -l")
            )
        ]

        await model.load()

        XCTAssertEqual(model.workspaces.map(\.id), ["ws-release"])
        XCTAssertEqual(model.selectedWorkspaceID, "ws-release")
        XCTAssertNil(model.selectedWorkspace)
        XCTAssertEqual(model.noteDraft, "")
        XCTAssertEqual(model.liveSessions, [])
        XCTAssertEqual(model.closedSessions, [])
        XCTAssertNotNil(model.loadErrorMessage)
    }

    @MainActor
    func test_save_note_failure_surfaces_an_error() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-release", name: "release", liveSessions: 1, recentlyClosedSessions: 1, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-release",
                name: "release",
                noteBody: "check prod logs",
                liveSessions: [],
                closedSessions: []
            )],
            noteUpdateError: CocoaError(.fileWriteUnknown)
        )
        let model = AppModel(core: client)

        await model.load()
        model.noteDraft = "updated note"
        await model.saveNote()

        XCTAssertEqual(model.selectedWorkspace?.noteBody, "check prod logs")
        XCTAssertNotNil(model.noteSaveErrorMessage)
    }

    @MainActor
    func test_save_note_does_not_overwrite_when_workspace_switches_during_save() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-A", name: "Workspace A", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                WorkspaceSummaryViewData(id: "ws-B", name: "Workspace B", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [
                WorkspaceDetailViewData(
                    id: "ws-A",
                    name: "Workspace A",
                    noteBody: "original A note",
                    liveSessions: [],
                    closedSessions: []
                ),
                WorkspaceDetailViewData(
                    id: "ws-B",
                    name: "Workspace B",
                    noteBody: "original B note",
                    liveSessions: [],
                    closedSessions: []
                )
            ],
            noteUpdateLatency: 200_000_000
        )
        let model = AppModel(core: client)

        await model.load()
        XCTAssertEqual(model.selectedWorkspace?.id, "ws-A")

        model.noteDraft = "updated A note"
        let saveTask = Task { await model.saveNote() }
        await Task.yield()

        await model.selectWorkspace(id: "ws-B")
        XCTAssertEqual(model.selectedWorkspace?.id, "ws-B")
        XCTAssertEqual(model.noteDraft, "original B note")

        await saveTask.value

        XCTAssertEqual(model.selectedWorkspace?.id, "ws-B")
        XCTAssertEqual(model.selectedWorkspace?.noteBody, "original B note")
        XCTAssertEqual(model.noteDraft, "original B note")
        XCTAssertNil(model.noteSaveErrorMessage)
    }

    @MainActor
    func test_rename_workspace_updates_name_in_list() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-release", name: "release", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-release",
                name: "release",
                noteBody: "",
                liveSessions: [],
                closedSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.renameWorkspace(id: "ws-release", newName: "renamed-release")

        XCTAssertEqual(model.workspaces[0].name, "renamed-release")
    }

    @MainActor
    func test_create_workspace_inserts_below_active() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-1", name: "Workspace 1", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                WorkspaceSummaryViewData(id: "ws-2", name: "Workspace 2", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [
                WorkspaceDetailViewData(
                    id: "ws-1",
                    name: "Workspace 1",
                    noteBody: "",
                    liveSessions: [],
                    closedSessions: []
                ),
                WorkspaceDetailViewData(
                    id: "mock-workspace-id",
                    name: "Workspace 3",
                    noteBody: "",
                    liveSessions: [],
                    closedSessions: []
                )
            ]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.selectWorkspace(id: "ws-1")
        await model.createWorkspace(name: "Workspace 3")

        XCTAssertEqual(model.workspaces.map(\.id), ["ws-1", "mock-workspace-id", "ws-2"])
        XCTAssertEqual(model.workspaces[1].name, "Workspace 3")
    }

    @MainActor
    func test_delete_workspace_removes_from_list() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-1", name: "Workspace 1", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                WorkspaceSummaryViewData(id: "ws-2", name: "Workspace 2", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-1",
                name: "Workspace 1",
                noteBody: "",
                liveSessions: [],
                closedSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.deleteWorkspace(id: "ws-2")

        XCTAssertEqual(model.workspaces.count, 1)
    }

    @MainActor
    func test_close_workspace_hides_from_list() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-1", name: "Workspace 1", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                WorkspaceSummaryViewData(id: "ws-2", name: "Workspace 2", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-1",
                name: "Workspace 1",
                noteBody: "",
                liveSessions: [],
                closedSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.closeWorkspace(id: "ws-2")

        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertTrue(model.hiddenWorkspaceIDs.contains("ws-2"))
    }

    @MainActor
    func test_close_session_removes_from_live_sessions() async {
        let client = MockWorkspaceCoreClient.workspaceWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: client, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()
        model.closeSession(id: "session-prod")
        host.finishClose(
            sessionID: "session-prod",
            snapshot: .fixture(lines: ["tail -f log"]),
            closeReason: .userClosed
        )

        XCTAssertFalse(model.liveSessions.contains(where: { $0.id == "session-prod" }))
    }

    @MainActor
    func test_reopen_last_closed_session_creates_new_live_session() async {
        let client = MockWorkspaceCoreClient.workspaceWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: client, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()
        model.closeSession(id: "session-prod")
        host.finishClose(
            sessionID: "session-prod",
            snapshot: .fixture(lines: ["tail -f log"]),
            closeReason: .userClosed
        )

        let liveSessionCountBeforeReopen = model.liveSessions.count
        await model.reopenLastClosedSession()

        XCTAssertEqual(model.liveSessions.count, liveSessionCountBeforeReopen + 1)
    }

    @MainActor
    func test_pending_close_session_id_triggers_close_flow() async {
        let client = MockWorkspaceCoreClient.workspaceWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: client, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()
        model.pendingCloseSessionID = "session-prod"
        model.closeSession(id: "session-prod")
        host.finishClose(
            sessionID: "session-prod",
            snapshot: .fixture(lines: ["tail -f log"]),
            closeReason: .userClosed
        )

        XCTAssertFalse(model.liveSessions.contains(where: { $0.id == "session-prod" }))
    }

    @MainActor
    func test_pending_close_workspace_id_triggers_close_flow() async {
        let client = MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(id: "ws-1", name: "Workspace 1", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                WorkspaceSummaryViewData(id: "ws-2", name: "Workspace 2", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-1",
                name: "Workspace 1",
                noteBody: "",
                liveSessions: [],
                closedSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        model.pendingCloseWorkspaceID = "ws-2"
        await model.closeWorkspace(id: "ws-2")

        XCTAssertTrue(model.hiddenWorkspaceIDs.contains("ws-2"))
    }
}
