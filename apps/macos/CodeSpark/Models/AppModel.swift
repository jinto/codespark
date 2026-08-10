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
            // Sync per-workspace selection when activeSessionID changes
            if let path = activeWorkspacePath, let id = activeSessionID {
                workspaceSelectedSessions[path] = id
            }
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
    @Published var workspaces: [WorkspaceViewData] = []
    @Published var selectedWorkspacePath: String?
    @Published private(set) var resumableAgentSessions: [ResumableAgentSession] = []
    @Published var activeWorkspacePath: String? {
        didSet {
            // Restore per-workspace selected session when switching workspaces
            if let path = activeWorkspacePath {
                if let savedID = workspaceSelectedSessions[path],
                   liveSessions.contains(where: { $0.id == savedID }) {
                    activeSessionID = savedID
                } else if let ws = workspaces.first(where: { $0.path == path }),
                          let first = ws.sessions.first {
                    activeSessionID = first.id
                    workspaceSelectedSessions[path] = first.id
                }
            }
        }
    }
    var workspaceSelectedSessions: [String: String] = [:]  // workspacePath → sessionID
    @Published var pendingSSHReconnectProjectID: String?
    @Published var pendingWorkspaceRecoveryProjectID: String?
    @Published var showNewSSHSheet = false

    let core: ProjectCoreClientProtocol
    private let terminalFactory: (SessionViewData) -> any TerminalHostProtocol
    private(set) var hosts: [String: any TerminalHostProtocol] = [:]
    private var detailTask: Task<Void, Never>?
    var idleTimer: AnyCancellable?
    var checkpointTimer: AnyCancellable?
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
                activeSessionID = existingSSH.first?.id
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
        activeSessionID = liveSessions.first?.id
        syncProjectSessionDetails()
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
                if !detail.path.isEmpty && detail.transport != "ssh" {
                    gitWorktreeService.invalidateCache(for: detail.path)
                    await gitWorktreeService.refreshWorktrees(for: [detail.path])
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
        activeSessionID = liveSessions.first?.id
        selectedWorkspacePath = nil
        activeWorkspacePath = detail.path
        recomputeWorkspaces()
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

    func moveProject(id: String, before targetID: String) {
        guard id != targetID,
              let sourceIndex = projects.firstIndex(where: { $0.id == id }),
              let targetIndex = projects.firstIndex(where: { $0.id == targetID }) else { return }

        let project = projects.remove(at: sourceIndex)
        let adjustedTargetIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        projects.insert(project, at: adjustedTargetIndex)
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
        liveSessions.append(session)
        if !allSessions.contains(where: { $0.id == sessionID }) {
            allSessions.append(session)
        }
        syncProjectSessionDetails()
        return sessionID
    }

    func newSession(inWorkspacePath: String? = nil) async {
        guard let projectID = selectedProjectID else { return }
        guard let project = selectedProject else { return }

        let workspacePath: String
        if let explicit = inWorkspacePath {
            workspacePath = explicit
        } else {
            workspacePath = project.path.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : project.path
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // SSH projects: use ssh command instead of local shell
        if project.transport == "ssh", let info = SSHConnectionInfo(uri: project.path) {
            do {
                let sessionID = try await startAndAttachSession(
                    projectID: projectID,
                    transport: "ssh",
                    targetLabel: info.displayLabel,
                    title: info.displayLabel,
                    shell: shell,
                    cwd: nil,
                    workspacePath: project.path,
                    command: info.sshCommand,
                    sshInfo: info
                )
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
            // Populate map first, then set workspace path (didSet restores activeSessionID from map)
            workspaceSelectedSessions[workspacePath] = sessionID
            activeWorkspacePath = workspacePath
            recomputeWorkspaces()
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
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        for interrupted in interruptedSessions {
            do {
                // Replays the tab's previous screen into scrollback, above the
                // prompt the restored shell is about to print.
                let replay = (try? await core.latestSnapshot(sessionID: interrupted.id))
                    .flatMap { RestoredScreenReplay.prepare(snapshot: $0) }

                let sessionID: String
                if project.transport == "ssh", var info = SSHConnectionInfo(uri: project.path) {
                    // Remote shells can't be reopened with a local cwd — land the
                    // ssh session in the directory the tab was last in instead.
                    if let remoteCwd = interrupted.lastCwd, !remoteCwd.isEmpty {
                        info.remotePath = remoteCwd
                    }
                    sessionID = try await startAndAttachSession(
                        projectID: projectID,
                        transport: "ssh",
                        targetLabel: interrupted.targetLabel,
                        title: interrupted.title,
                        shell: shell,
                        cwd: interrupted.lastCwd,
                        workspacePath: interrupted.workspacePath.isEmpty ? project.path : interrupted.workspacePath,
                        command: info.sshCommand,
                        initialInput: replay,
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
                        workspacePath: interrupted.workspacePath.isEmpty ? project.path : interrupted.workspacePath,
                        initialInput: replay
                    )
                }

                if let cwd = interrupted.lastCwd {
                    workspaceSelectedSessions[cwd] = sessionID
                }
                // The tab now lives in `sessionID`. Retiring the row it came from
                // is what stops the next launch restoring it alongside its own
                // replacement — that compounds, doubling tabs every launch.
                try? await core.consumeInterruptedSession(sessionId: interrupted.id)
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
        activeSessionID = liveSessions.last?.id
        recomputeWorkspaces()
    }

    func newAgentSession(_ agent: AgentKind, resumeID: String? = nil) async {
        guard let projectID = selectedProjectID,
              let project = selectedProject,
              project.transport == "local" else { return }

        let workspacePath = activeWorkspacePath ?? project.path
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
            gitWorktreeService.invalidateCache(for: project.path)
            await gitWorktreeService.refreshWorktrees(for: [project.path])
            recomputeWorkspaces()
            await newSession(inWorkspacePath: creation.path)
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func removeWorktree(path: String) async {
        guard let project = selectedProject, !project.path.isEmpty else { return }
        for session in liveSessions {
            let cwd = session.lastCwd ?? ""
            if cwd == path || cwd.hasPrefix(path + "/") {
                closeSession(id: session.id)
            }
        }
        do {
            try await GitWorktreeService.removeWorktree(projectPath: project.path, worktreePath: path)
            gitWorktreeService.invalidateCache(for: project.path)
            await gitWorktreeService.refreshWorktrees(for: [project.path])
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
        guard let index = liveSessions.firstIndex(where: { $0.id == sessionID }),
              liveSessions[index].lastCwd != cwd else { return }
        liveSessions[index].lastCwd = cwd
        recomputeWorkspaces()

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

    private func cycleSession(offset: Int) {
        guard let current = activeSessionID,
              let index = liveSessions.firstIndex(where: { $0.id == current }),
              !liveSessions.isEmpty else { return }
        activeSessionID = liveSessions[(index + offset + liveSessions.count) % liveSessions.count].id
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

    /// Backward-compatible computed property for views that check idle by session ID.
    var idleSessionIDs: Set<String> {
        Set(sessionStates.filter { $0.value == .idle }.map(\.key))
    }

    /// Keep projects[].liveSessionDetails in sync with current liveSessions.
    func syncProjectSessionDetails() {
        guard let projectID = selectedProjectID,
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
            // Find sibling sessions in the same workspace before removal
            let siblingIDs: [String] = {
                guard let ws = workspaces.first(where: { $0.sessions.contains(where: { $0.id == sessionID }) }) else {
                    return liveSessions.filter { $0.id != sessionID }.map(\.id)
                }
                return ws.sessions.filter { $0.id != sessionID }.map(\.id)
            }()

            liveSessions.removeAll { $0.id == sessionID }
            if activeSessionID == sessionID {
                activeSessionID = siblingIDs.first
            }
            recomputeWorkspaces()
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

enum AgentKind: String, CaseIterable, Identifiable, Hashable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var command: String {
        rawValue
    }

    func resumeCommand(id: String) -> String {
        switch self {
        case .claude: "claude --resume \(id)"
        case .codex: "codex resume \(id)"
        }
    }
}

struct ResumableAgentSession: Identifiable, Equatable, Hashable {
    let id: String
    let agent: AgentKind
    let cwd: String
    let lastActivity: Date

    var label: String {
        let shortID = String(id.prefix(8))
        return "\(agent.title) • \(shortID)"
    }
}

enum AgentSessionDiscovery {
    static func discover(for paths: [String]) -> [ResumableAgentSession] {
        let normalizedPaths = Set(paths.map { ($0 as NSString).standardizingPath })
        let claude = normalizedPaths.flatMap { discoverClaude(for: $0) }
        let codex = discoverCodex(for: normalizedPaths)
        return Array(Set(claude + codex)).sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func discoverClaude(for path: String) -> [ResumableAgentSession] {
        let encodedPath = path.replacingOccurrences(of: "/", with: "-")
        let root = ("~/.claude/projects/\(encodedPath)" as NSString).expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }

        return files.filter { $0.hasSuffix(".jsonl") }.compactMap { file in
            let id = String(file.dropLast(6))
            guard !id.isEmpty else { return nil }
            let fullPath = (root as NSString).appendingPathComponent(file)
            return ResumableAgentSession(
                id: id,
                agent: .claude,
                cwd: path,
                lastActivity: modificationDate(of: fullPath)
            )
        }
    }

    private static func discoverCodex(for paths: Set<String>) -> [ResumableAgentSession] {
        let root = ("~/.codex/sessions" as NSString).expandingTildeInPath
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var sessions: [ResumableAgentSession] = []

        for case let relativePath as String in enumerator where relativePath.hasPrefix("rollout-") && relativePath.hasSuffix(".jsonl") {
            let fullPath = (root as NSString).appendingPathComponent(relativePath)
            guard let metadata = firstJSONLine(in: fullPath),
                  metadata["type"] as? String == "session_meta",
                  let payload = metadata["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String,
                  paths.contains((cwd as NSString).standardizingPath) else { continue }

            sessions.append(ResumableAgentSession(
                id: id,
                agent: .codex,
                cwd: cwd,
                lastActivity: modificationDate(of: fullPath)
            ))
        }
        return sessions
    }

    private static func firstJSONLine(in path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384),
              let line = String(data: data, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return json
    }

    private static func modificationDate(of path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}
