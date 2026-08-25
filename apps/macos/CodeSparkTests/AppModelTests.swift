import XCTest
@testable import CodeSpark

final class AppModelTests: XCTestCase {
    @MainActor
    func test_loads_project_summaries_and_selects_first() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "/tmp/release", transport: "local", liveSessions: 1, recentlyClosedSessions: 1, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-release",
                name: "release",
                path: "/tmp/release",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()

        XCTAssertEqual(model.projects.map(\.name), ["release"])
        XCTAssertEqual(model.selectedProjectID, "ws-release")
        XCTAssertNil(model.loadErrorMessage)
    }

    @MainActor
    func test_select_project_loads_requested_detail() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "", transport: "local", liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-spark3", name: "spark3", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 1, hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "ws-release",
                    name: "release",
                    path: "",
                    transport: "local",
                    liveSessions: []
                ),
                ProjectDetailViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    path: "",
                    transport: "local",
                    liveSessions: []
                )
            ]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.selectProject(id: "ws-spark3")

        XCTAssertEqual(model.selectedProject?.id, "ws-spark3")
        XCTAssertEqual(model.selectedProjectID, "ws-spark3")
        XCTAssertNil(model.loadErrorMessage)
    }

    @MainActor
    func test_latest_project_selection_wins_when_detail_requests_finish_out_of_order() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "", transport: "local", liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-spark3", name: "spark3", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 1, hasInterruptedSessions: true, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "ws-release",
                    name: "release",
                    path: "",
                    transport: "local",
                    liveSessions: []
                ),
                ProjectDetailViewData(
                    id: "ws-spark3",
                    name: "spark3",
                    path: "",
                    transport: "local",
                    liveSessions: []
                )
            ],
            detailLatencyByID: ["ws-release": 200_000_000]
        )
        let model = AppModel(core: client)

        await model.load()

        let firstSelection = Task { await model.selectProject(id: "ws-release") }
        let secondSelection = Task { await model.selectProject(id: "ws-spark3") }
        await firstSelection.value
        await secondSelection.value

        XCTAssertEqual(model.selectedProjectID, "ws-spark3")
        XCTAssertEqual(model.selectedProject?.id, "ws-spark3")
    }

    @MainActor
    func test_detail_fetch_failure_clears_stale_detail_state() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "", transport: "local", liveSessions: 1, recentlyClosedSessions: 1, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-release",
                name: "release",
                path: "",
                transport: "local",
                liveSessions: []
            )],
            detailErrorsByID: ["ws-release": CocoaError(.fileReadUnknown)]
        )
        let model = AppModel(core: client)
        model.selectedProjectID = "stale-project"
        model.selectedProject = ProjectDetailViewData(
            id: "stale-project",
            name: "stale",
            path: "",
            transport: "local",
            liveSessions: []
        )
        model.liveSessions = [.fixture()]

        await model.load()

        XCTAssertEqual(model.projects.map(\.id), ["ws-release"])
        XCTAssertEqual(model.selectedProjectID, "ws-release")
        XCTAssertNil(model.selectedProject)
        XCTAssertEqual(model.liveSessions, [])
        XCTAssertNotNil(model.loadErrorMessage)
    }

    @MainActor
    func test_rename_project_updates_name_in_list() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-release", name: "release", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-release",
                name: "release",
                path: "",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.renameProject(id: "ws-release", newName: "renamed-release")

        XCTAssertEqual(model.projects[0].name, "renamed-release")
    }

    @MainActor
    func test_create_project_inserts_below_active() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "Project 1", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-2", name: "Project 2", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [
                ProjectDetailViewData(
                    id: "ws-1",
                    name: "Project 1",
                    path: "",
                    transport: "local",
                    liveSessions: []
                ),
                ProjectDetailViewData(
                    id: "mock-project-id",
                    name: "Project 3",
                    path: "",
                    transport: "local",
                    liveSessions: []
                )
            ]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.selectProject(id: "ws-1")
        await model.createProject(name: "Project 3")

        XCTAssertEqual(model.projects.map(\.id), ["ws-1", "ws-2", "mock-project-id"])
        XCTAssertEqual(model.projects[2].name, "Project 3")
    }

    @MainActor
    func test_create_project_opens_initial_terminal() async {
        let client = MockProjectCoreClient(
            summaries: [],
            details: [
                ProjectDetailViewData(
                    id: "mock-project-id",
                    name: "NewProj",
                    path: "/tmp/newproj",
                    transport: "local",
                    liveSessions: []
                )
            ]
        )
        let model = AppModel(core: client, terminalFactory: { _ in MockTerminalHost() })

        await model.load()
        await model.createProject(name: "NewProj", path: "/tmp/newproj")

        XCTAssertEqual(model.selectedProjectID, "mock-project-id")
        XCTAssertNotNil(model.selectedProject, "selectedProject should be set after selectProject")
        XCTAssertEqual(model.liveSessions.count, 1, "New project should auto-create one terminal session (liveSessions=\(model.liveSessions.count), selectedProject=\(model.selectedProject?.name ?? "nil"))")
        XCTAssertNotNil(model.activeSessionID, "Active session should be set")
    }

    @MainActor
    func test_delete_project_removes_from_list() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "Project 1", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-2", name: "Project 2", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-1",
                name: "Project 1",
                path: "",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.deleteProject(id: "ws-2")

        XCTAssertEqual(model.projects.count, 1)
    }

    @MainActor
    func test_select_project_forces_activeWorkspacePath_to_project_path() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "proj-1", name: "MyProject", path: "/tmp/myproject", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "proj-1",
                name: "MyProject",
                path: "/tmp/myproject",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.selectProject(id: "proj-1")

        XCTAssertEqual(model.activeWorkspacePath, "/tmp/myproject",
                        "activeWorkspacePath must equal project.path after selection")
    }

    @MainActor
    func test_new_session_uses_project_path_as_cwd() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "proj-1", name: "MyProject", path: "/tmp/myproject", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "proj-1",
                name: "MyProject",
                path: "/tmp/myproject",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client, terminalFactory: { _ in MockTerminalHost() })

        await model.load()
        await model.selectProject(id: "proj-1")
        await model.newSession()

        XCTAssertEqual(model.activeWorkspacePath, "/tmp/myproject",
                        "activeWorkspacePath should remain project.path after newSession")
    }

    @MainActor
    func test_close_project_hides_from_list() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "Project 1", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-2", name: "Project 2", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-1",
                name: "Project 1",
                path: "",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        await model.closeProject(id: "ws-2")

        XCTAssertEqual(model.projects.count, 1)
        XCTAssertTrue(model.hiddenProjectIDs.contains("ws-2"))
    }

    // MARK: - projectStatus

    @MainActor
    func test_project_status_idle_when_no_live_sessions() async {
        let project = ProjectSummaryViewData(
            id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
            liveSessions: 0, recentlyClosedSessions: 0,
            hasInterruptedSessions: false, liveSessionDetails: []
        )
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []))
        XCTAssertEqual(model.projectStatus(for: project), .idle)
    }

    @MainActor
    func test_project_status_interrupted_when_no_live_sessions() async {
        let project = ProjectSummaryViewData(
            id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
            liveSessions: 0, recentlyClosedSessions: 0,
            hasInterruptedSessions: true, liveSessionDetails: []
        )
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []))
        XCTAssertEqual(model.projectStatus(for: project), .interrupted)
    }

    @MainActor
    func test_project_status_running_with_live_sessions() async {
        let project = ProjectSummaryViewData(
            id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
            liveSessions: 1, recentlyClosedSessions: 0,
            hasInterruptedSessions: false,
            liveSessionDetails: [SessionSummary(id: "s1", title: "T", targetLabel: "local", lastCwd: "/tmp/proj")]
        )
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []))
        XCTAssertEqual(model.projectStatus(for: project), .running)
    }

    @MainActor
    func test_project_status_needs_input_when_live_and_interrupted() async {
        let project = ProjectSummaryViewData(
            id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
            liveSessions: 1, recentlyClosedSessions: 0,
            hasInterruptedSessions: true,
            liveSessionDetails: [SessionSummary(id: "s1", title: "T", targetLabel: "local", lastCwd: "/tmp/proj")]
        )
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []))
        XCTAssertEqual(model.projectStatus(for: project), .needsInput)
    }

    @MainActor
    func test_project_status_idle_when_all_sessions_idle() async {
        let project = ProjectSummaryViewData(
            id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
            liveSessions: 1, recentlyClosedSessions: 0,
            hasInterruptedSessions: false,
            liveSessionDetails: [SessionSummary(id: "s1", title: "T", targetLabel: "local", lastCwd: "/tmp/proj")]
        )
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []))
        model.sessionStates["s1"] = .idle
        XCTAssertEqual(model.projectStatus(for: project), .idle)
    }

    @MainActor
    func test_project_status_needsInput_from_session_state() async {
        let project = ProjectSummaryViewData(
            id: "p1", name: "Proj", path: "/tmp/proj", transport: "local",
            liveSessions: 1, recentlyClosedSessions: 0,
            hasInterruptedSessions: false,
            liveSessionDetails: [SessionSummary(id: "s1", title: "T", targetLabel: "local", lastCwd: "/tmp/proj")]
        )
        let model = AppModel(core: MockProjectCoreClient(summaries: [], details: []))
        model.sessionStates["s1"] = .needsInput
        XCTAssertEqual(model.projectStatus(for: project), .needsInput)
    }

    func test_status_color_mapping() {
        XCTAssertEqual(ProjectStatus.idle.color, .gray)
        XCTAssertEqual(ProjectStatus.running.color, .green)
        XCTAssertEqual(ProjectStatus.needsInput.color, .orange)
    }

    @MainActor
    func test_close_session_removes_from_live_sessions() async {
        let client = MockProjectCoreClient.projectWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: client, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()
        model.closeSession(id: "session-prod")
        host.finishClose(
            sessionID: "session-prod",
            snapshot: .fixture(lines: ["tail -f log"]),
            closeReason: .userClosed
        )

        XCTAssertFalse(model.liveSessions.contains(where: { $0.id == "session-prod" }))
    }

    @MainActor
    func test_pending_close_session_id_triggers_close_flow() async {
        let client = MockProjectCoreClient.projectWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: client, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()
        model.pendingCloseSessionID = "session-prod"
        model.closeSession(id: "session-prod")
        host.finishClose(
            sessionID: "session-prod",
            snapshot: .fixture(lines: ["tail -f log"]),
            closeReason: .userClosed
        )

        XCTAssertFalse(model.liveSessions.contains(where: { $0.id == "session-prod" }))
    }

    @MainActor
    func test_pending_close_project_id_triggers_close_flow() async {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "Project 1", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: []),
                ProjectSummaryViewData(id: "ws-2", name: "Project 2", path: "", transport: "local", liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-1",
                name: "Project 1",
                path: "",
                transport: "local",
                liveSessions: []
            )]
        )
        let model = AppModel(core: client)

        await model.load()
        model.pendingCloseProjectID = "ws-2"
        await model.closeProject(id: "ws-2")

        XCTAssertTrue(model.hiddenProjectIDs.contains("ws-2"))
    }

    @MainActor
    private func modelWithLiveSession() async -> (AppModel, MockProjectCoreClient) {
        let client = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "ws-1", name: "codespark", path: "/Users/me/codespark", transport: "local", liveSessions: 1, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(
                id: "ws-1",
                name: "codespark",
                path: "/Users/me/codespark",
                transport: "local",
                liveSessions: [SessionViewData(id: "session-1", title: "Terminal", targetLabel: "local", lastCwd: "/Users/me")]
            )]
        )
        let model = AppModel(core: client)
        await model.load()
        return (model, client)
    }

    @MainActor
    func test_cwd_report_updates_session_in_memory() async {
        let (model, _) = await modelWithLiveSession()

        model.sessionDidReportCwd(sessionID: "session-1", cwd: "/Users/me/projects/codespark")

        XCTAssertEqual(model.liveSessions.first?.lastCwd, "/Users/me/projects/codespark")
    }

    @MainActor
    func test_cwd_report_persists_to_core() async {
        let (model, client) = await modelWithLiveSession()

        model.sessionDidReportCwd(sessionID: "session-1", cwd: "/Users/me/projects/codespark")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.recordedCwds.first?.sessionId, "session-1")
        XCTAssertEqual(client.recordedCwds.first?.cwd, "/Users/me/projects/codespark")
    }

    @MainActor
    func test_repeated_cwd_report_with_same_value_is_not_persisted_twice() async {
        let (model, client) = await modelWithLiveSession()

        // OSC 7 fires on every prompt; only real directory changes should hit the store.
        model.sessionDidReportCwd(sessionID: "session-1", cwd: "/Users/me/projects/codespark")
        model.sessionDidReportCwd(sessionID: "session-1", cwd: "/Users/me/projects/codespark")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.recordedCwds.count, 1)
    }

    @MainActor
    func test_cwd_report_for_unknown_session_is_ignored() async {
        let (model, client) = await modelWithLiveSession()

        model.sessionDidReportCwd(sessionID: "ghost-session", cwd: "/tmp")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(client.recordedCwds.isEmpty)
    }

    // MARK: - Destructive confirmation copy

    /// Deleting a project unregisters it — the SQLite row and its session
    /// history — and never touches the filesystem. The old copy said only
    /// "permanently delete", which reads like the folder goes too.
    ///
    /// Asserted whole rather than by keyword: here the sentence *is* the
    /// feature, and a fragment check passes on copy that has lost the half that
    /// matters.
    @MainActor
    func test_delete_project_copy_says_files_on_disk_survive() {
        let model = AppModel(core: MockProjectCoreClient(summaries: []))

        XCTAssertEqual(
            model.deleteProjectMessage(name: "nightly"),
            "This will permanently delete \"nightly\" and all its sessions. "
                + "Files on disk are not affected."
        )
    }

    /// Removing a worktree runs `git worktree remove`, which does delete the
    /// directory. Say so with the word the user is afraid of.
    @MainActor
    func test_remove_worktree_copy_says_the_folder_is_deleted_from_disk() {
        let model = AppModel(core: MockProjectCoreClient(summaries: []))

        XCTAssertEqual(
            model.removeWorktreeMessage(path: "/Volumes/work/worktrees/feature"),
            "Its tabs will close and the folder /Volumes/work/worktrees/feature "
                + "will be deleted from disk. The branch itself stays."
        )
    }

    /// The path in the message is the one the sidebar shows, so it goes through
    /// `displayPath`: home collapses to `~`, and a remote worktree reads as the
    /// directory on the other machine rather than as its `ssh://` URI.
    @MainActor
    func test_remove_worktree_copy_spells_the_path_the_way_the_sidebar_does() {
        let model = AppModel(core: MockProjectCoreClient(summaries: []))

        let home = model.removeWorktreeMessage(
            path: NSHomeDirectory() + "/worktrees/feature")
        XCTAssertTrue(home.contains("the folder ~/worktrees/feature will be"), home)

        let remote = model.removeWorktreeMessage(path: "ssh://localhost/srv/repo-feature")
        XCTAssertTrue(remote.contains("the folder /srv/repo-feature will be"), remote)
    }

    /// The two tests above read the model, and the model is not what the user
    /// sees. Nothing in them notices a dialog that goes back to spelling its own
    /// copy inline — the strings in a view body are invisible to every test we
    /// can run, so the gate has to be the source itself.
    func test_destructive_dialogs_read_their_copy_from_the_model() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CodeSparkTests
            .deletingLastPathComponent()  // macos
            .appendingPathComponent("CodeSpark/Views")
        let sidebar = try String(
            contentsOf: views.appendingPathComponent("SidebarView.swift"), encoding: .utf8)

        XCTAssertTrue(sidebar.contains("model.deleteProjectMessage(name:"), "SidebarView.swift")
        XCTAssertTrue(sidebar.contains("model.removeWorktreeMessage(path:"), "SidebarView.swift")

        // The phrases only the model may own. A reverted wiring brings them
        // back into a view body, and this is what notices.
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for phrase in ["permanently delete", "will be deleted"] where source.contains(phrase) {
                offenders.append("\(file.lastPathComponent): \(phrase)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "삭제 다이얼로그 문구는 AppModel이 갖는다. 뷰에 다시 쓰면 테스트가 못 읽는다:\n"
                + offenders.joined(separator: "\n"))
    }
}
