import XCTest
@testable import CodeSpark

final class WorkspaceFlowTests: XCTestCase {
    @MainActor
    func test_closing_a_live_session_moves_it_to_recently_closed() async {
        let core = MockWorkspaceCoreClient.workspaceWithOneLiveSession()
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
        XCTAssertEqual(model.closedSessions.count, 1)
        XCTAssertEqual(model.closedSessions[0].title, "prod logs")
        XCTAssertEqual(model.closedSessions[0].snapshotPreview.lines[1], "error line")
    }
}
