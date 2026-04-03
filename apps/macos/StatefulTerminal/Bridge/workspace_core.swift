import Foundation

enum WorkspaceServiceError: Error, Equatable {
    case openStoreFailed
    case createWorkspaceFailed
    case updateWorkspaceNoteFailed
    case workspaceDetailFailed
    case poisonedState
    case listWorkspacesFailed
    case reconcileInterruptedFailed
    case startSessionFailed
    case recordSnapshotFailed
    case closeSessionFailed

    init(status: workspace_status_t) {
        switch status {
        case WORKSPACE_STATUS_OPEN_STORE_FAILED:
            self = .openStoreFailed
        case WORKSPACE_STATUS_CREATE_WORKSPACE_FAILED:
            self = .createWorkspaceFailed
        case WORKSPACE_STATUS_UPDATE_WORKSPACE_NOTE_FAILED:
            self = .updateWorkspaceNoteFailed
        case WORKSPACE_STATUS_WORKSPACE_DETAIL_FAILED:
            self = .workspaceDetailFailed
        case WORKSPACE_STATUS_POISONED_STATE:
            self = .poisonedState
        case WORKSPACE_STATUS_LIST_WORKSPACES_FAILED:
            self = .listWorkspacesFailed
        case WORKSPACE_STATUS_RECONCILE_INTERRUPTED_FAILED:
            self = .reconcileInterruptedFailed
        case WORKSPACE_STATUS_START_SESSION_FAILED:
            self = .startSessionFailed
        case WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED:
            self = .recordSnapshotFailed
        case WORKSPACE_STATUS_CLOSE_SESSION_FAILED:
            self = .closeSessionFailed
        case WORKSPACE_STATUS_OK:
            self = .workspaceDetailFailed
        default:
            self = .workspaceDetailFailed
        }
    }
}

enum SessionTransport: Equatable, Sendable {
    case local
    case ssh

    init(cValue: workspace_session_transport_t) {
        switch cValue {
        case WORKSPACE_SESSION_TRANSPORT_SSH:
            self = .ssh
        default:
            self = .local
        }
    }

    var cValue: workspace_session_transport_t {
        switch self {
        case .local:
            return WORKSPACE_SESSION_TRANSPORT_LOCAL
        case .ssh:
            return WORKSPACE_SESSION_TRANSPORT_SSH
        }
    }
}

enum CloseReason: Equatable, Sendable {
    case userClosed
    case processExited
    case sshDisconnected
    case appCrashed
    case hostQuit

    init(cValue: workspace_close_reason_t) {
        switch cValue {
        case WORKSPACE_CLOSE_REASON_PROCESS_EXITED:
            self = .processExited
        case WORKSPACE_CLOSE_REASON_SSH_DISCONNECTED:
            self = .sshDisconnected
        case WORKSPACE_CLOSE_REASON_APP_CRASHED:
            self = .appCrashed
        case WORKSPACE_CLOSE_REASON_HOST_QUIT:
            self = .hostQuit
        default:
            self = .userClosed
        }
    }

    var cValue: workspace_close_reason_t {
        switch self {
        case .userClosed:
            return WORKSPACE_CLOSE_REASON_USER_CLOSED
        case .processExited:
            return WORKSPACE_CLOSE_REASON_PROCESS_EXITED
        case .sshDisconnected:
            return WORKSPACE_CLOSE_REASON_SSH_DISCONNECTED
        case .appCrashed:
            return WORKSPACE_CLOSE_REASON_APP_CRASHED
        case .hostQuit:
            return WORKSPACE_CLOSE_REASON_HOST_QUIT
        }
    }
}

struct TerminalGrid: Equatable, Hashable, Sendable {
    var cols: UInt16
    var rows: UInt16
    var lines: [String]
}

struct RestoreRecipe: Equatable, Hashable, Sendable {
    var launchCommand: String
}

struct WorkspaceSessionSummary: Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var transport: SessionTransport
    var targetLabel: String
    var lastCwd: String?
    var closeReason: CloseReason
}

struct WorkspaceClosedSessionSummary: Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var transport: SessionTransport
    var targetLabel: String
    var lastCwd: String?
    var closeReason: CloseReason
    var snapshotPreview: TerminalGrid
    var restoreRecipe: RestoreRecipe
}

struct WorkspaceSummary: Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var liveSessions: Int64
    var recentlyClosedSessions: Int64
    var hasInterruptedSessions: Bool
    var updatedAt: Int64
}

struct WorkspaceDetail: Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var noteBody: String
    var liveSessions: [WorkspaceSessionSummary]
    var closedSessions: [WorkspaceClosedSessionSummary]
}

protocol WorkspaceServiceProtocol: AnyObject, Sendable {
    func closeSession(sessionId: String, reason: CloseReason, lastCwd: String?) throws
    func createWorkspace(name: String) throws -> String
    func listWorkspaceSummaries() throws -> [WorkspaceSummary]
    func reconcileInterruptedSessions() throws
    func recordSnapshot(sessionId: String, kind: String, cwd: String?, cols: UInt16, rows: UInt16, lines: [String]) throws
    func startSession(workspaceId: String, transport: SessionTransport, targetLabel: String, title: String, shell: String, initialCwd: String?) throws -> String
    func updateWorkspaceNote(workspaceId: String, noteBody: String) throws
    func workspaceDetail(workspaceId: String) throws -> WorkspaceDetail
}

final class WorkspaceService: WorkspaceServiceProtocol, @unchecked Sendable {
    private let handle: OpaquePointer

    init(storePath: String) throws {
        var status = WORKSPACE_STATUS_OK
        guard let handle = workspace_service_new(storePath, &status) else {
            throw WorkspaceServiceError(status: status)
        }
        self.handle = handle
    }

    deinit {
        workspace_service_free(handle)
    }

    func closeSession(sessionId: String, reason: CloseReason, lastCwd: String?) throws {
        try throwIfNeeded(
            workspace_service_close_session(handle, sessionId, reason.cValue, lastCwd),
            defaultError: .closeSessionFailed
        )
    }

    func createWorkspace(name: String) throws -> String {
        var result: UnsafeMutablePointer<CChar>? = nil
        let status = workspace_service_create_workspace(handle, name, &result)
        guard status == WORKSPACE_STATUS_OK, let result else {
            throw WorkspaceServiceError(status: status)
        }
        defer { workspace_free_string(result) }
        return String(cString: result)
    }

    func listWorkspaceSummaries() throws -> [WorkspaceSummary] {
        var summaries: UnsafeMutablePointer<workspace_summary_t>? = nil
        var count: Int32 = 0
        let status = workspace_service_list_workspace_summaries(handle, &summaries, &count)
        guard status == WORKSPACE_STATUS_OK else {
            throw WorkspaceServiceError(status: status)
        }
        defer { workspace_free_summaries(summaries, count) }

        guard let summaries, count > 0 else { return [] }
        return UnsafeBufferPointer(start: summaries, count: Int(count)).map(Self.makeWorkspaceSummary)
    }

    func reconcileInterruptedSessions() throws {
        try throwIfNeeded(
            workspace_service_reconcile_interrupted_sessions(handle),
            defaultError: .reconcileInterruptedFailed
        )
    }

    func recordSnapshot(sessionId: String, kind: String, cwd: String?, cols: UInt16, rows: UInt16, lines: [String]) throws {
        let snapshotKind: workspace_snapshot_kind_t = kind == "final"
            ? WORKSPACE_SNAPSHOT_KIND_FINAL
            : WORKSPACE_SNAPSHOT_KIND_CHECKPOINT

        try sessionId.withCString { sessionIdPtr in
            try withOptionalCString(cwd) { cwdPtr in
                try withCStringArray(lines) { rawLines in
                    var input = workspace_new_snapshot_t(
                        session_id: sessionIdPtr,
                        kind: snapshotKind,
                        cwd: cwdPtr,
                        cols: cols,
                        rows: rows,
                        lines: rawLines.baseAddress,
                        line_count: Int32(rawLines.count)
                    )
                    try throwIfNeeded(
                        workspace_service_record_snapshot(handle, &input),
                        defaultError: .recordSnapshotFailed
                    )
                }
            }
        }
    }

    func startSession(
        workspaceId: String,
        transport: SessionTransport,
        targetLabel: String,
        title: String,
        shell: String,
        initialCwd: String?
    ) throws -> String {
        try workspaceId.withCString { workspaceIdPtr in
            try targetLabel.withCString { targetLabelPtr in
                try title.withCString { titlePtr in
                    try shell.withCString { shellPtr in
                        try withOptionalCString(initialCwd) { initialCwdPtr in
                            var input = workspace_new_session_t(
                                workspace_id: workspaceIdPtr,
                                transport: transport.cValue,
                                target_label: targetLabelPtr,
                                title: titlePtr,
                                shell: shellPtr,
                                initial_cwd: initialCwdPtr
                            )
                            var result: UnsafeMutablePointer<CChar>? = nil
                            let status = workspace_service_start_session(handle, &input, &result)
                            guard status == WORKSPACE_STATUS_OK, let result else {
                                throw WorkspaceServiceError(status: status)
                            }
                            defer { workspace_free_string(result) }
                            return String(cString: result)
                        }
                    }
                }
            }
        }
    }

    func updateWorkspaceNote(workspaceId: String, noteBody: String) throws {
        try throwIfNeeded(
            workspace_service_update_workspace_note(handle, workspaceId, noteBody),
            defaultError: .updateWorkspaceNoteFailed
        )
    }

    func workspaceDetail(workspaceId: String) throws -> WorkspaceDetail {
        var raw = workspace_detail_t()
        let status = workspace_service_workspace_detail(handle, workspaceId, &raw)
        guard status == WORKSPACE_STATUS_OK else {
            workspace_free_detail(&raw)
            throw WorkspaceServiceError(status: status)
        }
        defer { workspace_free_detail(&raw) }
        return Self.makeWorkspaceDetail(raw)
    }

    private func throwIfNeeded(_ status: workspace_status_t, defaultError: WorkspaceServiceError) throws {
        guard status == WORKSPACE_STATUS_OK else {
            if status == WORKSPACE_STATUS_OK {
                return
            }
            throw WorkspaceServiceError(status: status)
        }
        _ = defaultError
    }

    private static func makeWorkspaceSummary(_ raw: workspace_summary_t) -> WorkspaceSummary {
        WorkspaceSummary(
            id: requiredString(raw.id),
            name: requiredString(raw.name),
            liveSessions: raw.live_sessions,
            recentlyClosedSessions: raw.recently_closed_sessions,
            hasInterruptedSessions: raw.has_interrupted_sessions,
            updatedAt: raw.updated_at
        )
    }

    private static func makeSessionSummary(_ raw: workspace_session_summary_t) -> WorkspaceSessionSummary {
        WorkspaceSessionSummary(
            id: requiredString(raw.id),
            title: requiredString(raw.title),
            transport: SessionTransport(cValue: raw.transport),
            targetLabel: requiredString(raw.target_label),
            lastCwd: optionalString(raw.last_cwd),
            closeReason: CloseReason(cValue: raw.close_reason)
        )
    }

    private static func makeClosedSessionSummary(_ raw: workspace_closed_session_summary_t) -> WorkspaceClosedSessionSummary {
        WorkspaceClosedSessionSummary(
            id: requiredString(raw.id),
            title: requiredString(raw.title),
            transport: SessionTransport(cValue: raw.transport),
            targetLabel: requiredString(raw.target_label),
            lastCwd: optionalString(raw.last_cwd),
            closeReason: CloseReason(cValue: raw.close_reason),
            snapshotPreview: makeTerminalGrid(raw.snapshot_preview),
            restoreRecipe: RestoreRecipe(launchCommand: requiredString(raw.restore_recipe.launch_command))
        )
    }

    private static func makeWorkspaceDetail(_ raw: workspace_detail_t) -> WorkspaceDetail {
        let liveSessions: [WorkspaceSessionSummary]
        if let sessions = raw.live_sessions, raw.live_session_count > 0 {
            liveSessions = UnsafeBufferPointer(start: sessions, count: Int(raw.live_session_count)).map(makeSessionSummary)
        } else {
            liveSessions = []
        }

        let closedSessions: [WorkspaceClosedSessionSummary]
        if let sessions = raw.closed_sessions, raw.closed_session_count > 0 {
            closedSessions = UnsafeBufferPointer(start: sessions, count: Int(raw.closed_session_count)).map(makeClosedSessionSummary)
        } else {
            closedSessions = []
        }

        return WorkspaceDetail(
            id: requiredString(raw.id),
            name: requiredString(raw.name),
            noteBody: requiredString(raw.note_body),
            liveSessions: liveSessions,
            closedSessions: closedSessions
        )
    }

    private static func makeTerminalGrid(_ raw: workspace_terminal_grid_t) -> TerminalGrid {
        let lines: [String]
        if let rawLines = raw.lines, raw.line_count > 0 {
            lines = UnsafeBufferPointer(
                start: UnsafePointer(rawLines),
                count: Int(raw.line_count)
            ).map { rawLine in
                rawLine.map { String(cString: $0) } ?? ""
            }
        } else {
            lines = []
        }

        return TerminalGrid(
            cols: raw.cols,
            rows: raw.rows,
            lines: lines
        )
    }

    private static func requiredString(_ value: UnsafeMutablePointer<CChar>?) -> String {
        value.map { String(cString: $0) } ?? ""
    }

    private static func optionalString(_ value: UnsafeMutablePointer<CChar>?) -> String? {
        value.map { String(cString: $0) }
    }
}

private func withCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) throws -> R
) throws -> R {
    let duplicated = strings.map { strdup($0) }
    defer {
        duplicated.forEach { pointer in
            if let pointer {
                free(pointer)
            }
        }
    }

    let pointers = duplicated.map { pointer in
        pointer.map { UnsafePointer<CChar>($0) }
    }
    return try pointers.withUnsafeBufferPointer(body)
}

private func withOptionalCString<R>(
    _ string: String?,
    _ body: (UnsafePointer<CChar>?) throws -> R
) throws -> R {
    if let string {
        return try string.withCString(body)
    }
    return try body(nil)
}
