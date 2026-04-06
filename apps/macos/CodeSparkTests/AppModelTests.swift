import XCTest
@testable import CodeSpark

final class AppModelTests: XCTestCase {
    @MainActor
    func test_loads_project_summaries_and_selects_first() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "/tmp/release", transport: "local", liveSessions: 1, recentlyClosedSessions: 1, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-release",
                name: "release",
                path: "/tmp/release",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()

        XCTAssertEqual(model.projects.map(\.name), ["release"])
        XCTAssertEqual(model.selectedProjectID, "ws-release")
        XCTAssertNil(model.loadErrorMessage)
    }

    @MainActor
    func test_select_project_loads_requested_detail() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "", transport: "local", liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-spark3", name: "spark3", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 1, hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "ws-release",
                    name: "release",
                    path: "",
                    transport: "local",
                    liveSessions: []
                ),
                ProjectDetailViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    path: "",
                    transport: "local",
                    liveSessions: []
                )
            ]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.selectProject(id: "ws-spark3")

        XCTAssertEqual(model.selectedProject?.id, "ws-spark3")
        XCTAssertEqual(model.selectedProjectID, "ws-spark3")
        XCTAssertNil(model.loadErrorMessage)
    }

    @MainActor
    func test_latest_project_selection_wins_when_detail_requests_finish_out_of_order() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "", transport: "local", liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-spark3", name: "spark3", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 1, hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "ws-release",
                    name: "release",
                    path: "",
                    transport: "local",
                    liveSessions: []
                ),
                ProjectDetailViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    path: "",
                    transport: "local",
                    liveSessions: []
                )
            ],
            detailLatencyByID: ["ws-release": 200_000_000]
        )
        let model = AppModel(core: client)

        await model.load()

        let firstSelection = Task { await model.selectProject(id: "ws-release") }
        let secondSelection = Task { await model.selectProject(id: "ws-spark3") }
        await firstSelection.value
        await secondSelection.value

        XCTAssertEqual(model.selectedProjectID, "ws-spark3")
        XCTAssertEqual(model.selectedProject?.id, "ws-spark3")
    }

    @MainActor
    func test_detail_fetch_failure_clears_stale_detail_state() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "", transport: "local", liveSessions: 1, recentlyClosedSessions: 1, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-release",
                name: "release",
                path: "",
                transport: "local",
                liveSessions: []
            )],
            detailErrorsByID: ["ws-release": CocoaError(.fileReadUnknown)]
        )
        let model = AppModel(core: client)
        model.selectedProjectID = "stale-project"
        model.selectedProject = ProjectDetailViewData(
            id: "stale-project",
            name: "stale",
            path: "",
            transport: "local",
            liveSessions: []
        )
        model.liveSessions = [.fixture()]

        await model.load()

        XCTAssertEqual(model.projects.map(\.id), ["ws-release"])
        XCTAssertEqual(model.selectedProjectID, "ws-release")
        XCTAssertNil(model.selectedProject)
        XCTAssertEqual(model.liveSessions, [])
        XCTAssertNotNil(model.loadErrorMessage)
    }

    @MainActor
    func test_rename_project_updates_name_in_list() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-release",
                name: "release",
                path: "",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.renameProject(id: "ws-release", newName: "renamed-release")

        XCTAssertEqual(model.projects[0].name, "renamed-release")
    }

    @MainActor
    func test_create_project_inserts_below_active() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "Project 1", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-2", name: "Project 2", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "ws-1",
                    name: "Project 1",
                    path: "",
                    transport: "local",
                    liveSessions: []
                ),
                ProjectDetailViewData(
                    id: "mock-project-id",
                    name: "Project 3",
                    path: "",
                    transport: "local",
                    liveSessions: []
                )
            ]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.selectProject(id: "ws-1")
        await model.createProject(name: "Project 3")

        XCTAssertEqual(model.projects.map(\.id), ["ws-1", "mock-project-id", "ws-2"])
        XCTAssertEqual(model.projects[1].name, "Project 3")
    }

    @MainActor
    func test_delete_project_removes_from_list() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "Project 1", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-2", name: "Project 2", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-1",
                name: "Project 1",
                path: "",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.deleteProject(id: "ws-2")

        XCTAssertEqual(model.projects.count, 1)
    }

    @MainActor
    func test_close_project_hides_from_list() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "Project 1", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-2", name: "Project 2", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-1",
                name: "Project 1",
                path: "",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.closeProject(id: "ws-2")

        XCTAssertEqual(model.projects.count, 1)
        XCTAssertTrue(model.hiddenProjectIDs.contains("ws-2"))
    }

    @MainActor
    func test_close_session_removes_from_live_sessions() async {
        let client = MockProjectCoreClient.projectWithOneLiveSession()
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
    func test_pending_close_session_id_triggers_close_flow() async {
        let client = MockProjectCoreClient.projectWithOneLiveSession()
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
    func test_pending_close_project_id_triggers_close_flow() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "Project 1", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-2", name: "Project 2", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-1",
                name: "Project 1",
                path: "",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        model.pendingCloseProjectID = "ws-2"
        await model.closeProject(id: "ws-2")

        XCTAssertTrue(model.hiddenProjectIDs.contains("ws-2"))
    }
}
