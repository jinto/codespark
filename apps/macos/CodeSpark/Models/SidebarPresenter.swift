import Foundation

/// Everything the sidebar reads, copied out of the model once.
///
/// The sidebar used to ask the model a question per row per field, and each
/// answer went back to live state for itself: drawing one project regrouped its
/// sessions four times over — once for the status dot, once for the info line's
/// worktree count, once to ask whether the tree is open, once to draw it. On
/// every `@Published` change, which includes the cwd report a shell sends at
/// every prompt.
///
/// Copying the state out first is what makes one pass possible, and it is also
/// what makes the answers testable: `SidebarPresenter` needs no `AppModel`, no
/// main actor, and no git.
struct SidebarSnapshot: Equatable {
    var projects: [ProjectSummaryViewData] = []

    /// The project the live grouping below belongs to — `Selection.onScreen`,
    /// which during a switch is still the project being left. Reading it off the
    /// *chosen* id instead is what used to hand one project's worktrees to
    /// another for the length of a lookup.
    var onScreenProjectID: String?

    /// What the user picked, which is what a row draws as selected. It moves on
    /// the click, ahead of the grouping — deliberately: the row must highlight
    /// under the finger, not a round trip later.
    var selectedProjectID: String?

    var activeWorkspacePath: String?

    /// The live grouping. Belongs to `onScreenProjectID` and to nobody else.
    var liveWorkspaces: [WorkspaceViewData] = []

    /// git's answer per project path. A path missing here has not been answered
    /// yet, which is not the same as a project with no worktrees: a count we do
    /// not have is left off the row, the way "non-git" waits for its lookup
    /// rather than guessing.
    var worktreesByPath: [String: [GitWorktree]] = [:]

    var sessionStates: [String: TerminalState] = [:]
    var gitBranches: [String: String] = [:]
    var nonGitProjectPaths: Set<String> = []
    var expandedProjectIDs: Set<String> = []
    var projectsShowingEveryWorktree: Set<String> = []
    var projectSelectedWorkspaces: [String: String] = [:]
}

/// One project's rows: the project itself, whatever worktrees are drawn under
/// it, and how many were folded away. Shaped like the sidebar rather than
/// flattened, because that is the shape the drag targets and context menus hang
/// on — a project row owns its children.
struct SidebarProjectGroup: Identifiable, Equatable {
    let project: ProjectSummaryViewData
    let isSelected: Bool
    let status: ProjectStatus
    let infoLine: String?
    let hotkeyIndex: Int?
    /// The tab total the project row wears — nil while worktree rows are shown,
    /// because every one of those tabs is then on screen with its own count and
    /// the heading repeating the sum counts them twice down one column.
    let sessionCount: Int?
    let worktrees: [SidebarWorktreeRow]
    let foldedCount: Int
    /// The project's directory, for hover — a path takes no row space anywhere.
    let hoverPath: String

    var id: String { project.id }
}

struct SidebarWorktreeRow: Identifiable, Equatable {
    let workspace: WorkspaceViewData
    let isSelected: Bool
    let status: ProjectStatus
    let hotkeyIndex: Int?
    /// Every row offers its directory on hover, the main worktree included —
    /// the second line only it used to carry made it the one row with a
    /// different height. Its identity is worn as a mark instead
    /// (`workspace.isMainWorktree`), which survives any checked-out branch.
    let hoverPath: String

    var id: String { workspace.id }
}

/// The sidebar's whole vocabulary, as functions of a snapshot and nothing else.
///
/// Nineteen of this repository's roughly sixty `fix:` commits landed in
/// `AppModel.swift` and fifteen more in `SidebarView.swift`, almost all
/// answering one question: *which row does this tab, or this string, belong
/// to?* The question now has one place to be answered, and answering it needs
/// no running app.
enum SidebarPresenter {

    /// Every row on the sidebar, worked out in a single pass.
    ///
    /// The grouping each project needs is computed once here and then read by
    /// the status dot, the info line, the fold, and the digits alike. The digits
    /// in particular used to rebuild the entire numbering per row, which made
    /// drawing N projects cost N² groupings; they are now just an index into a
    /// list this pass has already built.
    static func groups(_ snapshot: SidebarSnapshot) -> [SidebarProjectGroup] {
        let grouped = snapshot.projects.map { project in
            (project: project, workspaces: worktreeRows(of: project, in: snapshot))
        }
        let places = numberedPlaces(grouped)
        let badges = badges(places, grouped: grouped, in: snapshot)

        return grouped.map { project, all in
            let folded = fold(all, of: project, in: snapshot)
            let showsRows = snapshot.expandedProjectIDs.contains(project.id) && !all.isEmpty
            return SidebarProjectGroup(
                project: project,
                isSelected: snapshot.selectedProjectID == project.id,
                status: status(of: project, in: snapshot),
                infoLine: infoLine(for: project, worktreeRowsShown: showsRows, in: snapshot),
                hotkeyIndex: badges.byProject[project.id],
                sessionCount: showsRows || project.liveSessions == 0
                    ? nil : project.liveSessions,
                worktrees: showsRows ? folded.shown.map { workspace in
                    SidebarWorktreeRow(
                        workspace: workspace,
                        isSelected: snapshot.selectedProjectID == project.id
                            && snapshot.activeWorkspacePath == workspace.path,
                        status: status(of: workspace, in: snapshot),
                        hotkeyIndex: badges.byWorktree[
                            NumberedPlace.worktree(projectID: project.id, path: workspace.path)
                        ],
                        hoverPath: displayPath(for: workspace.path)
                    )
                } : [],
                foldedCount: showsRows ? folded.foldedCount : 0,
                hoverPath: displayPath(for: project.path)
            )
        }
    }

    // MARK: - Which workspaces a project has

    /// Every workspace of a project, whether it is the selected one or not. The
    /// project the live grouping belongs to reads that grouping; the rest are
    /// grouped from their summaries, so their tabs stay accounted for while
    /// focus is elsewhere.
    ///
    /// Keyed on the project the grouping belongs to, and not on the one that was
    /// picked: the two differ for the length of every lookup, and handing one
    /// project's grouping to another made both rows lie — the tree you had open
    /// blinked shut, and a flat project briefly wore four worktrees that were
    /// not its own. Until its detail arrives, a project is its summary, which is
    /// what every unselected row already reads.
    static func workspaces(
        of project: ProjectSummaryViewData,
        in snapshot: SidebarSnapshot
    ) -> [WorkspaceViewData] {
        guard project.id != snapshot.onScreenProjectID else { return snapshot.liveWorkspaces }
        return WorkspaceViewData.groupSessions(
            project.liveSessionDetails,
            into: snapshot.worktreesByPath[project.path],
            projectPath: project.path
        )
    }

    /// The same, filtered to what the sidebar draws as child rows: a repo with
    /// one worktree stays flat, because the project row already is it.
    static func worktreeRows(
        of project: ProjectSummaryViewData,
        in snapshot: SidebarSnapshot
    ) -> [WorkspaceViewData] {
        let grouped = workspaces(of: project, in: snapshot)
        return grouped.count > 1 ? grouped : []
    }

    /// A repo collects worktrees, and the ones with no tabs are the ones nobody
    /// is working in. They fold behind a count rather than pushing everything
    /// else off the screen.
    ///
    /// Two never fold. A worktree with tabs, because it carries a `Cmd` digit
    /// and folding it would leave a number pointing at nothing on screen — the
    /// same reason a folded project row wears the digit that leads inside it.
    /// And the row being stood in *right now*, under the same predicate the
    /// highlight uses, because a highlighted row that is folded away is a
    /// selection nobody can see.
    ///
    /// Nothing else. `main` folded like any other idle row on 2026-09-01: its
    /// old exemption guarded an open tree from showing a bare "2 more" under a
    /// blank line, and the line stopped being blank when `infoLine` learned to
    /// speak in every state — while a sidebar of repos collecting worktrees
    /// showed an idle `main` row under every one. The remembered worktree
    /// (`projectSelectedWorkspaces`) went with it: a row held open for a
    /// project you are not even in reads as clutter, not as memory. The cost,
    /// accepted: walking away from an idle worktree folds its row, so selection
    /// now changes the row count — the flap the remembered rule existed to
    /// avoid.
    static func fold(
        _ all: [WorkspaceViewData],
        of project: ProjectSummaryViewData,
        in snapshot: SidebarSnapshot
    ) -> FoldedWorktrees {
        guard !snapshot.projectsShowingEveryWorktree.contains(project.id) else {
            return FoldedWorktrees(shown: all, foldedCount: 0)
        }
        let standing = snapshot.selectedProjectID == project.id
            ? snapshot.activeWorkspacePath : nil
        let shown = all.filter { workspace in
            !workspace.sessions.isEmpty || workspace.path == standing
        }
        return FoldedWorktrees(shown: shown, foldedCount: all.count - shown.count)
    }

    /// The worktree rows of one project, with the idle ones folded away.
    struct FoldedWorktrees: Equatable {
        var shown: [WorkspaceViewData]
        var foldedCount: Int
    }

    // MARK: - What a row says

    static func status(
        of project: ProjectSummaryViewData,
        in snapshot: SidebarSnapshot
    ) -> ProjectStatus {
        let sessionIDs = Set(project.liveSessionDetails.map(\.id))
        if project.hasInterruptedSessions && project.liveSessions == 0 { return .interrupted }
        guard !sessionIDs.isEmpty, project.liveSessions > 0 else { return .idle }

        if project.hasInterruptedSessions { return .needsInput }

        let states = sessionIDs.compactMap { snapshot.sessionStates[$0] }
        if states.contains(.needsInput) { return .needsInput }
        if !states.isEmpty && states.allSatisfy({ $0 == .idle }) { return .idle }
        return .running
    }

    /// Status of one worktree, from the tabs that belong to it. Mirrors the
    /// project's but never reads a sibling worktree's tabs.
    static func status(
        of workspace: WorkspaceViewData,
        in snapshot: SidebarSnapshot
    ) -> ProjectStatus {
        let states = workspace.sessions.compactMap { snapshot.sessionStates[$0.id] }
        if states.contains(.needsInput) { return .needsInput }
        if states.isEmpty || states.allSatisfy({ $0 == .idle }) { return .idle }
        return .running
    }

    /// The line under a project's name — and it says something in every state.
    ///
    /// Closed, the row *is* its main worktree, so the line names it: the branch,
    /// or for a folder that is no repository, that fact. A repo with more than
    /// one worktree adds how many, which is the only warning that clicking will
    /// unfold a tree.
    ///
    /// Open, the branch is spelled by the `main` row one line below, so this
    /// line drops it and keeps the count — the one thing no child row can say,
    /// and the only mark left that the tree is open now that the disclosure
    /// triangle is gone. It used to be faded out instead, and with every
    /// worktree folded away that left a blank line under the name with nothing
    /// on screen to explain it.
    ///
    /// Never the path. The row's title is the folder's name, and spelling the
    /// same folder out again underneath tells nobody anything.
    static func infoLine(
        for project: ProjectSummaryViewData,
        worktreeRowsShown: Bool,
        in snapshot: SidebarSnapshot
    ) -> String? {
        let scale = worktreeCount(for: project, in: snapshot)
            .flatMap { $0 > 1 ? "\($0) worktrees" : nil }
        if worktreeRowsShown, let scale { return scale }
        guard let identity = identityLine(for: project, in: snapshot) else { return scale }
        guard let scale else { return identity }
        return "\(identity) · \(scale)"
    }

    /// A remote row leads with the branch and trails the host, the same way a
    /// local row leads with the branch and has no host to trail. Several
    /// projects on one box otherwise repeated that one word down the sidebar
    /// while saying nothing about any of them.
    ///
    /// The branch is the main worktree's, from the scan — the remote answer to
    /// what `gitBranches` is locally, since `git -C` here cannot be asked about
    /// a directory over there. Until the scan lands, or on a `ssh://host` with
    /// no path that is never scanned, the host stands alone: naming a branch
    /// nobody has told us is the guess that "non-git" waits to avoid.
    private static func identityLine(
        for project: ProjectSummaryViewData,
        in snapshot: SidebarSnapshot
    ) -> String? {
        if project.transport == "ssh" {
            let host = SSHConnectionInfo(uri: project.path)?.displayLabel ?? project.path
            guard let branch = snapshot.worktreesByPath[project.path]?
                .first(where: \.isMainWorktree)?.branch
            else { return host }
            return "\(branch) on \(host)"
        }
        guard !project.path.isEmpty else { return nil }
        // Under the address's one spelling, which is what git was asked under.
        // A project added as `/private/tmp/repo` reads the same row as one
        // added as `/tmp/repo`; spelling the key by hand loses both the branch
        // and the "non-git" that stands in for it.
        let key = WorkspaceAddress(project.path).storageKey
        if let branch = snapshot.gitBranches[key] { return branch }
        // Blank until the lookup lands: "non-git" before asking would be a guess.
        return snapshot.nonGitProjectPaths.contains(key) ? "non-git" : nil
    }

    /// How many worktrees a project has, or nil while nobody has answered yet.
    ///
    /// Straight from git's answer rather than through the row grouping, which
    /// reads the live grouping for the project on screen and the cache for every
    /// other one — a number that changed on selection would say the repo grew
    /// when all that happened was a click.
    static func worktreeCount(
        for project: ProjectSummaryViewData,
        in snapshot: SidebarSnapshot
    ) -> Int? {
        snapshot.worktreesByPath[project.path]?.count
    }

    /// How a workspace address reads on screen — the address knows, because it
    /// knows which machine it names.
    static func displayPath(for workspacePath: String) -> String {
        WorkspaceAddress(workspacePath).displayName
    }

    // MARK: - Where the digits go

    /// One place a `Cmd` digit can take you.
    ///
    /// A digit is for where work is happening, and inside a repo with several
    /// worktrees that is the worktree, not the project heading. A repo whose
    /// worktrees are all empty has nothing to single out and is addressed as
    /// itself — so is a project with no tabs at all, which is precisely where
    /// you go to open one.
    enum NumberedPlace: Hashable {
        case project(String)
        case worktree(projectID: String, path: String)

        var projectID: String {
            switch self {
            case .project(let id): id
            case .worktree(let id, _): id
            }
        }
    }

    struct NumberedBadges: Equatable {
        var byProject: [String: Int] = [:]
        var byWorktree: [NumberedPlace: Int] = [:]

        func index(forProject project: ProjectSummaryViewData) -> Int? {
            byProject[project.id]
        }

        func index(forWorktree workspace: WorkspaceViewData,
                   in project: ProjectSummaryViewData) -> Int? {
            byWorktree[.worktree(projectID: project.id, path: workspace.path)]
        }
    }

    /// Where `Cmd+1…9` go, in sidebar order.
    ///
    /// Blind to whether a tree is expanded: folding must not shuffle the digits
    /// out from under the user's fingers, and neither may walking between
    /// worktrees. Only the badge follows what is on screen.
    static func numberedPlaces(_ snapshot: SidebarSnapshot) -> [NumberedPlace] {
        numberedPlaces(snapshot.projects.map { project in
            (project: project, workspaces: worktreeRows(of: project, in: snapshot))
        })
    }

    private static func numberedPlaces(
        _ grouped: [(project: ProjectSummaryViewData, workspaces: [WorkspaceViewData])]
    ) -> [NumberedPlace] {
        let places = grouped.flatMap { project, all -> [NumberedPlace] in
            let worked = all.filter { !$0.sessions.isEmpty }
            guard !worked.isEmpty else { return [.project(project.id)] }
            return worked.map { .worktree(projectID: project.id, path: $0.path) }
        }
        return Array(places.prefix(9))
    }

    /// Every badge on the sidebar, worked out once.
    ///
    /// A project whose digit lives on a worktree row gives the badge up while
    /// its tree is open — that row is on screen and wears it. Folded, the
    /// project row stands in for the first digit inside it, because that row is
    /// then the only thing the digit can point at.
    static func badges(
        _ places: [NumberedPlace],
        grouped: [(project: ProjectSummaryViewData, workspaces: [WorkspaceViewData])],
        in snapshot: SidebarSnapshot
    ) -> NumberedBadges {
        var badges = NumberedBadges()
        for (offset, place) in places.enumerated() {
            if case .worktree = place { badges.byWorktree[place] = offset + 1 }
        }
        for (project, all) in grouped {
            if let own = places.firstIndex(of: .project(project.id)) {
                badges.byProject[project.id] = own + 1
            } else if !(snapshot.expandedProjectIDs.contains(project.id) && !all.isEmpty),
                      let first = places.firstIndex(where: { $0.projectID == project.id }) {
                badges.byProject[project.id] = first + 1
            }
        }
        return badges
    }
}
