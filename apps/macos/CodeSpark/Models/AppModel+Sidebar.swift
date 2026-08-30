import Foundation

/// The sidebar's whole vocabulary: what each row says, which worktrees it draws,
/// which of them fold, and where the `Cmd` digits go.
///
/// Split out of `AppModel` unchanged. Nineteen of the roughly sixty `fix:`
/// commits in this repository's history landed in `AppModel.swift` and fifteen
/// more in `SidebarView.swift` — 57% of them in two files, almost all answering
/// one question: *which row does this tab, or this string, belong to?* Giving
/// that question its own file is the first step toward giving it its own type.
///
/// Still an extension rather than a type of its own, so nothing about ownership
/// has changed yet: these functions read `AppModel`'s state directly. Making
/// them pure functions over a snapshot is the next move, and it is what would
/// let the sidebar be tested without a model at all.

extension AppModel {

    func projectStatus(for project: ProjectSummaryViewData) -> ProjectStatus {
        let sessionIDs = Set(project.liveSessionDetails.map(\.id))
        if project.hasInterruptedSessions && project.liveSessions == 0 { return .interrupted }
        guard !sessionIDs.isEmpty, project.liveSessions > 0 else { return .idle }

        if project.hasInterruptedSessions { return .needsInput }

        let states = sessionIDs.compactMap { sessionStates[$0] }
        if states.contains(.needsInput) { return .needsInput }
        if !states.isEmpty && states.allSatisfy({ $0 == .idle }) { return .idle }
        return .running
    }

    /// Worktrees to draw as child rows under the selected project. A repo with a
    /// single worktree stays flat — the project row already is that worktree, and
    /// a lone "main" child would be noise on every project.
    var sidebarWorktrees: [WorkspaceViewData] {
        workspaces.count > 1 ? workspaces : []
    }

    /// Every workspace of a project, whether it is the selected one or not. The
    /// selected project reads the live grouping; the rest are grouped from their
    /// summaries, so their tabs stay accounted for while focus is elsewhere.
    ///
    /// Keyed on the detail the live grouping belongs to, and not on the id,
    /// which moves the instant a row is clicked or a digit
    /// pressed. `workspaces` belongs to the project it was computed for, so
    /// through the round trip in between it still describes the project you came
    /// from, and handing it to the one you are going to made both rows lie: the
    /// tree you had open blinked shut, and a flat project briefly wore four
    /// worktrees that were not its own. Until the detail arrives, a project is
    /// its summary — the same thing every unselected row already reads.
    func workspaces(for project: ProjectSummaryViewData) -> [WorkspaceViewData] {
        guard project.id != selection.onScreen?.id else { return workspaces }
        return WorkspaceViewData.groupSessions(
            project.liveSessionDetails,
            into: gitWorktreeService.worktrees(for: project.path),
            projectPath: project.path
        )
    }

    /// The same, filtered down to what the sidebar draws as child rows: a repo
    /// with one worktree stays flat, because the project row already is it.
    func sidebarWorktrees(for project: ProjectSummaryViewData) -> [WorkspaceViewData] {
        let grouped = workspaces(for: project)
        return grouped.count > 1 ? grouped : []
    }

    /// The worktree rows of one project, with the idle ones folded away.
    struct SidebarWorktreeRows: Equatable {
        var shown: [WorkspaceViewData]
        var foldedCount: Int
    }

    /// A repo collects worktrees, and the ones with no tabs are the ones nobody
    /// is working in. They fold behind a count rather than pushing everything
    /// else off the screen.
    ///
    /// Three never fold. A worktree with tabs, because it carries a `Cmd` digit
    /// and folding it would leave a number pointing at nothing on screen — the
    /// same reason a folded project row wears the digit that leads inside it.
    /// The worktree the project was last left standing in, because coming back
    /// to a tree whose selection is hidden reads as no selection at all. And
    /// `main`, always: an open tree with every row folded away shows one grey
    /// "2 more" under a blank line, which reads as a rendering fault rather than
    /// as a fold — and since the expansion is remembered across launches while
    /// the "show me the rest" flag is not, that was the state the sidebar came
    /// back in every morning.
    ///
    /// The remembered worktree is read from `projectSelectedWorkspaces`, not
    /// from the live selection: the old test only held for the selected project,
    /// so a click that changed nothing else grew the list by a row and turned
    /// "2 more" into "1 more".
    func sidebarWorktreeRows(for project: ProjectSummaryViewData) -> SidebarWorktreeRows {
        let all = sidebarWorktrees(for: project)
        guard !projectsShowingEveryWorktree.contains(project.id) else {
            return SidebarWorktreeRows(shown: all, foldedCount: 0)
        }
        let remembered = projectSelectedWorkspaces[project.id]
        let shown = all.filter { workspace in
            !workspace.sessions.isEmpty
                || workspace.isMainWorktree
                || workspace.path == remembered
        }
        return SidebarWorktreeRows(shown: shown, foldedCount: all.count - shown.count)
    }

    /// Two halves of one rule: a path belongs to the row that *is* that worktree.
    /// While a tree is open the project row is only a heading, so it lets go of
    /// its path and the main worktree row picks it up — otherwise the same
    /// directory is spelled out twice, one line apart.
    func showsWorktreeRows(for project: ProjectSummaryViewData) -> Bool {
        expandedProjectIDs.contains(project.id) && !sidebarWorktrees(for: project).isEmpty
    }

    /// A linked worktree's directory is named after its branch, which the row
    /// already says. Only the main one carries a path worth reading.
    func worktreePathLine(for workspace: WorkspaceViewData) -> String? {
        workspace.isMainWorktree ? workspace.path : nil
    }

    /// How a workspace address reads on screen.
    ///
    /// A remote address is a URI, and a URI is not a filesystem path —
    /// `abbreviatingWithTildeInPath` collapses its `//` into
    /// `ssh:/localhost/srv/repo`. The host already sits on the project row, so
    /// the remote directory is the part worth reading.
    func displayPath(for workspacePath: String) -> String {
        if let remote = SSHConnectionInfo.remotePath(fromWorkspaceURI: workspacePath) {
            return remote
        }
        return (workspacePath as NSString).abbreviatingWithTildeInPath
    }

    /// What the two destructive confirmations say. Here rather than in the view
    /// body so a test can read it: a dialog's wording is the whole of what the
    /// user has to go on, and it is invisible from anywhere else.
    ///
    /// The distinction the copy has to carry is that these two deletions are not
    /// the same kind. Deleting a project drops a row from the store; the folder
    /// stays where it was. Removing a worktree runs `git worktree remove`, and
    /// that directory is gone.
    func deleteProjectMessage(name: String) -> String {
        "This will permanently delete \"\(name)\" and all its sessions. Files on disk are not affected."
    }

    func removeWorktreeMessage(path: String) -> String {
        "Its tabs will close and the folder \(displayPath(for: path)) will be deleted from disk. The branch itself stays."
    }

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

    /// Where `Cmd+1…9` go, in sidebar order.
    ///
    /// Blind to whether a tree is expanded: folding must not shuffle the digits
    /// out from under the user's fingers, and neither may walking between
    /// worktrees. Only the badge follows what is on screen — see
    /// `numberedIndex(forProject:)`.
    var numberedPlaces: [NumberedPlace] {
        Array(orderedProjects.flatMap(numberedPlaces(in:)).prefix(9))
    }

    private func numberedPlaces(in project: ProjectSummaryViewData) -> [NumberedPlace] {
        let worked = sidebarWorktrees(for: project).filter { !$0.sessions.isEmpty }
        guard !worked.isEmpty else { return [.project(project.id)] }
        return worked.map { .worktree(projectID: project.id, path: $0.path) }
    }

    /// Every badge on the sidebar, worked out once.
    ///
    /// There used to be two per-row lookups here, and each one rebuilt the whole
    /// numbering: drawing N projects grouped every project's sessions N times
    /// over, on every `@Published` change — including the OSC 7 report a shell
    /// sends at every prompt. Typing `ls` re-grouped the sidebar.
    ///
    /// The per-row functions are gone rather than kept alongside this one. A
    /// view that can only ask once cannot reintroduce the square.
    struct NumberedBadges: Equatable {
        fileprivate var byProject: [String: Int] = [:]
        fileprivate var byWorktree: [NumberedPlace: Int] = [:]

        func index(forProject project: ProjectSummaryViewData) -> Int? {
            byProject[project.id]
        }

        func index(forWorktree workspace: WorkspaceViewData,
                   in project: ProjectSummaryViewData) -> Int? {
            byWorktree[.worktree(projectID: project.id, path: workspace.path)]
        }
    }

    var numberedBadges: NumberedBadges {
        let places = numberedPlaces
        var badges = NumberedBadges()
        for (offset, place) in places.enumerated() {
            if case .worktree = place { badges.byWorktree[place] = offset + 1 }
        }
        for project in orderedProjects {
            if let own = places.firstIndex(of: .project(project.id)) {
                badges.byProject[project.id] = own + 1
            } else if !showsWorktreeRows(for: project),
                      let first = places.firstIndex(where: { $0.projectID == project.id }) {
                // Folded, the project row stands in for the first digit inside
                // it — that row is not on screen, and this is the only thing
                // that digit can point at.
                badges.byProject[project.id] = first + 1
            }
        }
        return badges
    }

    /// Menu wording: the project, and the branch the digit will land in when
    /// that is not simply the project itself.
    func numberedPlaceLabel(_ place: NumberedPlace) -> String {
        guard let project = projects.first(where: { $0.id == place.projectID }) else { return "" }
        let path: String? = switch place {
        case .project: projectSelectedWorkspaces[project.id]
        case .worktree(_, let path): path
        }
        guard let path,
              let branch = sidebarWorktrees(for: project).first(where: { $0.path == path })?.branch
        else { return project.name }
        return "\(project.name) — \(branch)"
    }

    /// A digit takes you somewhere and shows you where you landed: it selects
    /// the project — which reopens the worktree it was last left in, since
    /// `apply(detail:)` restores that — opens its tree, and stands in the
    /// worktree when the digit names one.
    ///
    /// Opens, never folds. Clicking a row toggles because the row is what you
    /// aimed at; a digit means "take me there", and arriving somewhere is no
    /// reason to shut what was open. Pressing it twice would otherwise make the
    /// tree flap, and the digits exist to be pressed without looking.
    func selectNumberedPlace(_ index: Int) async {
        let places = numberedPlaces
        guard index >= 1, index <= places.count else { return }
        let place = places[index - 1]
        // Open first, for the same reason the click toggles first: selecting
        // waits on a git round trip, and anything the row does after that shows
        // up as a second frame. Arriving already-open is one change; arriving
        // shut and then opening is a flicker.
        revealWorktrees(projectID: place.projectID)
        switch place {
        case .project(let id):
            await selectProject(id: id, promptForRecovery: true)
        case .worktree(let id, let path):
            await selectWorktree(projectID: id, path: path)
        }
    }

    /// Opens a tree that is shut and leaves an open one alone.
    func revealWorktrees(projectID: String) {
        guard !expandedProjectIDs.contains(projectID) else { return }
        toggleWorktrees(projectID: projectID)
    }

    /// What clicking a project row does. The disclosure triangle is gone, so the
    /// row is the only thing that folds the tree — while still selecting, which
    /// is the other half of what the click has always meant.
    ///
    /// It toggles without first asking whether there is a tree to toggle.
    /// Selecting refreshes the worktree list over git, so on a cold cache the
    /// answer at this moment is "none" even for a repo with several — and a
    /// guard would eat the first click on every project opened this session.
    /// A repo with one worktree just stores a flag that draws nothing.
    func selectProjectAndToggleWorktrees(id: String) async {
        // Fold first. Selecting refetches the worktree list, which queues behind
        // every other project's lookup — a remote one holds it for up to 20s —
        // and folding is local state that has no reason to wait for any of it.
        // Behind the await, the only way to open a tree took a round trip to
        // another machine to answer, and a second impatient click cancelled the
        // first.
        toggleWorktrees(projectID: id)
        await selectProject(id: id, promptForRecovery: true)
    }

    static func savedExpandedProjectIDs() -> Set<String> {
        let saved = UserDefaults.standard.string(forKey: StorageKeys.expandedProjectIDs) ?? ""
        return Set(saved.split(separator: ",").map(String.init))
    }

    /// A worktree row can belong to a project that is not the selected one, so
    /// picking it has to bring its project along.
    func selectWorktree(projectID: String, path: String) async {
        if selection.id != projectID {
            await selectProject(id: projectID, promptForRecovery: true)
        }
        activeWorkspacePath = path
    }

    /// Every project the sidebar can draw worktrees for. `refreshWorktrees`
    /// prunes whatever it is not given, so each refresh has to name them all or
    /// the projects that are merely open lose their rows.
    ///
    /// A remote project qualifies once its URI says where the repository is; a
    /// bare `ssh://host` does not, and guessing would cost a connection on
    /// every poll.
    var worktreeProjectPaths: [String] {
        projects.compactMap { project in
            guard !project.path.isEmpty else { return nil }
            guard project.transport == "ssh" else { return project.path }
            guard let info = SSHConnectionInfo(uri: project.path), info.remotePath != nil else { return nil }
            return project.path
        }
    }

    /// The branch a tab is currently working in, when that is not the worktree
    /// the tab belongs to — an agent that creates a worktree and moves into it
    /// leaves the tab where it was opened, which is right, but silent.
    ///
    /// nil whenever there is nothing to say: the tab is home, it stepped outside
    /// the repo entirely, or the repo has a single worktree.
    func visitingBranch(for session: SessionViewData) -> String? {
        guard workspaces.count > 1, let cwd = session.lastCwd else { return nil }
        // A remote tab reports a directory on the other machine, while
        // workspaces are addressed as URIs. Spell it the same way before
        // comparing — and through this project's own connection, so a path can
        // never match a worktree on some other host.
        let address: String
        if selection.onScreen?.transport == "ssh" {
            guard let info = SSHConnectionInfo(uri: selection.onScreen?.path ?? "") else { return nil }
            address = info.workspaceURI(forRemotePath: cwd)
        } else {
            address = cwd
        }
        guard let current = WorkspaceViewData.containing(cwd: address, in: workspaces),
              current.path != session.workspacePath else { return nil }
        return current.branch
    }

    /// Branch for the window subtitle. Once a repo has several worktrees the
    /// header has to name the one the tab bar is scoped to, or it reads as the
    /// wrong branch. A single-worktree project keeps the plain branch lookup —
    /// its grouping falls back to a "default" placeholder that must not show.
    var activeBranchLabel: String {
        if workspaces.count > 1,
           let path = activeWorkspacePath,
           let workspace = workspaces.first(where: { $0.path == path }) {
            return workspace.branch
        }
        return gitBranches[selection.onScreen?.path ?? ""] ?? ""
    }

    /// Status of one worktree, from the tabs that belong to it. Mirrors
    /// `projectStatus(for:)` but never reads a sibling worktree's tabs.
    func workspaceStatus(for workspace: WorkspaceViewData) -> ProjectStatus {
        let states = workspace.sessions.compactMap { sessionStates[$0.id] }
        if states.contains(.needsInput) { return .needsInput }
        if states.isEmpty || states.allSatisfy({ $0 == .idle }) { return .idle }
        return .running
    }
}
