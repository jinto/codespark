import XCTest
@testable import StatefulTerminal

final class RecoveryActionsTests: XCTestCase {
    @MainActor
    func test_interrupted_session_exposes_manual_recovery_actions() async {
        let client = MockWorkspaceCoreClient.workspaceWithInterruptedSession()
        let model = AppModel(core: client)

        await model.load()

        let actions = model.recoveryActions(for: model.closedSessions[0])
        XCTAssertEqual(actions.map(\.title), [
            "Open local shell here",
            "Reconnect SSH",
            "Reconnect SSH and cd here",
            "Copy session recipe",
        ])
    }
}
