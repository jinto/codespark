import XCTest
@testable import CodeSpark

/// The sidebar, tested with no `AppModel`, no main actor, and no git.
///
/// That is the point of the snapshot: what a row says was a method on a live
/// model reading live state, so every question about it needed an app to be
/// running. Here the state is an argument.
final class SidebarPresenterTests: XCTestCase {

    // MARK: - Fixtures

    private func project(
        _ id: String,
        path: String,
        transport: String = "local",
        sessions: [SessionSummary] = [],
        interrupted: Bool = false
    ) -> ProjectSummaryViewData {
        ProjectSummaryViewData(
            id: id, name: id, path: path, transport: transport,
            liveSessions: sessions.count, recentlyClosedSessions: 0,
            hasInterruptedSessions: interrupted, liveSessionDetails: sessions
        )
    }

    private func session(_ id: String, in workspacePath: String) -> SessionSummary {
        SessionSummary(id: id, title: id, targetLabel: "local", lastCwd: workspacePath,
                       workspacePath: workspacePath)
    }

    private static let main = "/tmp/repo"
    private static let feature = "/tmp/repo-feature"
    private static let idle = "/tmp/repo-idle"

    private func threeWorktrees() -> [GitWorktree] {
        [GitWorktree(path: Self.main, branch: "main", isMainWorktree: true),
         GitWorktree(path: Self.feature, branch: "feature", isMainWorktree: false),
         GitWorktree(path: Self.idle, branch: "idle", isMainWorktree: false)]
    }

    // MARK: - Rows

    func test_a_repo_with_one_worktree_draws_no_child_rows() {
        let p = project("p", path: Self.main)
        let snapshot = SidebarSnapshot(
            projects: [p],
            worktreesByPath: [Self.main: [GitWorktree(path: Self.main, branch: "main",
                                                      isMainWorktree: true)]],
            expandedProjectIDs: ["p"]
        )

        let groups = SidebarPresenter.groups(snapshot)

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].worktrees.isEmpty,
                      "the project row already is that worktree; a lone \"main\" child is noise")
        XCTAssertEqual(groups[0].foldedCount, 0)
        XCTAssertEqual(groups[0].infoLine, nil,
                       "one worktree is no scale to report, and git has said nothing about a branch")
    }

    func test_a_worktree_with_no_tabs_folds_but_main_never_does() {
        let p = project("p", path: Self.main, sessions: [session("s1", in: Self.feature)])
        let snapshot = SidebarSnapshot(
            projects: [p],
            worktreesByPath: [Self.main: threeWorktrees()],
            expandedProjectIDs: ["p"]
        )

        let group = SidebarPresenter.groups(snapshot)[0]

        XCTAssertEqual(group.worktrees.map(\.workspace.path), [Self.main, Self.feature],
                       "main stays whatever happens, and a worktree with tabs is where the work is")
        XCTAssertEqual(group.foldedCount, 1, "the idle worktree folds behind a count")
        XCTAssertEqual(group.infoLine, "3 worktrees",
                       "open, the branch is the main row's to say and this line keeps the scale")
    }

    func test_a_folded_project_says_its_branch_and_its_scale() {
        let p = project("p", path: Self.main)
        let snapshot = SidebarSnapshot(
            projects: [p],
            worktreesByPath: [Self.main: threeWorktrees()],
            gitBranches: [Self.main: "main"]
        )

        let group = SidebarPresenter.groups(snapshot)[0]

        XCTAssertTrue(group.worktrees.isEmpty, "a shut tree draws no children")
        XCTAssertEqual(group.infoLine, "main · 3 worktrees")
    }

    /// git is asked under the one spelling of an address, so the answer comes
    /// back filed under that spelling. A project added as `/private/tmp/repo`
    /// reads its own row under the same key or its subtitle goes blank — the
    /// branch, and "non-git" with it.
    func test_a_branch_is_found_however_the_project_spelled_its_path() {
        let p = project("p", path: "/private/tmp/repo")
        var snapshot = SidebarSnapshot(projects: [p], gitBranches: ["/tmp/repo": "main"])

        XCTAssertEqual(SidebarPresenter.groups(snapshot)[0].infoLine, "main")

        snapshot.gitBranches = [:]
        snapshot.nonGitProjectPaths = ["/tmp/repo"]
        XCTAssertEqual(SidebarPresenter.groups(snapshot)[0].infoLine, "non-git")
    }

    func test_a_folder_that_is_no_repository_says_so_only_once_asked() {
        let p = project("p", path: "/tmp/plain")
        var snapshot = SidebarSnapshot(projects: [p])

        XCTAssertNil(SidebarPresenter.groups(snapshot)[0].infoLine,
                     "\"non-git\" before asking would be a guess")

        snapshot.nonGitProjectPaths = ["/tmp/plain"]
        XCTAssertEqual(SidebarPresenter.groups(snapshot)[0].infoLine, "non-git")
    }

    func test_a_remote_row_leads_with_the_branch_and_trails_the_host() {
        let uri = "ssh://box/srv/repo"
        let p = project("p", path: uri, transport: "ssh")
        var snapshot = SidebarSnapshot(projects: [p])

        XCTAssertEqual(SidebarPresenter.groups(snapshot)[0].infoLine, "box",
                       "before the scan lands there is no branch to name")

        snapshot.worktreesByPath = [uri: [GitWorktree(path: uri, branch: "main",
                                                      isMainWorktree: true)]]
        XCTAssertEqual(SidebarPresenter.groups(snapshot)[0].infoLine, "main on box")
    }

    // MARK: - Whose grouping is whose

    /// The fault the whole snapshot exists to make unwriteable: the live
    /// grouping belongs to one project, and handing it to another draws that
    /// project wearing worktrees that are not its own.
    func test_only_the_project_the_live_grouping_belongs_to_reads_it() {
        let onScreen = project("on-screen", path: Self.main)
        let other = project("other", path: "/tmp/other")
        let snapshot = SidebarSnapshot(
            projects: [onScreen, other],
            onScreenProjectID: "on-screen",
            liveWorkspaces: [
                WorkspaceViewData(path: Self.main, branch: "main", isMainWorktree: true,
                                  sessions: [session("s1", in: Self.main)]),
                WorkspaceViewData(path: Self.feature, branch: "feature", isMainWorktree: false,
                                  sessions: [session("s2", in: Self.feature)])
            ],
            expandedProjectIDs: ["on-screen", "other"]
        )

        let groups = SidebarPresenter.groups(snapshot)

        XCTAssertEqual(groups[0].worktrees.count, 2)
        XCTAssertTrue(groups[1].worktrees.isEmpty,
                      "a project wore the worktrees of the one the grouping belongs to")
    }

    // MARK: - Digits

    func test_digits_land_where_the_tabs_are() {
        let flat = project("flat", path: "/tmp/flat")
        let repo = project("repo", path: Self.main, sessions: [session("s1", in: Self.feature)])
        let snapshot = SidebarSnapshot(
            projects: [flat, repo],
            worktreesByPath: [Self.main: threeWorktrees()]
        )

        let groups = SidebarPresenter.groups(snapshot)

        XCTAssertEqual(groups[0].hotkeyIndex, 1,
                       "a project with no tabs is addressed as itself — it is where you go to open one")
        XCTAssertEqual(groups[1].hotkeyIndex, 2,
                       "folded, the project row stands in for the first digit inside it")
        XCTAssertEqual(SidebarPresenter.numberedPlaces(snapshot), [
            .project("flat"),
            .worktree(projectID: "repo", path: Self.feature)
        ])
    }

    func test_an_open_project_gives_its_badge_to_the_row_that_is_on_screen() {
        let repo = project("repo", path: Self.main, sessions: [session("s1", in: Self.feature)])
        let snapshot = SidebarSnapshot(
            projects: [repo],
            worktreesByPath: [Self.main: threeWorktrees()],
            expandedProjectIDs: ["repo"]
        )

        let group = SidebarPresenter.groups(snapshot)[0]

        XCTAssertNil(group.hotkeyIndex, "the worktree row is on screen and wears the digit")
        XCTAssertEqual(
            group.worktrees.first { $0.workspace.path == Self.feature }?.hotkeyIndex, 1)
    }

    /// Folding must not shuffle the digits out from under the user's fingers.
    func test_folding_a_tree_does_not_move_a_digit() {
        let repo = project("repo", path: Self.main, sessions: [session("s1", in: Self.feature)])
        let after = project("after", path: "/tmp/after")
        var snapshot = SidebarSnapshot(
            projects: [repo, after],
            worktreesByPath: [Self.main: threeWorktrees()],
            expandedProjectIDs: ["repo"]
        )
        let open = SidebarPresenter.numberedPlaces(snapshot)

        snapshot.expandedProjectIDs = []

        XCTAssertEqual(SidebarPresenter.numberedPlaces(snapshot), open)
    }

    // MARK: - Paths

    func test_only_the_main_worktree_carries_a_path_and_a_uri_is_not_one() {
        let local = WorkspaceViewData(path: Self.main, branch: "main", isMainWorktree: true,
                                      sessions: [])
        let linked = WorkspaceViewData(path: Self.feature, branch: "feature",
                                       isMainWorktree: false, sessions: [])

        XCTAssertEqual(SidebarPresenter.pathLine(for: local), Self.main)
        XCTAssertNil(SidebarPresenter.pathLine(for: linked),
                     "a linked worktree's directory is named after the branch the row already says")
        XCTAssertEqual(SidebarPresenter.displayPath(for: "ssh://box/srv/repo"), "/srv/repo",
                       "a URI is not a filesystem path — tilde abbreviation eats its slashes")
    }

    // MARK: - The gate

    /// The single-project answers are for callers holding one project — the
    /// menu, and the tests above's siblings. A *view* asking them is the shape
    /// this refactoring removed: each one rebuilds a grouping, so a row that
    /// asks four of them regroups its project's sessions four times, times the
    /// number of rows, on every `@Published` change — which includes the OSC 7
    /// report a shell sends at every prompt. Typing `ls` redrew the sidebar.
    ///
    /// So views take `sidebarGroups`, once per body. Nothing about that is
    /// visible in a rendered view or a value read back from the model, which is
    /// why the gate reads the source — the same kind as the ban on inline
    /// `keyboardShortcut("…")` and on labels that reweight themselves.
    func test_no_view_asks_the_model_about_one_row_at_a_time() throws {
        let perRow = [
            "projectStatus(for:", "workspaceStatus(for:", "projectInfoLine(for:",
            "worktreeCount(for:", "showsWorktreeRows(for:", "sidebarWorktreeRows(for:",
            "sidebarWorktrees(for:", "workspaces(for:", "worktreePathLine(for:",
            "numberedBadges"
        ]
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodeSpark/Views")

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        XCTAssertFalse(files.isEmpty, "the gate found no views to check — it has gone blind")

        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                // Prose may name these; only a call is the fault.
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                for call in perRow where line.contains("." + call) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)  "
                        + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "A view asked the model row by row. Each of these rebuilds a grouping; "
                + "take `model.sidebarGroups` once per body instead:\n"
                + offenders.joined(separator: "\n")
        )
    }
}
