import XCTest
@testable import CodeSpark

final class ProjectFlowTests: XCTestCase {
    @MainActor
    func test_closing_a_live_session_removes_it() async {
        let core = MockProjectCoreClient.projectWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: core, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()

        host.finishClose(
            sessionID: "session-prod",
            snapshot: .fixture(lines: ["tail -f log", "error line"]),
            closeReason: .userClosed
        )

        XCTAssertEqual(model.liveSessions.count, 0)
    }

    // MARK: - C-6: liveSessionDetails sync

    @MainActor
    func test_new_session_syncs_project_session_details() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Project", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Project", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()
        XCTAssertEqual(model.projects[0].liveSessionDetails.count, 0)

        await model.newSession()

        XCTAssertEqual(model.projects[0].liveSessionDetails.count, 1)
        XCTAssertEqual(model.projects[0].liveSessions, 1)
    }

    @MainActor
    func test_close_session_syncs_project_session_details() async {
        let core = MockProjectCoreClient.projectWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: core, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()
        XCTAssertEqual(model.projects[0].liveSessionDetails.count, 1)

        host.finishClose(sessionID: "session-prod", snapshot: .fixture(lines: []), closeReason: .userClosed)

        XCTAssertEqual(model.projects[0].liveSessionDetails.count, 0)
        XCTAssertEqual(model.projects[0].liveSessions, 0)
    }

    // MARK: - Duplicate cwd crash prevention

    @MainActor
    func test_multiple_sessions_same_cwd_no_crash_on_git_refresh() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Project", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Project", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()
        // Create 3 sessions — all get same cwd "/tmp/proj"
        await model.newSession()
        await model.newSession()
        await model.newSession()

        XCTAssertEqual(model.liveSessions.count, 3)
        // This must not crash with "Duplicate values for key"
        model.refreshGitBranches()
    }
}
