import XCTest
@testable import CodeSpark

final class ProjectFlowTests: XCTestCase {
    @MainActor
    func test_closing_a_live_session_removes_it() async {
        let core = MockProjectCoreClient.projectWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: core, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()

        host.finishClose(
            sessionID: "session-prod",
            snapshot: .fixture(lines: ["tail -f log", "error line"]),
            closeReason: .userClosed
        )

        XCTAssertEqual(model.liveSessions.count, 0)
    }

    // MARK: - C-6: liveSessionDetails sync

    @MainActor
    func test_new_session_syncs_project_session_details() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Project", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Project", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()
        XCTAssertEqual(model.projects[0].liveSessionDetails.count, 0)

        await model.newSession()

        XCTAssertEqual(model.projects[0].liveSessionDetails.count, 1)
        XCTAssertEqual(model.projects[0].liveSessions, 1)
    }

    @MainActor
    func test_close_session_syncs_project_session_details() async {
        let core = MockProjectCoreClient.projectWithOneLiveSession()
        let host = MockTerminalHost()
        let model = AppModel(core: core, terminalFactory: { _ in host })

        await model.load()
        await model.attachLiveSessions()
        XCTAssertEqual(model.projects[0].liveSessionDetails.count, 1)

        host.finishClose(sessionID: "session-prod", snapshot: .fixture(lines: []), closeReason: .userClosed)

        XCTAssertEqual(model.projects[0].liveSessionDetails.count, 0)
        XCTAssertEqual(model.projects[0].liveSessions, 0)
    }

    // MARK: - Duplicate cwd crash prevention

    @MainActor
    func test_multiple_sessions_same_cwd_no_crash_on_git_refresh() async {
        let core = MockProjectCoreClient(
            summaries: [
                ProjectSummaryViewData(id: "p1", name: "Project", path: "/tmp/proj", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0, hasInterruptedSessions: false, liveSessionDetails: [])
            ],
            details: [ProjectDetailViewData(id: "p1", name: "Project", path: "/tmp/proj", transport: "local", liveSessions: [])]
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() })

        await model.load()
        // Create 3 sessions — all get same cwd "/tmp/proj"
        await model.newSession()
        await model.newSession()
        await model.newSession()

        XCTAssertEqual(model.liveSessions.count, 3)
        // This must not crash with "Duplicate values for key"
        model.refreshGitBranches()
    }

    // MARK: - Reordering projects by drag

    /// Never `.standard`: the test host shares its defaults domain with the real
    /// app, and these write the developer's own project order and groups.
    private func isolatedDefaults() -> UserDefaults {
        let name = "ProjectFlowTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    private func modelWithProjects(_ ids: [String], defaults: UserDefaults? = nil) async -> AppModel {
        let defaults = defaults ?? isolatedDefaults()
        let core = MockProjectCoreClient(
            summaries: ids.map {
                ProjectSummaryViewData(id: $0, name: $0, path: "/tmp/\($0)", transport: "local",
                                       liveSessions: 0, recentlyClosedSessions: 0,
                                       hasInterruptedSessions: false, liveSessionDetails: [])
            },
            details: ids.map {
                ProjectDetailViewData(id: $0, name: $0, path: "/tmp/\($0)", transport: "local", liveSessions: [])
            }
        )
        let model = AppModel(core: core, terminalFactory: { _ in MockTerminalHost() },
                             defaults: defaults)
        await model.load()
        return model
    }

    @MainActor
    func test_dropping_before_a_project_inserts_there() async {
        let model = await modelWithProjects(["a", "b", "c"])

        model.moveProject(id: "c", to: .before("b"))

        XCTAssertEqual(model.orderedProjects.map(\.id), ["a", "c", "b"])
    }

    @MainActor
    func test_dragging_downwards_lands_above_the_row_it_was_dropped_on() async {
        let model = await modelWithProjects(["a", "b", "c"])

        model.moveProject(id: "a", to: .before("c"))

        XCTAssertEqual(model.orderedProjects.map(\.id), ["b", "a", "c"])
    }

    @MainActor
    func test_dropping_past_the_last_row_moves_a_project_to_the_end() async {
        let model = await modelWithProjects(["a", "b", "c"])

        model.moveProject(id: "a", to: .end)

        XCTAssertEqual(model.orderedProjects.map(\.id), ["b", "c", "a"])
    }

    @MainActor
    func test_dropping_a_project_on_itself_changes_nothing() async {
        let model = await modelWithProjects(["a", "b", "c"])

        model.moveProject(id: "b", to: .before("b"))

        XCTAssertEqual(model.orderedProjects.map(\.id), ["a", "b", "c"])
    }

    @MainActor
    func test_a_reorder_is_remembered_for_the_next_launch() async {
        let defaults = isolatedDefaults()
        let model = await modelWithProjects(["a", "b", "c"], defaults: defaults)

        model.moveProject(id: "a", to: .end)

        XCTAssertEqual(defaults.string(forKey: StorageKeys.projectOrder), "b,c,a")
    }

    // MARK: - Grouping projects

    @MainActor
    func test_a_new_group_takes_the_project_it_was_made_from() async {
        let model = await modelWithProjects(["a", "b"])

        let groupID = model.createGroup(named: "Work", with: "b")

        XCTAssertEqual(model.projectGroups.groups.map(\.name), ["Work"])
        XCTAssertEqual(model.projectGroups.groupID(of: "b"), groupID)
        XCTAssertNil(model.projectGroups.groupID(of: "a"), "the rest stay in the default group")
    }

    /// Dropping above a row means "here" — and here is that row's group.
    @MainActor
    func test_dropping_before_a_grouped_project_files_it_in_that_group() async {
        let model = await modelWithProjects(["a", "b", "c"])
        let groupID = model.createGroup(named: "Work", with: "a")

        // Filing "a" put it last in the one order: b, c, a.
        model.moveProject(id: "c", to: .before("a"))

        XCTAssertEqual(model.projectGroups.groupID(of: "c"), groupID)
        XCTAssertEqual(model.orderedProjects.map(\.id), ["b", "c", "a"])
    }

    /// The space under the list belongs to the default group, which draws last.
    @MainActor
    func test_dropping_past_the_last_row_takes_a_project_out_of_its_group() async {
        let model = await modelWithProjects(["a", "b"])
        model.createGroup(named: "Work", with: "a")

        model.moveProject(id: "a", to: .end)

        XCTAssertNil(model.projectGroups.groupID(of: "a"))
    }

    /// Dropped on a header, a project goes in last.
    @MainActor
    func test_dropping_on_a_group_header_files_the_project_at_its_end() async {
        let model = await modelWithProjects(["a", "b", "c"])
        let groupID = model.createGroup(named: "Work", with: "c")

        model.moveProject(id: "a", to: .group(groupID))

        XCTAssertEqual(model.projectGroups.groupID(of: "a"), groupID)
        XCTAssertEqual(model.orderedProjects.map(\.id), ["b", "c", "a"])
    }

    /// Deleting a group deletes a label, never a project.
    @MainActor
    func test_deleting_a_group_returns_its_projects_to_the_default_group() async {
        let model = await modelWithProjects(["a", "b"])
        let groupID = model.createGroup(named: "Work", with: "a")

        model.deleteGroup(id: groupID)

        XCTAssertTrue(model.projectGroups.groups.isEmpty)
        XCTAssertNil(model.projectGroups.groupID(of: "a"))
        XCTAssertEqual(Set(model.orderedProjects.map(\.id)), ["a", "b"])
    }

    @MainActor
    func test_groups_are_remembered_for_the_next_launch() async {
        let defaults = isolatedDefaults()
        let first = await modelWithProjects(["a", "b"], defaults: defaults)
        let groupID = first.createGroup(named: "Work", with: "b")
        first.renameGroup(id: groupID, to: "Clients")
        first.toggleGroupCollapsed(id: groupID)

        let next = await modelWithProjects(["a", "b"], defaults: defaults)

        XCTAssertEqual(next.projectGroups.groups,
                       [ProjectGroups.Group(id: groupID, name: "Clients", isCollapsed: true)])
        XCTAssertEqual(next.projectGroups.groupID(of: "b"), groupID)
    }

    @MainActor
    func test_moving_a_group_changes_only_the_group_order() async {
        let model = await modelWithProjects(["a", "b"])
        let work = model.createGroup(named: "Work", with: "a")
        let side = model.createGroup(named: "Side", with: "b")

        model.moveGroup(id: side, by: -1)
        XCTAssertEqual(model.projectGroups.groups.map(\.id), [side, work])

        model.moveGroup(id: side, by: -1)
        XCTAssertEqual(model.projectGroups.groups.map(\.id), [side, work], "the top stays put")
    }
}
