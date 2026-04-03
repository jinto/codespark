import Foundation

protocol WorkspaceCoreClientProtocol {
    func listWorkspaceSummaries() async throws -> [WorkspaceSummaryViewData]
    func workspaceDetail(id: String) async throws -> WorkspaceDetailViewData
    func updateWorkspaceNote(id: String, noteBody: String) async throws

    // MARK: - Session lifecycle
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
    private let service: OpaquePointer

    init(storePath: String) throws {
        var status = WORKSPACE_STATUS_OK
        guard let svc = storePath.withCString({ workspace_service_new($0, &status) }),
              status == WORKSPACE_STATUS_OK else {
            throw NSError(domain: "WorkspaceCore", code: Int(status.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Failed to open workspace store"
            ])
        }
        self.service = svc
    }

    deinit {
        workspace_service_free(service)
    }

    func listWorkspaceSummaries() async throws -> [WorkspaceSummaryViewData] {
        var summaries: UnsafeMutablePointer<workspace_summary_t>?
        var count: Int32 = 0
        let status = workspace_service_list_workspace_summaries(service, &summaries, &count)
        guard status == WORKSPACE_STATUS_OK else { throw workspaceError(status) }
        defer { workspace_free_summaries(summaries, count) }

        return (0..<Int(count)).map { i in
            let s = summaries![i]
            return WorkspaceSummaryViewData(
                id: String(cString: s.id),
                name: String(cString: s.name),
                liveSessions: Int(s.live_sessions),
                recentlyClosedSessions: Int(s.recently_closed_sessions),
                hasInterruptedSessions: s.has_interrupted_sessions
            )
        }
    }

    func workspaceDetail(id: String) async throws -> WorkspaceDetailViewData {
        var detail = workspace_detail_t()
        let status = id.withCString { workspace_service_workspace_detail(service, $0, &detail) }
        guard status == WORKSPACE_STATUS_OK else { throw workspaceError(status) }
        defer { workspace_free_detail(&detail) }

        let liveSessions = (0..<Int(detail.live_session_count)).map { i -> SessionViewData in
            let s = detail.live_sessions[i]
            return SessionViewData(
                id: String(cString: s.id),
                title: String(cString: s.title),
                targetLabel: String(cString: s.target_label),
                lastCwd: s.last_cwd != nil ? String(cString: s.last_cwd) : nil,
                restoreRecipe: RestoreRecipeViewData(launchCommand: "")
            )
        }

        let closedSessions = (0..<Int(detail.closed_session_count)).map { i -> ClosedSessionViewData in
            let s = detail.closed_sessions[i]
            let grid = s.snapshot_preview
            let lines = (0..<Int(grid.line_count)).map { j -> String in
                guard let line = grid.lines[j] else { return "" }
                return String(cString: line)
            }
            return ClosedSessionViewData(
                id: String(cString: s.id),
                title: String(cString: s.title),
                targetLabel: String(cString: s.target_label),
                lastCwd: s.last_cwd != nil ? String(cString: s.last_cwd) : nil,
                closeReason: CloseReasonViewData.from(cReason: s.close_reason),
                snapshotPreview: TerminalSnapshotViewData(
                    cols: Int(grid.cols),
                    rows: Int(grid.rows),
                    lines: lines
                ),
                restoreRecipe: RestoreRecipeViewData(launchCommand: String(cString: s.restore_recipe.launch_command))
            )
        }

        return WorkspaceDetailViewData(
            id: String(cString: detail.id),
            name: String(cString: detail.name),
            noteBody: String(cString: detail.note_body),
            liveSessions: liveSessions,
            closedSessions: closedSessions
        )
    }

    func updateWorkspaceNote(id: String, noteBody: String) async throws {
        let status = id.withCString { idPtr in
            noteBody.withCString { bodyPtr in
                workspace_service_update_workspace_note(service, idPtr, bodyPtr)
            }
        }
        guard status == WORKSPACE_STATUS_OK else { throw workspaceError(status) }
    }

    // MARK: - Session lifecycle

    func recordFinalSnapshotAndClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) async throws {
        // Record snapshot
        var cLines = snapshot.lines.map { strdup($0) }
        defer { cLines.forEach { free($0) } }

        var input = cLines.withUnsafeMutableBufferPointer { buf -> workspace_new_snapshot_t in
            workspace_new_snapshot_t(
                session_id: nil,
                kind: WORKSPACE_SNAPSHOT_KIND_FINAL,
                cwd: nil,
                cols: UInt16(snapshot.cols),
                rows: UInt16(snapshot.rows),
                lines: UnsafePointer(buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { $0 }),
                line_count: Int32(snapshot.lines.count)
            )
        }

        let snapStatus = sessionID.withCString { idPtr -> workspace_status_t in
            input.session_id = idPtr
            return workspace_service_record_snapshot(service, &input)
        }
        guard snapStatus == WORKSPACE_STATUS_OK else { throw workspaceError(snapStatus) }

        // Close session
        let closeStatus = sessionID.withCString { idPtr in
            workspace_service_close_session(service, idPtr, closeReason.toCReason(), nil)
        }
        guard closeStatus == WORKSPACE_STATUS_OK else { throw workspaceError(closeStatus) }
    }

    func openLocalShellHere(sessionID: String) async throws {
        // Will be wired when process launching is implemented
    }

    func reconnectSSH(sessionID: String, cdIntoDirectory: Bool) async throws {
        // Will be wired when SSH reconnection is implemented
    }

    private func workspaceError(_ status: workspace_status_t) -> Error {
        NSError(domain: "WorkspaceCore", code: Int(status.rawValue), userInfo: [
            NSLocalizedDescriptionKey: "Workspace operation failed (code \(status.rawValue))"
        ])
    }
}
