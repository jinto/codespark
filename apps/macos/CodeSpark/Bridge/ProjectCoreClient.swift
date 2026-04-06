import Foundation

protocol ProjectCoreClientProtocol {
    func createProject(name: String, path: String, transport: String) async throws -> String
    func listProjectSummaries() async throws -> [ProjectSummaryViewData]
    func projectDetail(id: String) async throws -> ProjectDetailViewData
    func renameProject(id: String, newName: String) async throws
    func deleteProject(id: String) async throws
    func startSession(projectId: String, transport: String, targetLabel: String, title: String, shell: String, initialCwd: String?) async throws -> String

    // MARK: - Session lifecycle
    func recordFinalSnapshotAndClose(
        sessionID: String,
        snapshot: TerminalSnapshotViewData,
        closeReason: CloseReasonViewData
    ) async throws
    func updateSessionTitle(sessionId: String, newTitle: String) async throws
    func reconcileInterruptedSessions() async throws
    func recordCheckpointSnapshot(sessionID: String, snapshot: TerminalSnapshotViewData) async throws
}

enum ProjectCoreClient {
    static var live: ProjectCoreClientProtocol {
        let dbPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeSpark", isDirectory: true)
            .appendingPathComponent("store.sqlite3")
            .path
        do {
            try FileManager.default.createDirectory(
                atPath: (dbPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            return try LiveProjectCoreClient(storePath: dbPath)
        } catch {
            fatalError("Failed to initialize project store: \(error)")
        }
    }
}

final class LiveProjectCoreClient: ProjectCoreClientProtocol {
    private let service: OpaquePointer

    init(storePath: String) throws {
        var status = PROJECT_STATUS_OK
        guard let svc = storePath.withCString({ project_service_new($0, &status) }),
              status == PROJECT_STATUS_OK else {
            throw NSError(domain: "ProjectCore", code: Int(status.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Failed to open project store"
            ])
        }
        self.service = svc
    }

    deinit {
        project_service_free(service)
    }

    func createProject(name: String, path: String, transport: String) async throws -> String {
        var outId: UnsafeMutablePointer<CChar>?
        let cTransport: project_session_transport_t = transport == "ssh"
            ? PROJECT_SESSION_TRANSPORT_SSH
            : PROJECT_SESSION_TRANSPORT_LOCAL
        let status = name.withCString { namePtr in
            path.withCString { pathPtr in
                project_service_create_project(service, namePtr, pathPtr, cTransport, &outId)
            }
        }
        guard status == PROJECT_STATUS_OK, let outId else { throw projectError(status) }
        defer { project_free_string(outId) }
        return String(cString: outId)
    }

    func startSession(projectId: String, transport: String, targetLabel: String, title: String, shell: String, initialCwd: String?) async throws -> String {
        var input = project_new_session_t(
            project_id: nil,
            transport: transport == "ssh" ? PROJECT_SESSION_TRANSPORT_SSH : PROJECT_SESSION_TRANSPORT_LOCAL,
            target_label: nil,
            title: nil,
            shell: nil,
            initial_cwd: nil
        )
        var outId: UnsafeMutablePointer<CChar>?
        let status = projectId.withCString { projPtr in
            targetLabel.withCString { tlPtr in
                title.withCString { titlePtr in
                    shell.withCString { shellPtr in
                        input.project_id = projPtr
                        input.target_label = tlPtr
                        input.title = titlePtr
                        input.shell = shellPtr
                        if let cwd = initialCwd {
                            return cwd.withCString { cwdPtr in
                                input.initial_cwd = cwdPtr
                                return project_service_start_session(service, &input, &outId)
                            }
                        } else {
                            return project_service_start_session(service, &input, &outId)
                        }
                    }
                }
            }
        }
        guard status == PROJECT_STATUS_OK, let outId else { throw projectError(status) }
        defer { project_free_string(outId) }
        return String(cString: outId)
    }

    func listProjectSummaries() async throws -> [ProjectSummaryViewData] {
        var summaries: UnsafeMutablePointer<project_summary_t>?
        var count: Int32 = 0
        let status = project_service_list_project_summaries(service, &summaries, &count)
        guard status == PROJECT_STATUS_OK else { throw projectError(status) }
        defer { project_free_summaries(summaries, count) }

        return (0..<Int(count)).map { i in
            let s = summaries![i]
            let details = (0..<Int(s.live_session_detail_count)).map { j in
                let d = s.live_session_details![j]
                return SessionSummary(
                    id: String(cString: d.id),
                    title: String(cString: d.title),
                    targetLabel: String(cString: d.target_label),
                    lastCwd: d.last_cwd != nil ? String(cString: d.last_cwd) : nil
                )
            }
            let transportStr: String = s.transport == PROJECT_SESSION_TRANSPORT_SSH ? "ssh" : "local"
            return ProjectSummaryViewData(
                id: String(cString: s.id),
                name: String(cString: s.name),
                path: String(cString: s.path),
                transport: transportStr,
                liveSessions: Int(s.live_sessions),
                recentlyClosedSessions: Int(s.recently_closed_sessions),
                hasInterruptedSessions: s.has_interrupted_sessions,
                liveSessionDetails: details
            )
        }
    }

    func projectDetail(id: String) async throws -> ProjectDetailViewData {
        var detail = project_detail_t()
        let status = id.withCString { project_service_project_detail(service, $0, &detail) }
        guard status == PROJECT_STATUS_OK else { throw projectError(status) }
        defer { project_free_detail(&detail) }

        let liveSessions = (0..<Int(detail.live_session_count)).map { i -> SessionViewData in
            let s = detail.live_sessions[i]
            return SessionViewData(
                id: String(cString: s.id),
                title: String(cString: s.title),
                targetLabel: String(cString: s.target_label),
                lastCwd: s.last_cwd != nil ? String(cString: s.last_cwd) : nil
            )
        }

        let transportStr: String = detail.transport == PROJECT_SESSION_TRANSPORT_SSH ? "ssh" : "local"
        return ProjectDetailViewData(
            id: String(cString: detail.id),
            name: String(cString: detail.name),
            path: String(cString: detail.path),
            transport: transportStr,
            liveSessions: liveSessions
        )
    }

    func updateSessionTitle(sessionId: String, newTitle: String) async throws {
        let status = sessionId.withCString { idPtr in
            newTitle.withCString { titlePtr in
                project_service_update_session_title(service, idPtr, titlePtr)
            }
        }
        guard status == PROJECT_STATUS_OK else { throw projectError(status) }
    }

    func renameProject(id: String, newName: String) async throws {
        let status = id.withCString { idPtr in
            newName.withCString { namePtr in
                project_service_rename_project(service, idPtr, namePtr)
            }
        }
        guard status == PROJECT_STATUS_OK else { throw projectError(status) }
    }

    func deleteProject(id: String) async throws {
        let status = id.withCString { idPtr in
            project_service_delete_project(service, idPtr)
        }
        guard status == PROJECT_STATUS_OK else { throw projectError(status) }
    }

    // MARK: - Session lifecycle

    func recordFinalSnapshotAndClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) async throws {
        try recordSnapshot(sessionID: sessionID, snapshot: snapshot, kind: PROJECT_SNAPSHOT_KIND_FINAL)

        let closeStatus = sessionID.withCString { idPtr in
            project_service_close_session(service, idPtr, closeReason.toCReason(), nil)
        }
        guard closeStatus == PROJECT_STATUS_OK else { throw projectError(closeStatus) }
    }

    func reconcileInterruptedSessions() async throws {
        let status = project_service_reconcile_interrupted_sessions(service)
        guard status == PROJECT_STATUS_OK else { throw projectError(status) }
    }

    func recordCheckpointSnapshot(sessionID: String, snapshot: TerminalSnapshotViewData) async throws {
        guard !snapshot.lines.isEmpty else { return }
        try recordSnapshot(sessionID: sessionID, snapshot: snapshot, kind: PROJECT_SNAPSHOT_KIND_CHECKPOINT)
    }

    private func recordSnapshot(sessionID: String, snapshot: TerminalSnapshotViewData, kind: project_snapshot_kind_t) throws {
        var cLines = snapshot.lines.map { strdup($0) }
        defer { cLines.forEach { free($0) } }

        let status: project_status_t = cLines.withUnsafeMutableBufferPointer { buf in
            guard let baseAddress = buf.baseAddress, !buf.isEmpty else {
                // Empty buffer — pass nil lines to C API
                var input = project_new_snapshot_t(
                    session_id: nil,
                    kind: kind,
                    cwd: nil,
                    cols: UInt16(snapshot.cols),
                    rows: UInt16(snapshot.rows),
                    lines: nil,
                    line_count: 0
                )
                return sessionID.withCString { idPtr -> project_status_t in
                    input.session_id = idPtr
                    return project_service_record_snapshot(service, &input)
                }
            }

            // Safe: pointer is consumed within withUnsafeMutableBufferPointer scope
            return baseAddress.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { linesPtr in
                var input = project_new_snapshot_t(
                    session_id: nil,
                    kind: kind,
                    cwd: nil,
                    cols: UInt16(snapshot.cols),
                    rows: UInt16(snapshot.rows),
                    lines: linesPtr,
                    line_count: Int32(buf.count)
                )
                return sessionID.withCString { idPtr -> project_status_t in
                    input.session_id = idPtr
                    return project_service_record_snapshot(service, &input)
                }
            }
        }
        guard status == PROJECT_STATUS_OK else { throw projectError(status) }
    }

    private func projectError(_ status: project_status_t) -> Error {
        NSError(domain: "ProjectCore", code: Int(status.rawValue), userInfo: [
            NSLocalizedDescriptionKey: "Project operation failed (code \(status.rawValue))"
        ])
    }
}
