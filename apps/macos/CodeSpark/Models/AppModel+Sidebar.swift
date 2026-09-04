import Foundation

/// The model's side of the sidebar: it hands `SidebarPresenter` a snapshot and
/// gets rows back, and it owns the actions a row can start.
///
/// Nothing here decides what a row says any more. That moved to
/// `SidebarPresenter`, where it is a function of a value and can be tested
/// without a model, a main actor, or git — and where it is worked out in one
/// pass instead of once per row per field.

extension AppModel {

    /// Everything the sidebar reads, copied out once.
    var sidebarSnapshot: SidebarSnapshot {
        var worktreesByPath: [String: [GitWorktree]] = [:]
        for project in orderedProjects {
            worktreesByPath[project.path] = gitWorktreeService.worktrees(for: project.path)
        }
        return SidebarSnapshot(
            projects: orderedProjects,
            onScreenProjectID: selection.onScreen?.id,
            selectedProjectID: selection.id,
            activeWorkspacePath: activeWorkspacePath,
            liveWorkspaces: workspaces,
            worktreesByPath: worktreesByPath,
            sessionStates: sessionStates,
            gitBranches: gitBranches,
            nonGitProjectPaths: nonGitProjectPaths,
            expandedProjectIDs: expandedProjectIDs,
            projectsShowingEveryWorktree: projectsShowingEveryWorktree,
            projectSelectedWorkspaces: projectSelectedWorkspaces
        )
    }

    /// Every row the sidebar draws. The view binds this once per body pass —
    /// asking per row is the shape that made drawing N projects cost N groupings
    /// of every project's sessions, on every `@Published` change.
    var sidebarGroups: [SidebarProjectGroup] {
        SidebarPresenter.groups(sidebarSnapshot)
    }

    typealias NumberedPlace = SidebarPresenter.NumberedPlace
    typealias NumberedBadges = SidebarPresenter.NumberedBadges
    typealias SidebarWorktreeRows = SidebarPresenter.FoldedWorktrees

    // MARK: - One question at a time
    //
    // The presenter answers these for the whole sidebar at once; these are for
    // callers that hold a single project — the menu, and the tests that read one
    // row's worth of the answer.

    func projectStatus(for project: ProjectSummaryViewData) -> ProjectStatus {
        SidebarPresenter.status(of: project, in: sidebarSnapshot)
    }

    func workspaceStatus(for workspace: WorkspaceViewData) -> ProjectStatus {
        SidebarPresenter.status(of: workspace, in: sidebarSnapshot)
    }

    /// Worktrees to draw as child rows under the selected project. A repo with a
    /// single worktree stays flat — the project row already is that worktree, and
    /// a lone "main" child would be noise on every project.
    var sidebarWorktrees: [WorkspaceViewData] {
        workspaces.count > 1 ? workspaces : []
    }

    func workspaces(for project: ProjectSummaryViewData) -> [WorkspaceViewData] {
        SidebarPresenter.workspaces(of: project, in: sidebarSnapshot)
    }

    func sidebarWorktrees(for project: ProjectSummaryViewData) -> [WorkspaceViewData] {
        SidebarPresenter.worktreeRows(of: project, in: sidebarSnapshot)
    }

    func sidebarWorktreeRows(for project: ProjectSummaryViewData) -> SidebarWorktreeRows {
        let snapshot = sidebarSnapshot
        return SidebarPresenter.fold(
            SidebarPresenter.worktreeRows(of: project, in: snapshot),
            of: project,
            in: snapshot
        )
    }

    func showsWorktreeRows(for project: ProjectSummaryViewData) -> Bool {
        let snapshot = sidebarSnapshot
        return snapshot.expandedProjectIDs.contains(project.id)
            && !SidebarPresenter.worktreeRows(of: project, in: snapshot).isEmpty
    }

    func displayPath(for workspacePath: String) -> String {
        SidebarPresenter.displayPath(for: workspacePath)
    }

    func projectInfoLine(for project: ProjectSummaryViewData) -> String? {
        let snapshot = sidebarSnapshot
        let shown = snapshot.expandedProjectIDs.contains(project.id)
            && !SidebarPresenter.worktreeRows(of: project, in: snapshot).isEmpty
        return SidebarPresenter.infoLine(for: project, worktreeRowsShown: shown, in: snapshot)
    }

    func worktreeCount(for project: ProjectSummaryViewData) -> Int? {
        SidebarPresenter.worktreeCount(for: project, in: sidebarSnapshot)
    }

    var numberedPlaces: [NumberedPlace] {
        SidebarPresenter.numberedPlaces(sidebarSnapshot)
    }

    var numberedBadges: NumberedBadges {
        let snapshot = sidebarSnapshot
        let grouped = snapshot.projects.map { project in
            (project: project, workspaces: SidebarPresenter.worktreeRows(of: project, in: snapshot))
        }
        return SidebarPresenter.badges(
            SidebarPresenter.numberedPlaces(snapshot), grouped: grouped, in: snapshot
        )
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
        let landed = switch place {
        case .project(let id):
            await selectProject(id: id, promptForRecovery: true)
        case .worktree(let id, let path):
            await selectWorktree(projectID: id, path: path)
        }
        // A digit pressed while this one was still on its round trip has already
        // taken the user somewhere else. Scrolling to where this one was going
        // would drag the sidebar off the row they are now standing in.
        guard landed else { return }
        requestSidebarScroll(toProjectID: place.projectID)
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
    ///
    /// The path is written only if this navigation is still the current one.
    /// Selecting the project waits on git, and a digit pressed during that wait
    /// lands somewhere else — writing this worktree's path afterwards would put
    /// the project the user actually landed in on a worktree it does not have,
    /// emptying its tab bar. Returns whether it held.
    @discardableResult
    func selectWorktree(projectID: String, path: String) async -> Bool {
        if selection.id != projectID {
            guard await selectProject(id: projectID, promptForRecovery: true, landingOn: path)
            else { return false }
        }
        activeWorkspacePath = path
        return true
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
        if let connection = WorkspaceAddress(selection.onScreen?.path ?? "").remote {
            address = connection.address(forRemotePath: cwd).storageKey
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
        // Same key `refreshGitBranches` files the answer under.
        return gitBranches[WorkspaceAddress(selection.onScreen?.path ?? "").storageKey] ?? ""
    }
}
