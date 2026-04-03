import XCTest
@testable import StatefulTerminal

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
}
