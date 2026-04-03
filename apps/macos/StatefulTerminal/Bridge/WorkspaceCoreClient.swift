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
    static var live: WorkspaceCoreClientProtocol {
        let dbPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StatefulTerminal", isDirectory: true)
            .appendingPathComponent("store.sqlite3")
            .path
        do {
            try FileManager.default.createDirectory(
                atPath: (dbPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            return try LiveWorkspaceCoreClient(storePath: dbPath)
        } catch {
            fatalError("Failed to initialize workspace store: \(error)")
        }
    }
}

final class LiveWorkspaceCoreClient: WorkspaceCoreClientProtocol {
    private let service: WorkspaceService

    init(storePath: String) throws {
        self.service = try WorkspaceService(storePath: storePath)
    }

    func listWorkspaceSummaries() async throws -> [WorkspaceSummaryViewData] {
        try service.listWorkspaceSummaries().map { summary in
            WorkspaceSummaryViewData(
                id: summary.id,
                name: summary.name,
                liveSessions: Int(summary.liveSessions),
                recentlyClosedSessions: Int(summary.recentlyClosedSessions),
                hasInterruptedSessions: summary.hasInterruptedSessions
            )
        }
    }

    func workspaceDetail(id: String) async throws -> WorkspaceDetailViewData {
        let detail = try service.workspaceDetail(workspaceId: id)
        return WorkspaceDetailViewData(
            id: detail.id,
            name: detail.name,
            noteBody: detail.noteBody,
            liveSessions: detail.liveSessions.map { s in
                SessionViewData(
                    id: s.id,
                    title: s.title,
                    targetLabel: s.targetLabel,
                    lastCwd: s.lastCwd,
                    restoreRecipe: RestoreRecipeViewData(launchCommand: "")
                )
            },
            closedSessions: detail.closedSessions.map { s in
                ClosedSessionViewData(
                    id: s.id,
                    title: s.title,
                    targetLabel: s.targetLabel,
                    lastCwd: s.lastCwd,
                    closeReason: CloseReasonViewData.from(ffi: s.closeReason),
                    snapshotPreview: TerminalSnapshotViewData(
                        cols: Int(s.snapshotPreview.cols),
                        rows: Int(s.snapshotPreview.rows),
                        lines: s.snapshotPreview.lines
                    ),
                    restoreRecipe: RestoreRecipeViewData(launchCommand: s.restoreRecipe.launchCommand)
                )
            }
        )
    }

    func updateWorkspaceNote(id: String, noteBody: String) async throws {
        try service.updateWorkspaceNote(workspaceId: id, noteBody: noteBody)
    }

    // MARK: - Future session lifecycle (not yet wired to FFI bridge)

    func recordFinalSnapshotAndClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) async throws {
        throw CocoaError(.featureUnsupported)
    }

    func openLocalShellHere(sessionID: String) async throws {
        throw CocoaError(.featureUnsupported)
    }

    func reconnectSSH(sessionID: String, cdIntoDirectory: Bool) async throws {
        throw CocoaError(.featureUnsupported)
    }
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
