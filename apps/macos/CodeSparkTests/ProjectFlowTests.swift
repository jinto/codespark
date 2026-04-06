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
}
