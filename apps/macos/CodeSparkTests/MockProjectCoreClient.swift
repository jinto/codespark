import Foundation
@testable import CodeSpark

final class MockProjectCoreClient: ProjectCoreClientProtocol {
    private let summaries: [ProjectSummaryViewData]
    private var detailsByID: [String: ProjectDetailViewData]
    private let detailErrorsByID: [String: Error]
    private let detailLatencyByID: [String: UInt64]
    private let noteUpdateError: Error?
    private let noteUpdateLatency: UInt64?
    private(set) var closedSessionIDs: [String] = []
    private(set) var renamedProjects: [(id: String, newName: String)] = []
    private(set) var deletedProjectIDs: [String] = []
    private var sessionCounter = 0

    init(
        summaries: [ProjectSummaryViewData],
        details: [ProjectDetailViewData] = [],
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

    func createProject(name: String) async throws -> String {
        "mock-project-id"
    }

    func startSession(projectId: String, transport: String, targetLabel: String, title: String, shell: String, initialCwd: String?) async throws -> String {
        sessionCounter += 1
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

    func updateProjectNote(id: String, noteBody: String) async throws {
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

    func reconcileInterruptedSessions() async throws { }

    func recordCheckpointSnapshot(sessionID: String, snapshot: TerminalSnapshotViewData) async throws { }

    func updateSessionTitle(sessionId: String, newTitle: String) async throws { }

    func renameProject(id: String, newName: String) async throws {
        renamedProjects.append((id: id, newName: newName))
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
                    liveSessions: 1,
                    recentlyClosedSessions: 0,
                    hasInterruptedSessions: false,
                    liveSessionDetails: []
                )
            ],
            details: [ProjectDetailViewData(
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

    static func projectWithInterruptedSession() -> MockProjectCoreClient {
        MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    liveSessions: 0,
                    recentlyClosedSessions: 1,
                    hasInterruptedSessions: true,
                    liveSessionDetails: []
                )
            ],
            details: [ProjectDetailViewData(
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
