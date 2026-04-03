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
