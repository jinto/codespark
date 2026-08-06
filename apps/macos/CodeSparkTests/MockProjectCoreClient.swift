import Foundation
@testable import CodeSpark

final class MockProjectCoreClient: ProjectCoreClientProtocol {
    private let summaries: [ProjectSummaryViewData]
    private var detailsByID: [String: ProjectDetailViewData]
    private let detailErrorsByID: [String: Error]
    private let detailLatencyByID: [String: UInt64]
    private(set) var closedSessionIDs: [String] = []
    private(set) var recordedCwds: [(sessionId: String, cwd: String)] = []
    private(set) var startedSessions: [(initialCwd: String?, workspacePath: String)] = []
    private(set) var savedRestoreSnapshots: [String] = []
    var snapshotsBySessionID: [String: TerminalSnapshotViewData] = [:]
    private(set) var consumedInterruptedSessions: [String] = []
    private(set) var renamedProjects: [(id: String, newName: String)] = []
    private(set) var updatedProjectPaths: [(id: String, newPath: String)] = []
    private(set) var deletedProjectIDs: [String] = []
    private var sessionCounter = 0

    init(
        summaries: [ProjectSummaryViewData],
        details: [ProjectDetailViewData] = [],
        detailErrorsByID: [String: Error] = [:],
        detailLatencyByID: [String: UInt64] = [:]
    ) {
        self.summaries = summaries
        self.detailsByID = Self.makeDetailsMap(details)
        self.detailErrorsByID = detailErrorsByID
        self.detailLatencyByID = detailLatencyByID
    }

    func createProject(name: String, path: String, transport: String) async throws -> String {
        "mock-project-id"
    }

    func startSession(projectId: String, transport: String, targetLabel: String, title: String, shell: String, initialCwd: String?, workspacePath: String) async throws -> String {
        sessionCounter += 1
        startedSessions.append((initialCwd: initialCwd, workspacePath: workspacePath))
        return "mock-session-\(sessionCounter)"
    }

    func listProjectSummaries() async throws -> [ProjectSummaryViewData] {
        summaries
    }

    func projectDetail(id: String) async throws -> ProjectDetailViewData {
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

    func recordFinalSnapshotAndClose(
        sessionID: String,
        snapshot: TerminalSnapshotViewData,
        closeReason: CloseReasonViewData
    ) async throws {
        closedSessionIDs.append(sessionID)
    }

    func reconcileInterruptedSessions() async throws { }

    func recordCheckpointSnapshot(sessionID: String, snapshot: TerminalSnapshotViewData) async throws { }

    func saveSnapshotForRestore(sessionID: String, snapshot: TerminalSnapshotViewData) throws {
        savedRestoreSnapshots.append(sessionID)
    }

    func latestSnapshot(sessionID: String) async throws -> TerminalSnapshotViewData? {
        snapshotsBySessionID[sessionID]
    }

    func updateSessionTitle(sessionId: String, newTitle: String) async throws { }

    func updateSessionCwd(sessionId: String, cwd: String) async throws {
        recordedCwds.append((sessionId: sessionId, cwd: cwd))
    }

    func consumeInterruptedSession(sessionId: String) async throws {
        consumedInterruptedSessions.append(sessionId)
    }

    func renameProject(id: String, newName: String) async throws {
        renamedProjects.append((id: id, newName: newName))
    }

    func updateProjectPath(id: String, newPath: String) async throws {
        updatedProjectPaths.append((id: id, newPath: newPath))
    }

    func deleteProject(id: String) async throws {
        deletedProjectIDs.append(id)
    }

    private static func makeDetailsMap(
        _ details: [ProjectDetailViewData]
    ) -> [String: ProjectDetailViewData] {
        Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
    }

    static func projectWithOneLiveSession() -> MockProjectCoreClient {
        MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(
                    id: "ws-release",
                    name: "release",
                    path: "/tmp/release",
                    transport: "local",
                    liveSessions: 1,
                    recentlyClosedSessions: 0,
                    hasInterruptedSessions: false,
                    liveSessionDetails: []
                )
            ],
            details: [ProjectDetailViewData(
                id: "ws-release",
                name: "release",
                path: "/tmp/release",
                transport: "local",
                liveSessions: [
                    SessionViewData(
                        id: "session-prod",
                        title: "prod logs",
                        targetLabel: "prod",
                        lastCwd: "/srv/app"
                    )
                ],
                interruptedSessions: []
            )]
        )
    }

    static func projectWithInterruptedSession() -> MockProjectCoreClient {
        MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    path: "/Users/jinto/projects/spark3",
                    transport: "local",
                    liveSessions: 0,
                    recentlyClosedSessions: 1,
                    hasInterruptedSessions: true,
                    liveSessionDetails: []
                )
            ],
            details: [ProjectDetailViewData(
                id: "ws-spark3",
                name: "spark3",
                path: "/Users/jinto/projects/spark3",
                transport: "local",
                liveSessions: [],
                interruptedSessions: [
                    SessionSummary(
                        id: "session-interrupted",
                        title: "Terminal",
                        targetLabel: "local",
                        lastCwd: "/Users/jinto/projects/spark3"
                    )
                ]
            )]
        )
    }
}
