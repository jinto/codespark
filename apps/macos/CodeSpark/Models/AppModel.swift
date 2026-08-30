import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectSummaryViewData] = []
    @Published var selectedProjectID: String?
    @Published var selectedProject: ProjectDetailViewData?
    @Published var activeSessionID: String? {
        didSet {
            guard let id = activeSessionID else { return }
            // A tab carries its worktree, so selecting one moves the sidebar with
            // it rather than recording the choice against whatever was active.
            let owner = liveSessions.first { $0.id == id }?.workspacePath
            // A worktree that no longer exists is not somewhere to move the
            // sidebar to — such a tab is regrouped under main and stays put.
            let ownerIsReal = workspaces.isEmpty || workspaces.contains { $0.path == owner }
            guard let path = (owner?.isEmpty == false && ownerIsReal) ? owner : activeWorkspacePath
            else { return }
            // Record before switching: `activeWorkspacePath`'s observer reads this
            // map, and the inequality guard is what stops the two from recursing.
            workspaceSelectedSessions[path] = id
            if activeWorkspacePath != path { activeWorkspacePath = path }
        }
    }
    @Published var liveSessions: [SessionViewData] = []

    /// All sessions across all projects — keeps Ghostty surfaces alive during project switches
    @Published private(set) var allSessions: [SessionViewData] = []
    @Published var loadErrorMessage: String?
    @Published var sessionStates: [String: TerminalState] = [:]
    var debounceTasks: [String: Task<Void, Never>] = [:]
    @Published var pendingCloseSessionID: String?
    @Published var pendingCloseProjectID: String?
    @Published var hiddenProjectIDs: Set<String> = []
    @Published var hiddenProjectNames: [String: String] = [:]
    @Published var gitBranches: [String: String] = [:]
    /// Project folders git has been asked about and disowned. Kept apart from
    /// "not asked yet": both have no branch, but only one of them knows it.
    @Published var nonGitProjectPaths: Set<String> = []
    @Published var workspaces: [WorkspaceViewData] = []
    @Published private(set) var expandedProjectIDs: Set<String> = AppModel.savedExpandedProjectIDs()
    @Published var selectedWorkspacePath: String?
    @Published private(set) var resumableAgentSessions: [ResumableAgentSession] = []
    @Published var activeWorkspacePath: String? {
        didSet {
            guard let path = activeWorkspacePath else { return }
            // The project remembers where you were, so coming back to it does not
            // drop you at the repo root.
            if let projectID = selectedProjectID { projectSelectedWorkspaces[projectID] = path }
            selectRememberedSession(in: path)
        }
    }

    /// Picks the tab this workspace was last on, falling back to its first.
    private func selectRememberedSession(in path: String) {
        // `workspaces` is empty until a project is applied — fall back to the
        // flat list then, so an early selection isn't thrown away.
        var scoped: [String] = []
        if workspaces.isEmpty {
            scoped = liveSessions.map(\.id)
        } else if let workspace = workspaces.first(where: { $0.path == path }) {
            scoped = workspace.sessions.map(\.id)
        }

        if let savedID = workspaceSelectedSessions[path], scoped.contains(savedID) {
            activeSessionID = savedID
        } else if let first = scoped.first {
            activeSessionID = first
            workspaceSelectedSessions[path] = first
        } else {
            // Nothing open here, so nothing may stay selected — the tab bar
            // is empty and the active tab must not point outside it.
            activeSessionID = nil
        }
    }

    /// Tabs belong to the worktree they were opened in, so the tab bar shows only
    /// the active worktree's. Falls back to every tab before workspaces exist.
    var visibleSessions: [SessionViewData] {
        guard !workspaces.isEmpty, let path = activeWorkspacePath else { return liveSessions }
        guard let workspace = workspaces.first(where: { $0.path == path }) else { return [] }
        let ids = Set(workspace.sessions.map(\.id))
        return liveSessions.filter { ids.contains($0.id) }
    }
    var workspaceSelectedSessions: [String: String] = [:]  // workspacePath → sessionID
    var projectSelectedWorkspaces: [String: String] = [:]  // projectID → workspacePath
    @Published var pendingSSHReconnectProjectID: String?
    @Published var pendingWorkspaceRecoveryProjectID: String?
    /// One sheet for a new project, wherever it lives. It used to be two flags
    /// and two menu items, which made "which kind of project is this" the first
    /// question rather than a detail of the answer.
    @Published var showNewProjectSheet = false

    /// How far a restore has got. Each tab costs a round trip, and an ssh tab
    /// waits on a remote host after that, so the wait is long enough to need
    /// saying out loud. nil whenever nothing is being restored.
    struct RestoreProgress: Equatable {
        /// Whose restore this is. A restore outlives the screen that started it —
        /// switch projects halfway and the count would otherwise follow you and
        /// promise tabs that are landing somewhere else.
        var projectID: String
        var completed: Int
        var total: Int

        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }
    @Published private(set) var restoreProgress: RestoreProgress?

    /// The restore the project on screen is waiting for, if it is waiting for one.
    private var progressForSelectedProject: RestoreProgress? {
        guard let restoreProgress, restoreProgress.projectID == selectedProjectID else { return nil }
        return restoreProgress
    }

    /// What the main area shows. Kept here as one decision so the view does not
    /// restate it in a chain of conditions only a running app can check.
    enum MainAreaContent: Equatable {
        case sshReconnect
        case restoring(RestoreProgress)
        case empty
        case terminals
    }

    var mainAreaContent: MainAreaContent {
        if pendingSSHReconnectProjectID != nil && liveSessions.isEmpty { return .sshReconnect }
        // A tab that is already back gets the room. Restoring the rest is said in
        // a strip above it, not by covering the terminal the user can use now.
        guard visibleSessions.isEmpty else { return .terminals }
        if let progress = progressForSelectedProject { return .restoring(progress) }
        return .empty
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
    func projectInfoLine(for project: ProjectSummaryViewData) -> String? {
        let scale = worktreeCount(for: project).flatMap { $0 > 1 ? "\($0) worktrees" : nil }
        if showsWorktreeRows(for: project), let scale { return scale }
        guard let identity = projectIdentityLine(for: project) else { return scale }
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
    private func projectIdentityLine(for project: ProjectSummaryViewData) -> String? {
        if project.transport == "ssh" {
            let host = SSHConnectionInfo(uri: project.path)?.displayLabel ?? project.path
            guard let branch = gitWorktreeService.worktrees(for: project.path)?
                .first(where: \.isMainWorktree)?.branch
            else { return host }
            return "\(branch) on \(host)"
        }
        guard !project.path.isEmpty else { return nil }
        if let branch = gitBranches[project.path] { return branch }
        // Blank until the lookup lands: "non-git" before asking would be a guess.
        return nonGitProjectPaths.contains(project.path) ? "non-git" : nil
    }

    /// How many worktrees a project has, or nil while nobody has answered yet.
    ///
    /// Straight from the cache rather than through `sidebarWorktrees(for:)`,
    /// which reads the live grouping for the selected project and the cache for
    /// every other one — a number that changed on selection would say the repo
    /// grew when all that happened was a click. And nil is not zero: a count we
    /// do not have yet is left off the row, the same way "non-git" waits for its
    /// lookup instead of guessing.
    func worktreeCount(for project: ProjectSummaryViewData) -> Int? {
        gitWorktreeService.worktrees(for: project.path)?.count
    }

    /// The strip above a terminal, for the tabs still on their way back.
    var restoreBannerProgress: RestoreProgress? {
        mainAreaContent == .terminals ? progressForSelectedProject : nil
    }

    let core: ProjectCoreClientProtocol
    private let terminalFactory: (SessionViewData) -> any TerminalHostProtocol
    private(set) var hosts: [String: any TerminalHostProtocol] = [:]
    private var detailTask: Task<Void, Never>?
    var idleTimer: AnyCancellable?
    var checkpointTimer: AnyCancellable?
    var activationObserver: AnyCancellable?
    private var hasReconciledOnLaunch = false
    let gitBranchService = GitBranchService()
    let gitWorktreeService = GitWorktreeService()

    init(
        core: ProjectCoreClientProtocol,
        terminalFactory: @escaping (SessionViewData) -> any TerminalHostProtocol = { _ in NoOpTerminalHost() }
    ) {
        self.core = core
        self.terminalFactory = terminalFactory
        startMonitorTimers()
    }

    func attachLiveSessions() async {
        guard let project = selectedProject else { return }
        // SSH projects: reattach existing sessions if any, otherwise show reconnect prompt
        if project.transport == "ssh" {
            let existingSSH = project.liveSessions.filter { hosts[$0.id] != nil }
            if !existingSSH.isEmpty {
                liveSessions = existingSSH
                activeSessionID = rememberedSession() ?? existingSSH.first?.id
            } else {
                liveSessions = []
                activeSessionID = nil
            }
            return
        }
        liveSessions = project.liveSessions
        for session in liveSessions where hosts[session.id] == nil {
            if !allSessions.contains(where: { $0.id == session.id }) {
                allSessions.append(session)
            }
            var host = terminalFactory(session)
            host.delegate = self
            host.attach(sessionID: session.id, command: nil, initialInput: nil)
            hosts[session.id] = host
        }
        // Reopening a project must not throw away which tab its active worktree
        // was on — the first one is only the fallback.
        activeSessionID = rememberedSession() ?? visibleSessions.first?.id
        syncProjectSessionDetails()
    }

    /// The tab the active workspace was last on, if it is still open here.
    private func rememberedSession() -> String? {
        guard let path = activeWorkspacePath,
              let saved = workspaceSelectedSessions[path],
              visibleSessions.contains(where: { $0.id == saved }) else { return nil }
        return saved
    }

    func load() async {
        do {
            if !hasReconciledOnLaunch {
                try await core.reconcileInterruptedSessions()
                hasReconciledOnLaunch = true
            }
            let allProjects = try await core.listProjectSummaries()
            let projects = allProjects.filter { !hiddenProjectIDs.contains($0.id) }
            self.projects = applySavedProjectOrder(to: projects)
            persistProjectOrder()

            guard !projects.isEmpty else {
                cancelInflightWork()
                selectedProjectID = nil
                clearDetailState()
                loadErrorMessage = nil
                return
            }

            let resolvedProjectID = if let selectedProjectID,
                                       projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID
            } else {
                projects[0].id
            }

            await selectProject(id: resolvedProjectID)
            await restoreInterruptedTabs(projectID: resolvedProjectID)
        } catch {
            cancelInflightWork()
            projects = []
            selectedProjectID = nil
            clearDetailState()
            loadErrorMessage = error.localizedDescription
        }
    }

    func selectProject(id: String?, promptForRecovery: Bool = false) async {
        cancelInflightWork()
        pendingWorkspaceRecoveryProjectID = nil

        guard let id else {
            selectedProjectID = nil
            clearDetailState()
            loadErrorMessage = nil
            return
        }

        selectedProjectID = id

        let task = Task {
            do {
                let detail = try await core.projectDetail(id: id)
                guard !Task.isCancelled else { return }
                apply(detail: detail)
                await attachLiveSessions()
                // SSH projects: show reconnect prompt if no live sessions
                if detail.transport == "ssh" && liveSessions.isEmpty {
                    pendingSSHReconnectProjectID = id
                } else {
                    pendingSSHReconnectProjectID = nil
                }
                // Two gates guard remote scanning — this one and the filter in
                // `worktreeProjectPaths`. Ask the same question in both places
                // so opening one without the other cannot happen.
                if worktreeProjectPaths.contains(detail.path) {
                    gitWorktreeService.expireCache(for: detail.path)
                    await gitWorktreeService.refreshWorktrees(for: worktreeProjectPaths)
                    recomputeWorkspaces()
                }
                refreshAgentSessions()
                if promptForRecovery,
                   liveSessions.isEmpty,
                   !detail.interruptedSessions.isEmpty {
                    pendingWorkspaceRecoveryProjectID = id
                }
                loadErrorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                clearDetailState()
                loadErrorMessage = error.localizedDescription
            }
        }
        detailTask = task
        await task.value
    }

    private func cancelInflightWork() {
        detailTask?.cancel()
    }

    private func apply(detail: ProjectDetailViewData) {
        selectedProject = detail
        liveSessions = detail.liveSessions
        selectedWorkspacePath = nil
        // The selection still names the *previous* project's worktree. Let it go
        // before recomputing, or the missing-worktree guard below reads it as a
        // worktree that vanished and overwrites what this project remembers.
        activeWorkspacePath = nil
        recomputeWorkspaces()
        // Reopening a project lands on the worktree it was left in — its path is
        // only the starting point, and the fallback when that worktree is gone.
        // The observer then picks that worktree's tab. Setting the tab first
        // would leave the selection outside the active worktree.
        let remembered = projectSelectedWorkspaces[detail.id]
        activeWorkspacePath = workspaces.contains { $0.path == remembered } ? remembered : detail.path
    }

    func recomputeWorkspaces() {
        guard let project = selectedProject else {
            workspaces = []
            return
        }
        let sessions = liveSessions.map { s in
            SessionSummary(id: s.id, title: s.title, targetLabel: s.targetLabel, lastCwd: s.lastCwd, workspacePath: s.workspacePath)
        }
        let worktrees = gitWorktreeService.worktrees(for: project.path)
        workspaces = WorkspaceViewData.groupSessions(sessions, into: worktrees, projectPath: project.path)

        // A worktree can go out from under the selection — removed here, or
        // deleted behind the app's back. Standing on one that no longer exists
        // matches no workspace, so `visibleSessions` empties and the main area
        // goes blank while sibling worktrees still have tabs running.
        //
        // Only when git actually named the worktrees: an empty answer means the
        // lookup failed or has not landed yet, which is no reason to move
        // someone off the worktree they are working in.
        if worktrees?.isEmpty == false, let active = activeWorkspacePath,
           !workspaces.contains(where: { $0.path.sameWorkspace(as: active) }) {
            activeWorkspacePath = workspaces.first { $0.path.sameWorkspace(as: project.path) }?.path
                ?? workspaces[0].path
        }
    }

    // MARK: - Project lifecycle

    func createProjectFromFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder for the new project"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let name = url.lastPathComponent
        await createProject(name: name, path: path)
    }

    func createProject(name: String, path: String = "", transport: String = "local") async {
        do {
            let newID = try await core.createProject(name: name, path: path, transport: transport)
            let newProject = ProjectSummaryViewData(
                id: newID,
                name: name,
                path: path,
                transport: transport,
                liveSessions: 0,
                recentlyClosedSessions: 0,
                hasInterruptedSessions: false,
                liveSessionDetails: []
            )
            projects.append(newProject)
            persistProjectOrder()
            await selectProject(id: newID)
            await newSession()
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func renameProject(id: String, newName: String) async {
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].name = newName
        }
        if selectedProject?.id == id {
            selectedProject = selectedProject.map {
                ProjectDetailViewData(id: $0.id, name: newName, path: $0.path, transport: $0.transport, liveSessions: $0.liveSessions)
            }
        }
        do {
            try await core.renameProject(id: id, newName: newName)
        } catch {
            NSLog("[CodeSpark] rename failed: \(error)")
        }
    }

    func updateProjectPath(id: String, newPath: String) async {
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].path = newPath
        }
        if selectedProject?.id == id {
            selectedProject = selectedProject.map {
                ProjectDetailViewData(id: $0.id, name: $0.name, path: newPath, transport: $0.transport, liveSessions: $0.liveSessions)
            }
        }
        do {
            try await core.updateProjectPath(id: id, newPath: newPath)
        } catch {
            NSLog("[CodeSpark] update path failed: \(error)")
        }
    }

    func focusActiveTerminal() {
        guard let id = activeSessionID,
              let surfaceView = hosts[id]?.surfaceNSView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            surfaceView.window?.makeFirstResponder(surfaceView)
        }
    }

    /// Returns the adjacent project ID (next preferred, then previous).
    private func adjacentProjectID(excluding id: String) -> String? {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return projects.first?.id }
        if index + 1 < projects.count { return projects[index + 1].id }
        if index > 0 { return projects[index - 1].id }
        return nil
    }

    /// Close all live sessions for a project and switch away if it was selected.
    /// Returns the adjacent project ID for selection after removal.
    private func teardownProject(id: String) -> String? {
        let nextID = adjacentProjectID(excluding: id)
        // Close sessions belonging to this project (from summary details or current liveSessions)
        let sessionIDs: [String]
        if selectedProjectID == id {
            sessionIDs = liveSessions.map(\.id)
        } else if let proj = projects.first(where: { $0.id == id }) {
            sessionIDs = proj.liveSessionDetails.map(\.id)
        } else {
            sessionIDs = []
        }
        for sessionID in sessionIDs {
            closeSession(id: sessionID)
        }
        projects.removeAll(where: { $0.id == id })
        return nextID
    }

    func closeProject(id: String) async {
        if let proj = projects.first(where: { $0.id == id }) {
            hiddenProjectNames[id] = proj.name
        }
        hiddenProjectIDs.insert(id)

        let nextID = teardownProject(id: id)
        if selectedProjectID == id {
            await selectProject(id: nextID)
        }
    }

    func reopenProject(id: String) async {
        hiddenProjectIDs.remove(id)
        hiddenProjectNames.removeValue(forKey: id)
        await load()
        await selectProject(id: id)
    }

    func deleteProject(id: String) async {
        let nextID = teardownProject(id: id)
        removeProjectFromSavedOrder(id: id)

        var deleteError: String?
        do {
            try await core.deleteProject(id: id)
        } catch {
            deleteError = error.localizedDescription
        }

        if selectedProjectID == id {
            await selectProject(id: nextID)
        }

        if let deleteError {
            loadErrorMessage = deleteError
        }
    }

    // MARK: - Session lifecycle

    func refreshAgentSessions() {
        let paths = Set(
            [selectedProject?.path, activeWorkspacePath]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                + workspaces.map(\.path)
        )
        resumableAgentSessions = AgentSessionDiscovery.discover(for: Array(paths))
    }

    /// Presents the same session chooser used when opening an interrupted workspace.
    func presentSessionChooser() {
        guard selectedProjectID != nil else { return }
        pendingWorkspaceRecoveryProjectID = selectedProjectID
    }

    /// The single project order shared by the sidebar and Cmd+1…9 shortcuts.
    var orderedProjects: [ProjectSummaryViewData] {
        projects
    }

    func moveProject(id: String, to target: ProjectDropTarget) {
        guard let sourceIndex = projects.firstIndex(where: { $0.id == id }) else { return }

        let insertionIndex: Int
        switch target {
        case .before(let targetID):
            guard id != targetID,
                  let targetIndex = projects.firstIndex(where: { $0.id == targetID }) else { return }
            // The row it lands above shifts up once the dragged one is lifted out.
            insertionIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        case .end:
            insertionIndex = projects.count - 1
        }

        let project = projects.remove(at: sourceIndex)
        projects.insert(project, at: insertionIndex)
        persistProjectOrder()
    }

    private func applySavedProjectOrder(to loadedProjects: [ProjectSummaryViewData]) -> [ProjectSummaryViewData] {
        let savedIDs = savedProjectOrder()
        guard !savedIDs.isEmpty else { return loadedProjects }

        let projectsByID = Dictionary(uniqueKeysWithValues: loadedProjects.map { ($0.id, $0) })
        let savedProjects = savedIDs.compactMap { projectsByID[$0] }
        let savedIDSet = Set(savedIDs)
        let newProjects = loadedProjects.filter { !savedIDSet.contains($0.id) }
        return savedProjects + newProjects
    }

    private func savedProjectOrder() -> [String] {
        UserDefaults.standard.string(forKey: StorageKeys.projectOrder)?
            .split(separator: ",")
            .map(String.init) ?? []
    }

    private func persistProjectOrder() {
        let currentIDs = projects.map(\.id)
        let savedIDs = savedProjectOrder()
        let currentIDSet = Set(currentIDs)
        let preservedIDs = savedIDs.filter { !currentIDSet.contains($0) }
        UserDefaults.standard.set((currentIDs + preservedIDs).joined(separator: ","), forKey: StorageKeys.projectOrder)
    }

    private func removeProjectFromSavedOrder(id: String) {
        let remaining = savedProjectOrder().filter { $0 != id }
        UserDefaults.standard.set(remaining.joined(separator: ","), forKey: StorageKeys.projectOrder)
    }

    @discardableResult
    private func startAndAttachSession(
        projectID: String,
        transport: String,
        targetLabel: String,
        title: String,
        shell: String,
        cwd: String?,
        workspacePath: String,
        command: String? = nil,
        initialInput: String? = nil,
        sshInfo: SSHConnectionInfo? = nil
    ) async throws -> String {
        let sessionID = try await core.startSession(
            projectId: projectID,
            transport: transport,
            targetLabel: targetLabel,
            title: title,
            shell: shell,
            initialCwd: cwd,
            workspacePath: workspacePath
        )
        let session = SessionViewData(
            id: sessionID,
            title: title,
            targetLabel: targetLabel,
            lastCwd: cwd,
            workspacePath: workspacePath
        )
        var host = terminalFactory(session)
        host.delegate = self
        #if GHOSTTY_FIRST
        if let sshInfo, let ghosttyHost = host as? GhosttyTerminalHost {
            ghosttyHost.sshConnectionInfo = sshInfo
        }
        #endif
        host.attach(sessionID: sessionID, command: command, initialInput: initialInput)
        hosts[sessionID] = host
        if !allSessions.contains(where: { $0.id == sessionID }) {
            allSessions.append(session)
        }
        // `liveSessions` is the selected project's tab bar, and this can land
        // after the selection moved: restoring a project's tabs takes a round
        // trip each, and clicking another project mid-restore used to pour them
        // into whatever was on screen. The surface stays alive either way — its
        // own project picks it up from the store when it is opened again.
        guard selectedProjectID == projectID else { return sessionID }
        liveSessions.append(session)
        // The grouping is what the tab bar reads through `visibleSessions`, so a
        // tab that is not in it is a tab nobody can see. `newSession` regrouped
        // on its own and restoring did not, which left restored tabs invisible
        // until some unrelated recompute — a cwd report, usually — went past.
        recomputeWorkspaces()
        syncProjectSessionDetails()
        return sessionID
    }

    func newSession(inWorkspacePath: String? = nil) async {
        // The summary, not `selectedProject`. `selectedProjectID` moves on the
        // click and the detail lands a git round trip later, so reading both in
        // one breath filed this tab under the project you were going to with the
        // path of the one you came from — and `core.startSession` below writes
        // that row before any guard can catch it. `projects` is keyed by id, so
        // it cannot disagree with itself.
        guard let projectID = selectedProjectID,
              let project = projects.first(where: { $0.id == projectID }) else { return }

        let workspacePath: String
        if let explicit = inWorkspacePath {
            workspacePath = explicit
        } else if let active = activeWorkspacePath,
                  // `activeWorkspacePath` and `workspaces` still describe the
                  // previous project until `apply(detail:)` runs, and the
                  // membership check passes against *its* grouping. Only trust
                  // them once they are this project's.
                  selectedProject?.id == projectID,
                  workspaces.contains(where: { $0.path == active }) {
            // A new tab belongs to the worktree you are looking at. The
            // membership check keeps a removed worktree from taking the tab
            // somewhere that no longer exists.
            workspacePath = active
        } else {
            workspacePath = project.path.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : project.path
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // SSH projects: use ssh command instead of local shell
        if project.transport == "ssh", var info = SSHConnectionInfo(uri: project.path) {
            // The tab belongs to the worktree the tab bar is showing. That
            // address is a URI on this same host, and its remote path is where
            // the shell has to land.
            let remoteCwd = SSHConnectionInfo.remotePath(fromWorkspaceURI: workspacePath)
            if let remoteCwd { info.remotePath = remoteCwd }
            do {
                // `cwd` is a *remote* path on purpose — see the note in
                // `restoreInterruptedTabs`. It is also what the store files as
                // this tab's position, and no OSC 7 will ever refill it.
                let sessionID = try await startAndAttachSession(
                    projectID: projectID,
                    transport: "ssh",
                    targetLabel: info.displayLabel,
                    title: info.displayLabel,
                    shell: shell,
                    cwd: remoteCwd,
                    workspacePath: workspacePath,
                    command: info.sshCommand(),
                    sshInfo: info
                )
                guard selectedProjectID == projectID else { return }
                // Regroup before selecting: `activeWorkspacePath`'s observer
                // reads `workspaces`, so a stale grouping would not see the new
                // tab and would bounce the selection to an older one.
                recomputeWorkspaces()
                workspaceSelectedSessions[workspacePath] = sessionID
                activeWorkspacePath = workspacePath
                activeSessionID = sessionID
                pendingSSHReconnectProjectID = nil
            } catch {
                loadErrorMessage = error.localizedDescription
            }
            return
        }
        do {
            let sessionID = try await startAndAttachSession(
                projectID: projectID,
                transport: "local",
                targetLabel: "local",
                title: "Terminal",
                shell: shell,
                cwd: workspacePath,
                workspacePath: workspacePath
            )
            // The selection may have moved while the session was starting; the
            // tab belongs to the project that asked for it, not to this screen.
            guard selectedProjectID == projectID else { return }
            // Regroup before selecting: `activeWorkspacePath`'s observer reads
            // `workspaces`, so a stale grouping would not see the new tab and
            // would bounce the selection to an older one.
            recomputeWorkspaces()
            workspaceSelectedSessions[workspacePath] = sessionID
            activeWorkspacePath = workspacePath
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func restoreInterruptedTabs(projectID: String) async {
        guard let project = selectedProject,
              project.id == projectID,
              liveSessions.isEmpty,
              !project.interruptedSessions.isEmpty else {
            pendingWorkspaceRecoveryProjectID = nil
            return
        }

        let interruptedSessions = project.interruptedSessions
        pendingWorkspaceRecoveryProjectID = nil
        // `selectProject` raises the reconnect offer for an ssh project with no
        // live tabs, and `mainAreaContent` puts that ahead of everything. We are
        // the answer to it: reconnecting is exactly what this is doing. Left
        // standing it hides the progress through the whole ssh restore — the
        // slow one — and outlives it, so closing every tab later offers to
        // reconnect a project that is already connected.
        pendingSSHReconnectProjectID = nil
        restoreProgress = RestoreProgress(projectID: projectID, completed: 0, total: interruptedSessions.count)
        defer { restoreProgress = nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        for interrupted in interruptedSessions {
            do {
                // Replays the tab's previous screen into scrollback, above the
                // prompt the restored shell is about to print.
                let snapshot = (try? await core.latestSnapshot(sessionID: interrupted.id)) ?? nil

                let sessionID: String
                // Where the tab belongs, which is not where it happened to be
                // standing: a cwd may be any directory inside the worktree.
                let workspacePath = interrupted.workspacePath.isEmpty
                    ? project.path
                    : interrupted.workspacePath
                if project.transport == "ssh", var info = SSHConnectionInfo(uri: project.path) {
                    // Remote shells can't be reopened with a local cwd — land the
                    // ssh session in the directory the tab was last in instead.
                    if let remoteCwd = interrupted.lastCwd, !remoteCwd.isEmpty {
                        info.remotePath = remoteCwd
                    }
                    // `cwd` below is a *remote* path, and it stays that way on
                    // purpose. It is not only Ghostty's working directory — it is
                    // also what `startSession` files as this tab's cwd, and a
                    // remote shell has no Ghostty shell integration to report OSC
                    // 7 and refill it. Passing nil to keep the local surface
                    // honest would cost the tab its place on every later restore.
                    // Ghostty already tolerates the mismatch: a working directory
                    // it cannot open is logged and skipped (`embedded.zig`), and
                    // the remote side is positioned by `info.remotePath` anyway.
                    // The real fix is to stop conflating "where the surface
                    // starts" with "where the tab is", at the Ghostty boundary.
                    sessionID = try await startAndAttachSession(
                        projectID: projectID,
                        transport: "ssh",
                        targetLabel: interrupted.targetLabel,
                        title: interrupted.title,
                        shell: shell,
                        cwd: interrupted.lastCwd,
                        workspacePath: workspacePath,
                        command: info.sshCommand(
                            replaying: snapshot.flatMap { RestoredScreenReplay.inlineCommand(for: $0) }
                        ),
                        sshInfo: info
                    )
                } else {
                    sessionID = try await startAndAttachSession(
                        projectID: projectID,
                        transport: "local",
                        targetLabel: interrupted.targetLabel,
                        title: interrupted.title,
                        shell: shell,
                        cwd: interrupted.lastCwd ?? project.path,
                        workspacePath: workspacePath,
                        initialInput: snapshot.flatMap { RestoredScreenReplay.prepare(snapshot: $0) }
                    )
                }

                workspaceSelectedSessions[workspacePath] = sessionID
                // The tab now lives in `sessionID`. Retiring the row it came from
                // is what stops the next launch restoring it alongside its own
                // replacement — that compounds, doubling tabs every launch.
                try? await core.consumeInterruptedSession(sessionId: interrupted.id)
                restoreProgress?.completed += 1
            } catch {
                loadErrorMessage = error.localizedDescription
                break
            }
        }

        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].hasInterruptedSessions = false
        }
        if selectedProject?.id == projectID, let detail = selectedProject {
            selectedProject = ProjectDetailViewData(
                id: detail.id,
                name: detail.name,
                path: detail.path,
                transport: detail.transport,
                liveSessions: detail.liveSessions,
                interruptedSessions: []
            )
        }
        // Same guard the loop uses on every tab it creates: by the time a
        // restore finishes, the user may be looking at another project, and
        // `liveSessions` is then theirs. Choosing a tab in it moves them off the
        // one they opened on, and `activeSessionID.didSet` drags the sidebar to
        // that tab's worktree after it.
        guard selectedProjectID == projectID else { return }
        recomputeWorkspaces()
        activeSessionID = liveSessions.last?.id
    }

    func newAgentSession(_ agent: AgentKind, resumeID: String? = nil) async {
        // Same pairing as `newSession`, and the transport made it worse: read
        // from the project you came from, leaving a local project for an ssh one
        // opened a local agent shell and recorded it against the remote project.
        guard let projectID = selectedProjectID,
              let project = projects.first(where: { $0.id == projectID }),
              project.transport == "local" else { return }

        let workspacePath = selectedProject?.id == projectID
            ? (activeWorkspacePath ?? project.path)
            : project.path
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command: String = if let resumeID {
            agent.resumeCommand(id: resumeID)
        } else {
            agent.command
        }
        let title = resumeID.map { "\(agent.title) • \(String($0.prefix(8)))" } ?? agent.title

        do {
            let sessionID = try await startAndAttachSession(
                projectID: projectID,
                transport: "local",
                targetLabel: agent.rawValue,
                title: title,
                shell: shell,
                cwd: workspacePath,
                workspacePath: workspacePath,
                command: command
            )
            // The selection may have moved while the session was starting; the
            // tab belongs to the project that asked for it, not to this screen.
            guard selectedProjectID == projectID else { return }
            recomputeWorkspaces()
            activeSessionID = sessionID
            refreshAgentSessions()
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Worktree lifecycle

    func addWorktree(branch: String) async {
        guard let project = selectedProject, !project.path.isEmpty else { return }
        do {
            let creation = try await GitWorktreeService.addWorktree(
                projectPath: project.path, branch: branch
            )
            gitWorktreeService.expireCache(for: project.path)
            await gitWorktreeService.refreshWorktrees(for: worktreeProjectPaths)
            recomputeWorkspaces()
            await newSession(inWorkspacePath: creation.path)
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func removeWorktree(path: String) async {
        guard let project = selectedProject, !project.path.isEmpty else { return }
        do {
            // Remove first, close after. A remove that fails must not cost the
            // user their terminals — over ssh that failure is routine.
            try await GitWorktreeService.removeWorktree(projectPath: project.path, worktreePath: path)
            // By ownership, not by where the tab is standing: a tab belongs to
            // the worktree it was opened in and keeps belonging to it after a
            // `cd`. The old cwd test let a tab that had wandered out survive the
            // directory it lived in, and shut down visitors from other worktrees
            // in its place.
            for session in liveSessions where session.belongs(to: path) {
                closeSession(id: session.id)
            }
            gitWorktreeService.expireCache(for: project.path)
            await gitWorktreeService.refreshWorktrees(for: worktreeProjectPaths)
            recomputeWorkspaces()
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func closeSession(id: String) {
        guard let host = hosts[id] else { return }
        closingSessionIDs.insert(id)
        host.close(sessionID: id)
    }

    /// The terminal reports its working directory on every prompt, so this is a
    /// hot path — only a real directory change is written through to the store.
    func sessionDidReportCwd(sessionID: String, cwd: String) {
        // `allSessions`, not `liveSessions`: a tab whose project is not on screen
        // still has a running shell that can `cd`. Reading the narrower list
        // dropped those reports and left the store pointing at the old
        // directory, which is where the next restore would bring the tab back.
        guard let index = allSessions.firstIndex(where: { $0.id == sessionID }),
              allSessions[index].lastCwd != cwd else { return }
        allSessions[index].lastCwd = cwd
        if let visible = liveSessions.firstIndex(where: { $0.id == sessionID }) {
            liveSessions[visible].lastCwd = cwd
            recomputeWorkspaces()
        }

        Task { [core] in
            do {
                try await core.updateSessionCwd(sessionId: sessionID, cwd: cwd)
            } catch {
                NSLog("[CodeSpark] cwd update failed for session \(sessionID): \(error)")
            }
        }
    }

    func renameSession(id: String, title: String) async {
        if let index = liveSessions.firstIndex(where: { $0.id == id }) {
            var updated = liveSessions[index]
            updated.title = title
            liveSessions[index] = updated
        }
        do {
            try await core.updateSessionTitle(sessionId: id, newTitle: title)
        } catch {
            NSLog("[CodeSpark] session rename failed: \(error)")
        }
    }

    func selectNextSession() { cycleSession(offset: 1) }
    func selectPreviousSession() { cycleSession(offset: -1) }

    func selectNextWorktree() { cycleWorktree(offset: 1) }
    func selectPreviousWorktree() { cycleWorktree(offset: -1) }

    /// Clicking a sidebar row is otherwise the only way to reach another
    /// worktree, which would strand its tabs whenever the sidebar is hidden.
    private func cycleWorktree(offset: Int) {
        guard workspaces.count > 1,
              let current = activeWorkspacePath,
              let index = workspaces.firstIndex(where: { $0.path == current }) else { return }
        activeWorkspacePath = workspaces[(index + offset + workspaces.count) % workspaces.count].path
    }

    private func cycleSession(offset: Int) {
        let scope = visibleSessions
        guard let current = activeSessionID,
              let index = scope.firstIndex(where: { $0.id == current }) else { return }
        activeSessionID = scope[(index + offset + scope.count) % scope.count].id
    }

    /// Runs while the app is terminating, so it must finish synchronously.
    ///
    /// Session rows are deliberately left `live`: the next launch reconciles them
    /// to `interrupted`, which is what restore reads. Closing them here is what
    /// used to make restore a coin flip — a closed row is not restorable, and
    /// whether the close landed at all depended on termination timing.
    func saveAllSessionsForRestore() {
        for (sessionID, host) in hosts {
            guard let snapshot = host.extractSnapshot() else { continue }
            do {
                try core.saveSnapshotForRestore(sessionID: sessionID, snapshot: snapshot)
            } catch {
                NSLog("[CodeSpark] restore snapshot failed for session \(sessionID): \(error)")
            }
        }
    }

    private(set) var closingSessionIDs: Set<String> = []

    func markActiveSessionOutput() {
        guard let id = activeSessionID, let host = hosts[id] else { return }
        host.markOutput()
        resetDebounce(sessionID: id)
    }

    #if GHOSTTY_FIRST
    func handleSurfacePwd(_ surface: UnsafeMutableRawPointer, cwd: String) {
        guard let (sessionID, _) = hosts.first(where: { _, host in
            (host.surfaceNSView as? GhosttyTerminalSurfaceView)?.surface == surface
        }) else { return }
        sessionDidReportCwd(sessionID: sessionID, cwd: cwd)
    }

    func handleSurfaceClose(_ surfaceView: GhosttyTerminalSurfaceView, processAlive: Bool) {
        guard let (sessionID, host) = hosts.first(where: { _, host in
            host.surfaceNSView === surfaceView
        }) else { return }
        guard !closingSessionIDs.contains(sessionID) else { return }
        let snapshot = host.extractSnapshot()
            ?? TerminalSnapshotViewData(cols: 0, rows: 0, lines: [])
        terminalHostDidClose(sessionID: sessionID, snapshot: snapshot, closeReason: .processExited)
    }
    #endif

    /// Projects the user has asked to see every worktree of. Not remembered
    /// across launches: it answers "show me the rest, now", and a tree that
    /// reopened permanently unfolded would defeat the folding.
    @Published private(set) var projectsShowingEveryWorktree: Set<String> = []

    // The two writers of the stored properties above live here rather than in
    // `AppModel+Sidebar.swift`: `private(set)` is file-scoped, so the file that
    // owns the storage owns the writes. Everything that only *reads* them moved.

    func revealFoldedWorktrees(projectID: String) {
        projectsShowingEveryWorktree.insert(projectID)
    }

    func toggleWorktrees(projectID: String) {
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
        } else {
            expandedProjectIDs.insert(projectID)
        }
        UserDefaults.standard.set(
            expandedProjectIDs.sorted().joined(separator: ","),
            forKey: StorageKeys.expandedProjectIDs
        )
    }


    /// Backward-compatible computed property for views that check idle by session ID.
    var idleSessionIDs: Set<String> {
        Set(sessionStates.filter { $0.value == .idle }.map(\.key))
    }

    /// Keep projects[].liveSessionDetails in sync with current liveSessions.
    ///
    /// Keyed on the detail that has landed, because `liveSessions` belongs to
    /// *that* project. `terminalHostDidClose` calls this, so during a switch any
    /// shell exiting stamped the old project's tabs onto the new project's row —
    /// the same field the sidebar reads for every unselected project, and the
    /// one `workspaces(for:)` falls back to.
    func syncProjectSessionDetails() {
        guard let projectID = selectedProject?.id,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].liveSessionDetails = liveSessions.map { session in
            SessionSummary(id: session.id, title: session.title, targetLabel: session.targetLabel, lastCwd: session.lastCwd, workspacePath: session.workspacePath)
        }
        projects[index].liveSessions = liveSessions.count
    }

    private func clearDetailState() {
        selectedProject = nil
        activeSessionID = nil
        liveSessions = []
        workspaces = []
        pendingWorkspaceRecoveryProjectID = nil
    }

}

extension AppModel: TerminalHostDelegate {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        // Always clean up global state regardless of which project is selected
        allSessions.removeAll { $0.id == sessionID }
        hosts.removeValue(forKey: sessionID)
        closingSessionIDs.remove(sessionID)
        debounceTasks[sessionID]?.cancel()
        debounceTasks.removeValue(forKey: sessionID)
        sessionStates.removeValue(forKey: sessionID)

        // Update current project's live sessions if applicable
        if liveSessions.contains(where: { $0.id == sessionID }) {
            // Where focus goes next, decided before the tab is gone — the tab
            // bar's order is the only thing that can answer it.
            //
            // The neighbour on the left, which is where the eye already is. It
            // used to be whichever tab was leftmost, so closing the one you were
            // working in threw you to the far end of the bar to walk back. The
            // leftmost tab has nothing on its left and hands over to its right,
            // the tab that is leftmost now.
            let neighbourID: String? = {
                let bar = workspaces.first { $0.sessions.contains { $0.id == sessionID } }?
                    .sessions.map(\.id) ?? liveSessions.map(\.id)
                guard let index = bar.firstIndex(of: sessionID) else { return nil }
                var rest = bar
                rest.remove(at: index)
                guard !rest.isEmpty else { return nil }
                return rest[max(0, index - 1)]
            }()

            liveSessions.removeAll { $0.id == sessionID }
            recomputeWorkspaces()
            if activeSessionID == sessionID {
                activeSessionID = neighbourID
            }
        }
        syncProjectSessionDetails()

        Task { [weak self] in
            do {
                try await self?.core.recordFinalSnapshotAndClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason)
            } catch {
                NSLog("[CodeSpark] final snapshot failed for session \(sessionID): \(error)")
            }
        }
    }
}
