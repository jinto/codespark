import Foundation

protocol WorkspaceCoreClientProtocol {
    func listWorkspaceSummaries() async throws -> [WorkspaceSummaryViewData]
    func workspaceDetail(id: String) async throws -> WorkspaceDetailViewData
    func updateWorkspaceNote(id: String, noteBody: String) async throws

    // MARK: - Future session lifecycle (not yet wired to FFI bridge)
    func recordFinalSnapshotAndClose(
        sessionID: String,
        snapshot: TerminalSnapshotViewData,
        closeReason: CloseReasonViewData
    ) async throws
    func openLocalShellHere(sessionID: String) async throws
    func reconnectSSH(sessionID: String, cdIntoDirectory: Bool) async throws
}

enum WorkspaceCoreClient {
    static let live: WorkspaceCoreClientProtocol = MockWorkspaceCoreClient(
        summaries: []
    )
}

final class MockWorkspaceCoreClient: WorkspaceCoreClientProtocol {
    private let summaries: [WorkspaceSummaryViewData]
    private var detailsByID: [String: WorkspaceDetailViewData]
    private let detailErrorsByID: [String: Error]
    private let detailLatencyByID: [String: UInt64]
    private let noteUpdateError: Error?
    private let noteUpdateLatency: UInt64?
    private(set) var lastRecoveryAction: String?
    private(set) var closedSessionIDs: [String] = []

    init(
        summaries: [WorkspaceSummaryViewData],
        details: [WorkspaceDetailViewData] = [],
        detailErrorsByID: [String: Error] = [:],
        detailLatencyByID: [String: UInt64] = [:],
        noteUpdateError: Error? = nil,
        noteUpdateLatency: UInt64? = nil
    ) {
        self.summaries = summaries
        self.detailsByID = Self.makeDetailsMap(details)
        self.detailErrorsByID = detailErrorsByID
        self.detailLatencyByID = detailLatencyByID
        self.noteUpdateError = noteUpdateError
        self.noteUpdateLatency = noteUpdateLatency
    }

    func listWorkspaceSummaries() async throws -> [WorkspaceSummaryViewData] {
        summaries
    }

    func workspaceDetail(id: String) async throws -> WorkspaceDetailViewData {
        if let detailLatency = detailLatencyByID[id] {
            try? await Task.sleep(nanoseconds: detailLatency)
        }

        if let detailError = detailErrorsByID[id] {
            throw detailError
        }

        guard let detail = detailsByID[id] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return detail
    }

    func updateWorkspaceNote(id: String, noteBody: String) async throws {
        if let noteUpdateLatency {
            try? await Task.sleep(nanoseconds: noteUpdateLatency)
        }

        if let noteUpdateError {
            throw noteUpdateError
        }

        guard var detail = detailsByID[id] else {
            throw CocoaError(.fileNoSuchFile)
        }
        detail.noteBody = noteBody
        detailsByID[id] = detail
    }

    func recordFinalSnapshotAndClose(
        sessionID: String,
        snapshot: TerminalSnapshotViewData,
        closeReason: CloseReasonViewData
    ) async throws {
        closedSessionIDs.append(sessionID)
    }

    func openLocalShellHere(sessionID: String) async throws {
        lastRecoveryAction = "open-local:\(sessionID)"
    }

    func reconnectSSH(sessionID: String, cdIntoDirectory: Bool) async throws {
        lastRecoveryAction = cdIntoDirectory ? "reconnect-ssh-cd:\(sessionID)" : "reconnect-ssh:\(sessionID)"
    }

    private static func makeDetailsMap(
        _ details: [WorkspaceDetailViewData]
    ) -> [String: WorkspaceDetailViewData] {
        Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
    }

    static func workspaceWithOneLiveSession() -> MockWorkspaceCoreClient {
        MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(
                    id: "ws-release",
                    name: "release",
                    liveSessions: 1,
                    recentlyClosedSessions: 0,
                    hasInterruptedSessions: false
                )
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-release",
                name: "release",
                noteBody: "check prod logs",
                liveSessions: [
                    SessionViewData(
                        id: "session-prod",
                        title: "prod logs",
                        targetLabel: "prod",
                        lastCwd: "/srv/app",
                        restoreRecipe: RestoreRecipeViewData(
                            launchCommand: "ssh prod -- 'cd /srv/app && exec zsh -l'"
                        )
                    )
                ],
                closedSessions: []
            )]
        )
    }

    static func workspaceWithInterruptedSession() -> MockWorkspaceCoreClient {
        MockWorkspaceCoreClient(
            summaries: [
                WorkspaceSummaryViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    liveSessions: 0,
                    recentlyClosedSessions: 1,
                    hasInterruptedSessions: true
                )
            ],
            details: [WorkspaceDetailViewData(
                id: "ws-spark3",
                name: "spark3",
                noteBody: "resume after crash",
                liveSessions: [],
                closedSessions: [
                    ClosedSessionViewData(
                        id: "session-interrupted",
                        title: "shell",
                        targetLabel: "local",
                        lastCwd: "/Users/jinto/projects/spark3",
                        lastCommand: "cargo test -p workspace-core",
                        closeReason: .appCrashed,
                        snapshotPreview: .fixture(
                            lines: ["cargo test -p workspace-core", "test result: interrupted"]
                        ),
                        restoreRecipe: RestoreRecipeViewData(
                            launchCommand: "zsh -lc 'cd /Users/jinto/projects/spark3 && exec zsh -l'"
                        )
                    )
                ]
            )]
        )
    }
}
