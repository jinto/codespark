import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectSummaryViewData] = []
    @Published var selectedProjectID: String?
    @Published var selectedProject: ProjectDetailViewData?
    @Published var activeSessionID: String?
    @Published var liveSessions: [SessionViewData] = []

    /// All sessions across all projects — keeps Ghostty surfaces alive during project switches
    @Published private(set) var allSessions: [SessionViewData] = []
    @Published var loadErrorMessage: String?
    @Published var idleSessionIDs: Set<String> = []
    @Published var pendingCloseSessionID: String?
    @Published var pendingCloseProjectID: String?
    @Published var hiddenProjectIDs: Set<String> = []
    @Published var hiddenProjectNames: [String: String] = [:]
    @Published var gitBranches: [String: String] = [:]
    @Published var hookNeedsInputCwds: Set<String> = []
    @Published var acknowledgedProjectIDs: Set<String> = []
    @Published var hookSnippets: [String: String] = [:]  // projectID → last output snippet
    @Published var claudeHooksStatus: ClaudeHooksStatus = .installed
    @Published var workspaces: [WorkspaceViewData] = []
    @Published var selectedWorkspacePath: String?
    @Published var pendingSSHReconnectProjectID: String?

    var hookServer: HookSocketServer?

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
            host.attach(sessionID: session.id, command: nil)
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
            self.projects = projects

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
        } catch {
            cancelInflightWork()
            projects = []
            selectedProjectID = nil
            clearDetailState()
            loadErrorMessage = error.localizedDescription
        }
    }

    func selectProject(id: String?) async {
        cancelInflightWork()

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
        recomputeWorkspaces()
    }

    func recomputeWorkspaces() {
        guard let project = selectedProject else {
            workspaces = []
            return
        }
        let sessions = liveSessions.map { s in
            SessionSummary(id: s.id, title: s.title, targetLabel: s.targetLabel, lastCwd: s.lastCwd)
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
            if let activeIndex = projects.firstIndex(where: { $0.id == selectedProjectID }) {
                projects.insert(newProject, at: activeIndex + 1)
            } else {
                projects.append(newProject)
            }
            await selectProject(id: newID)
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

    @discardableResult
    private func startAndAttachSession(
        projectID: String,
        transport: String,
        targetLabel: String,
        title: String,
        shell: String,
        cwd: String?,
        command: String? = nil
    ) async throws -> String {
        let sessionID = try await core.startSession(
            projectId: projectID,
            transport: transport,
            targetLabel: targetLabel,
            title: title,
            shell: shell,
            initialCwd: cwd
        )
        let session = SessionViewData(
            id: sessionID,
            title: title,
            targetLabel: targetLabel,
            lastCwd: cwd
        )
        var host = terminalFactory(session)
        host.delegate = self
        host.attach(sessionID: sessionID, command: command)
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
        } else if let selected = selectedWorkspacePath {
            workspacePath = selected
        } else if let activeID = activeSessionID,
                  let activeSession = liveSessions.first(where: { $0.id == activeID }),
                  let activeCwd = activeSession.lastCwd,
                  let matchedWS = workspaces.first(where: { activeCwd == $0.path || activeCwd.hasPrefix($0.path + "/") }) {
            workspacePath = matchedWS.path
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
                    command: info.sshCommand
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
                cwd: workspacePath
            )
            activeSessionID = sessionID
            recomputeWorkspaces()
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Worktree lifecycle

    func addWorktree(branch: String) async {
        guard let project = selectedProject, !project.path.isEmpty else { return }
        let sanitized = branch.replacingOccurrences(of: "/", with: "-")
        do {
            let worktreePath = try await GitWorktreeService.addWorktree(
                projectPath: project.path, name: sanitized, branch: branch
            )
            gitWorktreeService.invalidateCache(for: project.path)
            await gitWorktreeService.refreshWorktrees(for: [project.path])
            recomputeWorkspaces()
            await newSession(inWorkspacePath: worktreePath)
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

    func saveAllSessionsAndClose() {
        let snapshot = Array(hosts)
        for (sessionID, host) in snapshot {
            host.close(sessionID: sessionID)
        }
    }

    private(set) var closingSessionIDs: Set<String> = []

    func markActiveSessionOutput() {
        guard let id = activeSessionID, let host = hosts[id] else { return }
        host.markOutput()
    }

    #if GHOSTTY_FIRST
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
        if project.hasInterruptedSessions { return .needsInput }

        // Hook-based: any live session whose cwd is waiting for input
        let hookNeedsInput = project.liveSessionDetails.contains { session in
            session.lastCwd.map { hookNeedsInputCwds.contains($0) } ?? false
        }
        if hookNeedsInput { return .needsInput }

        if project.liveSessions > 0 {
            let sessionIDs = Set(project.liveSessionDetails.map(\.id))
            let allIdle = !sessionIDs.isEmpty && sessionIDs.isSubset(of: idleSessionIDs)
            return allIdle ? .idle : .running
        }
        return .idle
    }

    /// Keep projects[].liveSessionDetails in sync with current liveSessions.
    func syncProjectSessionDetails() {
        guard let projectID = selectedProjectID,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].liveSessionDetails = liveSessions.map { session in
            SessionSummary(id: session.id, title: session.title, targetLabel: session.targetLabel, lastCwd: session.lastCwd)
        }
        projects[index].liveSessions = liveSessions.count
    }

    private func clearDetailState() {
        selectedProject = nil
        activeSessionID = nil
        liveSessions = []
        workspaces = []
    }

}

extension AppModel: TerminalHostDelegate {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        // Always clean up global state regardless of which project is selected
        allSessions.removeAll { $0.id == sessionID }
        hosts.removeValue(forKey: sessionID)
        closingSessionIDs.remove(sessionID)

        // Update current project's live sessions if applicable
        if let index = liveSessions.firstIndex(where: { $0.id == sessionID }) {
            liveSessions.remove(at: index)
            if activeSessionID == sessionID {
                activeSessionID = liveSessions.isEmpty ? nil : liveSessions[max(0, index - 1)].id
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

