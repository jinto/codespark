import XCTest
@testable import CodeSpark

final class RecoveryActionsTests: XCTestCase {
    @MainActor
    func test_local_session_shows_open_shell_and_copy_recipe() async {
        let client = MockProjectCoreClient.projectWithInterruptedSession()
        let model = AppModel(core: client)

        await model.load()

        let actions = model.recoveryActions(for: model.closedSessions[0])
        XCTAssertEqual(actions.map(\.title), [
            "Open local shell here",
            "Copy session recipe",
        ])
    }

    @MainActor
    func test_ssh_session_shows_reconnect_actions() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(
                    id: "ws-ssh", name: "ssh-work", liveSessions: 0,
                    recentlyClosedSessions: 1, hasInterruptedSessions: false,
                    liveSessionDetails: []
                )
            ],
            details: [ProjectDetailViewData(
                id: "ws-ssh", name: "ssh-work", noteBody: "",
                liveSessions: [],
                closedSessions: [
                    ClosedSessionViewData(
                        id: "session-ssh",
                        title: "prod logs",
                        targetLabel: "prod",
                        lastCwd: "/srv/app",
                        closeReason: .sshDisconnected,
                        snapshotPreview: .fixture(lines: ["$ tail -f log"]),
                        restoreRecipe: RestoreRecipeViewData(
                            launchCommand: "ssh prod -- 'cd /srv/app && exec zsh -l'"
                        )
                    )
                ]
            )]
        )
        let model = AppModel(core: client)
        await model.load()

        let actions = model.recoveryActions(for: model.closedSessions[0])
        XCTAssertEqual(actions.map(\.title), [
            "Open local shell here",
            "Reconnect SSH and cd here",
            "Copy session recipe",
        ])
    }
}
