import Foundation

enum ProjectServiceError: Error, Equatable {
    case openStoreFailed
    case createProjectFailed
    case updateProjectNoteFailed
    case projectDetailFailed
    case poisonedState
    case listProjectsFailed
    case reconcileInterruptedFailed
    case startSessionFailed
    case recordSnapshotFailed
    case closeSessionFailed
    case renameProjectFailed
    case deleteProjectFailed

    init(status: project_status_t) {
        switch status {
        case PROJECT_STATUS_OPEN_STORE_FAILED:
            self = .openStoreFailed
        case PROJECT_STATUS_CREATE_PROJECT_FAILED:
            self = .createProjectFailed
        case PROJECT_STATUS_UPDATE_PROJECT_NOTE_FAILED:
            self = .updateProjectNoteFailed
        case PROJECT_STATUS_PROJECT_DETAIL_FAILED:
            self = .projectDetailFailed
        case PROJECT_STATUS_POISONED_STATE:
            self = .poisonedState
        case PROJECT_STATUS_LIST_PROJECTS_FAILED:
            self = .listProjectsFailed
        case PROJECT_STATUS_RECONCILE_INTERRUPTED_FAILED:
            self = .reconcileInterruptedFailed
        case PROJECT_STATUS_START_SESSION_FAILED:
            self = .startSessionFailed
        case PROJECT_STATUS_RECORD_SNAPSHOT_FAILED:
            self = .recordSnapshotFailed
        case PROJECT_STATUS_CLOSE_SESSION_FAILED:
            self = .closeSessionFailed
        case PROJECT_STATUS_RENAME_PROJECT_FAILED:
            self = .renameProjectFailed
        case PROJECT_STATUS_DELETE_PROJECT_FAILED:
            self = .deleteProjectFailed
        case PROJECT_STATUS_OK:
            fatalError("ProjectServiceError.init(status:) must not be called with PROJECT_STATUS_OK")
        default:
            self = .projectDetailFailed
        }
    }
}

enum SessionTransport: Equatable, Sendable {
    case local
    case ssh

    init(cValue: project_session_transport_t) {
        switch cValue {
        case PROJECT_SESSION_TRANSPORT_SSH:
            self = .ssh
        default:
            self = .local
        }
    }

    var cValue: project_session_transport_t {
        switch self {
        case .local:
            return PROJECT_SESSION_TRANSPORT_LOCAL
        case .ssh:
            return PROJECT_SESSION_TRANSPORT_SSH
        }
    }
}

enum CloseReason: Equatable, Sendable {
    case userClosed
    case processExited
    case sshDisconnected
    case appCrashed
    case hostQuit

    init(cValue: project_close_reason_t) {
        switch cValue {
        case PROJECT_CLOSE_REASON_PROCESS_EXITED:
            self = .processExited
        case PROJECT_CLOSE_REASON_SSH_DISCONNECTED:
            self = .sshDisconnected
        case PROJECT_CLOSE_REASON_APP_CRASHED:
            self = .appCrashed
        case PROJECT_CLOSE_REASON_HOST_QUIT:
            self = .hostQuit
        default:
            self = .userClosed
        }
    }

    var cValue: project_close_reason_t {
        switch self {
        case .userClosed:
            return PROJECT_CLOSE_REASON_USER_CLOSED
        case .processExited:
            return PROJECT_CLOSE_REASON_PROCESS_EXITED
        case .sshDisconnected:
            return PROJECT_CLOSE_REASON_SSH_DISCONNECTED
        case .appCrashed:
            return PROJECT_CLOSE_REASON_APP_CRASHED
        case .hostQuit:
            return PROJECT_CLOSE_REASON_HOST_QUIT
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

struct ProjectSessionSummary: Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var transport: SessionTransport
    var targetLabel: String
    var lastCwd: String?
    var closeReason: CloseReason
}

struct ProjectClosedSessionSummary: Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var transport: SessionTransport
    var targetLabel: String
    var lastCwd: String?
    var closeReason: CloseReason
    var snapshotPreview: TerminalGrid
    var restoreRecipe: RestoreRecipe
}

struct ProjectSummary: Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var liveSessions: Int64
    var recentlyClosedSessions: Int64
    var hasInterruptedSessions: Bool
    var updatedAt: Int64
}

struct ProjectDetail: Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var noteBody: String
    var liveSessions: [ProjectSessionSummary]
    var closedSessions: [ProjectClosedSessionSummary]
}

protocol ProjectServiceProtocol: AnyObject, Sendable {
    func closeSession(sessionId: String, reason: CloseReason, lastCwd: String?) throws
    func createProject(name: String) throws -> String
    func listProjectSummaries() throws -> [ProjectSummary]
    func reconcileInterruptedSessions() throws
    func recordSnapshot(sessionId: String, kind: String, cwd: String?, cols: UInt16, rows: UInt16, lines: [String]) throws
    func startSession(projectId: String, transport: SessionTransport, targetLabel: String, title: String, shell: String, initialCwd: String?) throws -> String
    func updateProjectNote(projectId: String, noteBody: String) throws
    func renameProject(projectId: String, newName: String) throws
    func deleteProject(projectId: String) throws
    func projectDetail(projectId: String) throws -> ProjectDetail
}

final class ProjectService: ProjectServiceProtocol, @unchecked Sendable {
    private let handle: OpaquePointer

    init(storePath: String) throws {
        var status = PROJECT_STATUS_OK
        guard let handle = project_service_new(storePath, &status) else {
            throw ProjectServiceError(status: status)
        }
        self.handle = handle
    }

    deinit {
        project_service_free(handle)
    }

    func closeSession(sessionId: String, reason: CloseReason, lastCwd: String?) throws {
        try throwIfNeeded(
            project_service_close_session(handle, sessionId, reason.cValue, lastCwd),
            defaultError: .closeSessionFailed
        )
    }

    func createProject(name: String) throws -> String {
        var result: UnsafeMutablePointer<CChar>? = nil
        let status = project_service_create_project(handle, name, &result)
        guard status == PROJECT_STATUS_OK, let result else {
            throw ProjectServiceError(status: status)
        }
        defer { project_free_string(result) }
        return String(cString: result)
    }

    func listProjectSummaries() throws -> [ProjectSummary] {
        var summaries: UnsafeMutablePointer<project_summary_t>? = nil
        var count: Int32 = 0
        let status = project_service_list_project_summaries(handle, &summaries, &count)
        guard status == PROJECT_STATUS_OK else {
            throw ProjectServiceError(status: status)
        }
        defer { project_free_summaries(summaries, count) }

        guard let summaries, count > 0 else { return [] }
        return UnsafeBufferPointer(start: summaries, count: Int(count)).map(Self.makeProjectSummary)
    }

    func reconcileInterruptedSessions() throws {
        try throwIfNeeded(
            project_service_reconcile_interrupted_sessions(handle),
            defaultError: .reconcileInterruptedFailed
        )
    }

    func recordSnapshot(sessionId: String, kind: String, cwd: String?, cols: UInt16, rows: UInt16, lines: [String]) throws {
        let snapshotKind: project_snapshot_kind_t = kind == "final"
            ? PROJECT_SNAPSHOT_KIND_FINAL
            : PROJECT_SNAPSHOT_KIND_CHECKPOINT

        try sessionId.withCString { sessionIdPtr in
            try withOptionalCString(cwd) { cwdPtr in
                try withCStringArray(lines) { rawLines in
                    var input = project_new_snapshot_t(
                        session_id: sessionIdPtr,
                        kind: snapshotKind,
                        cwd: cwdPtr,
                        cols: cols,
                        rows: rows,
                        lines: rawLines.baseAddress,
                        line_count: Int32(rawLines.count)
                    )
                    try throwIfNeeded(
                        project_service_record_snapshot(handle, &input),
                        defaultError: .recordSnapshotFailed
                    )
                }
            }
        }
    }

    func startSession(
        projectId: String,
        transport: SessionTransport,
        targetLabel: String,
        title: String,
        shell: String,
        initialCwd: String?
    ) throws -> String {
        try projectId.withCString { projectIdPtr in
            try targetLabel.withCString { targetLabelPtr in
                try title.withCString { titlePtr in
                    try shell.withCString { shellPtr in
                        try withOptionalCString(initialCwd) { initialCwdPtr in
                            var input = project_new_session_t(
                                project_id: projectIdPtr,
                                transport: transport.cValue,
                                target_label: targetLabelPtr,
                                title: titlePtr,
                                shell: shellPtr,
                                initial_cwd: initialCwdPtr
                            )
                            var result: UnsafeMutablePointer<CChar>? = nil
                            let status = project_service_start_session(handle, &input, &result)
                            guard status == PROJECT_STATUS_OK, let result else {
                                throw ProjectServiceError(status: status)
                            }
                            defer { project_free_string(result) }
                            return String(cString: result)
                        }
                    }
                }
            }
        }
    }

    func updateProjectNote(projectId: String, noteBody: String) throws {
        try throwIfNeeded(
            project_service_update_project_note(handle, projectId, noteBody),
            defaultError: .updateProjectNoteFailed
        )
    }

    func renameProject(projectId: String, newName: String) throws {
        try throwIfNeeded(
            project_service_rename_project(handle, projectId, newName),
            defaultError: .renameProjectFailed
        )
    }

    func deleteProject(projectId: String) throws {
        try throwIfNeeded(
            project_service_delete_project(handle, projectId),
            defaultError: .deleteProjectFailed
        )
    }

    func projectDetail(projectId: String) throws -> ProjectDetail {
        var raw = project_detail_t()
        let status = project_service_project_detail(handle, projectId, &raw)
        guard status == PROJECT_STATUS_OK else {
            project_free_detail(&raw)
            throw ProjectServiceError(status: status)
        }
        defer { project_free_detail(&raw) }
        return Self.makeProjectDetail(raw)
    }

    private func throwIfNeeded(_ status: project_status_t, defaultError: ProjectServiceError) throws {
        guard status == PROJECT_STATUS_OK else {
            if status == PROJECT_STATUS_OK {
                return
            }
            throw ProjectServiceError(status: status)
        }
        _ = defaultError
    }

    private static func makeProjectSummary(_ raw: project_summary_t) -> ProjectSummary {
        ProjectSummary(
            id: requiredString(raw.id),
            name: requiredString(raw.name),
            liveSessions: raw.live_sessions,
            recentlyClosedSessions: raw.recently_closed_sessions,
            hasInterruptedSessions: raw.has_interrupted_sessions,
            updatedAt: raw.updated_at
        )
    }

    private static func makeSessionSummary(_ raw: project_session_summary_t) -> ProjectSessionSummary {
        ProjectSessionSummary(
            id: requiredString(raw.id),
            title: requiredString(raw.title),
            transport: SessionTransport(cValue: raw.transport),
            targetLabel: requiredString(raw.target_label),
            lastCwd: optionalString(raw.last_cwd),
            closeReason: CloseReason(cValue: raw.close_reason)
        )
    }

    private static func makeClosedSessionSummary(_ raw: project_closed_session_summary_t) -> ProjectClosedSessionSummary {
        ProjectClosedSessionSummary(
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

    private static func makeProjectDetail(_ raw: project_detail_t) -> ProjectDetail {
        let liveSessions: [ProjectSessionSummary]
        if let sessions = raw.live_sessions, raw.live_session_count > 0 {
            liveSessions = UnsafeBufferPointer(start: sessions, count: Int(raw.live_session_count)).map(makeSessionSummary)
        } else {
            liveSessions = []
        }

        let closedSessions: [ProjectClosedSessionSummary]
        if let sessions = raw.closed_sessions, raw.closed_session_count > 0 {
            closedSessions = UnsafeBufferPointer(start: sessions, count: Int(raw.closed_session_count)).map(makeClosedSessionSummary)
        } else {
            closedSessions = []
        }

        return ProjectDetail(
            id: requiredString(raw.id),
            name: requiredString(raw.name),
            noteBody: requiredString(raw.note_body),
            liveSessions: liveSessions,
            closedSessions: closedSessions
        )
    }

    private static func makeTerminalGrid(_ raw: project_terminal_grid_t) -> TerminalGrid {
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
