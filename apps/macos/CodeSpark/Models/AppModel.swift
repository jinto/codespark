import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectSummaryViewData] = []
    @Published var selectedProjectID: String?
    @Published var selectedProject: ProjectDetailViewData?
    @Published var noteDraft = ""
    @Published var activeSessionID: String?
    @Published var liveSessions: [SessionViewData] = []
    @Published var closedSessions: [ClosedSessionViewData] = []

    /// All sessions across all projects — keeps Ghostty surfaces alive during project switches
    @Published private(set) var allSessions: [SessionViewData] = []
    @Published var loadErrorMessage: String?
    @Published var noteSaveErrorMessage: String?
    @Published var idleSessionIDs: Set<String> = []
    @Published var pendingCloseSessionID: String?
    @Published var pendingCloseProjectID: String?
    @Published var pendingRestoreSessions: [ClosedSessionViewData] = []
    @Published var hiddenProjectIDs: Set<String> = []
    @Published var hiddenProjectNames: [String: String] = [:]
    @Published var gitBranches: [String: String] = [:]
    @Published var hookNeedsInputCwds: Set<String> = []
    @Published var acknowledgedProjectIDs: Set<String> = []
    @Published var hookSnippets: [String: String] = [:]  // projectID → last output snippet
    @Published var claudeHooksStatus: ClaudeHooksStatus = .installed

    var hookServer: HookSocketServer?

    private let core: ProjectCoreClientProtocol
    private let terminalFactory: (SessionViewData) -> any TerminalHostProtocol
    private var hosts: [String: any TerminalHostProtocol] = [:]
    private var detailTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var idleTimer: AnyCancellable?
    private var checkpointTimer: AnyCancellable?
    private var hasReconciledOnLaunch = false
    private let gitBranchService = GitBranchService()

    init(
        core: ProjectCoreClientProtocol,
        terminalFactory: @escaping (SessionViewData) -> any TerminalHostProtocol = { _ in NoOpTerminalHost() }
    ) {
        self.core = core
        self.terminalFactory = terminalFactory
        self.idleTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard NSApp.isActive else { return }
                self?.updateIdleStates()
                self?.refreshGitBranches()
            }
        self.checkpointTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.captureCheckpoints()
            }
    }

    func attachLiveSessions() async {
        guard let project = selectedProject else { return }
        liveSessions = project.liveSessions
        closedSessions = project.closedSessions
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

            if projects.isEmpty {
                let projId = try await core.createProject(name: "Default")
                let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                _ = try await core.startSession(
                    projectId: projId,
                    transport: "local",
                    targetLabel: "local",
                    title: "Terminal",
                    shell: shell,
                    initialCwd: homeDir
                )
                let refreshed = try await core.listProjectSummaries()
                self.projects = refreshed
            }

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

    func saveNote() async {
        guard var project = selectedProject else {
            return
        }

        let task = Task {
            do {
                try await core.updateProjectNote(id: project.id, noteBody: noteDraft)
                guard !Task.isCancelled else { return }
                project.noteBody = noteDraft
                selectedProject = project
                noteSaveErrorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                noteSaveErrorMessage = error.localizedDescription
            }
        }
        saveTask = task
        await task.value
    }

    private func cancelInflightWork() {
        detailTask?.cancel()
        saveTask?.cancel()
    }

    private func apply(detail: ProjectDetailViewData) {
        selectedProject = detail
        noteDraft = detail.noteBody
        liveSessions = detail.liveSessions
        pendingRestoreSessions = detail.closedSessions
        closedSessions = detail.closedSessions
        activeSessionID = liveSessions.first?.id
        noteSaveErrorMessage = nil
    }

    func recoveryActions(for session: ClosedSessionViewData) -> [RecoveryActionViewData] {
        var actions: [RecoveryActionViewData] = []

        actions.append(RecoveryActionViewData(title: "Open local shell here") { [weak self] in
            guard let self else { return }
            Task {
                do { try await self.recoverLocalSession(from: session) }
                catch { self.loadErrorMessage = error.localizedDescription }
            }
        })

        if session.targetLabel != "local" {
            actions.append(RecoveryActionViewData(title: "Reconnect SSH and cd here") { [weak self] in
                guard let self else { return }
                Task {
                    do { try await self.recoverSSHSession(from: session) }
                    catch { self.loadErrorMessage = error.localizedDescription }
                }
            })
        }

        actions.append(RecoveryActionViewData(title: "Copy session recipe") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.restoreRecipe.launchCommand, forType: .string)
        })

        return actions
    }

    func recoverLocalSession(from closed: ClosedSessionViewData) async throws {
        guard let projectID = selectedProjectID else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let title = closed.lastCwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
        let sessionID = try await startAndAttachSession(
            projectID: projectID,
            transport: "local",
            targetLabel: "local",
            title: title,
            shell: shell,
            cwd: closed.lastCwd
        )
        guard selectedProjectID == projectID else { return }
        activeSessionID = sessionID
    }

    func recoverSSHSession(from closed: ClosedSessionViewData) async throws {
        guard let projectID = selectedProjectID else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let sessionID = try await startAndAttachSession(
            projectID: projectID,
            transport: "ssh",
            targetLabel: closed.targetLabel,
            title: closed.title,
            shell: shell,
            cwd: closed.lastCwd,
            command: closed.restoreRecipe.launchCommand
        )
        guard selectedProjectID == projectID else { return }
        activeSessionID = sessionID
    }

    func reopenLastClosedSession() async {
        guard let closed = closedSessions.first else { return }
        do {
            if closed.targetLabel != "local" {
                try await recoverSSHSession(from: closed)
            } else {
                try await recoverLocalSession(from: closed)
            }
            closedSessions.removeFirst()
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func restoreAllClosedSessions() async {
        let sessions = pendingRestoreSessions
        for session in sessions {
            do {
                if session.targetLabel != "local" {
                    try await recoverSSHSession(from: session)
                } else {
                    try await recoverLocalSession(from: session)
                }
                pendingRestoreSessions.removeAll { $0.id == session.id }
                closedSessions.removeAll { $0.id == session.id }
            } catch {
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    func dismissRestorePrompt() {
        pendingRestoreSessions = []
    }

    // MARK: - Project lifecycle

    func createProject(name: String) async {
        do {
            let newID = try await core.createProject(name: name)
            let newProject = ProjectSummaryViewData(
                id: newID,
                name: name,
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
                ProjectDetailViewData(id: $0.id, name: newName, noteBody: $0.noteBody, liveSessions: $0.liveSessions, closedSessions: $0.closedSessions)
            }
        }
        try? await core.renameProject(id: id, newName: newName)
    }

    /// Returns the adjacent project ID (next preferred, then previous).
    private func adjacentProjectID(excluding id: String) -> String? {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return projects.first?.id }
        if index + 1 < projects.count { return projects[index + 1].id }
        if index > 0 { return projects[index - 1].id }
        return nil
    }

    func closeProject(id: String) async {
        let nextID = adjacentProjectID(excluding: id)

        if selectedProjectID == id {
            for session in liveSessions {
                closeSession(id: session.id)
            }
        }

        if let proj = projects.first(where: { $0.id == id }) {
            hiddenProjectNames[id] = proj.name
        }
        hiddenProjectIDs.insert(id)
        projects.removeAll(where: { $0.id == id })

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
        let nextID = adjacentProjectID(excluding: id)

        if selectedProjectID == id {
            for session in liveSessions {
                closeSession(id: session.id)
            }
        }

        projects.removeAll(where: { $0.id == id })

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
            lastCwd: cwd,
            restoreRecipe: RestoreRecipeViewData(launchCommand: command ?? "\(shell) -l")
        )
        liveSessions.append(session)
        if !allSessions.contains(where: { $0.id == sessionID }) {
            allSessions.append(session)
        }
        var host = terminalFactory(session)
        host.delegate = self
        host.attach(sessionID: sessionID, command: command)
        hosts[sessionID] = host
        return sessionID
    }

    func newSession() async {
        guard let projectID = selectedProjectID else { return }
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        do {
            let sessionID = try await startAndAttachSession(
                projectID: projectID,
                transport: "local",
                targetLabel: "local",
                title: "Terminal",
                shell: shell,
                cwd: homeDir
            )
            activeSessionID = sessionID
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
        try? await core.updateSessionTitle(sessionId: id, newTitle: title)
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
        for (sessionID, host) in hosts {
            host.close(sessionID: sessionID)
        }
    }

    private var closingSessionIDs: Set<String> = []

    private func captureCheckpoints() {
        guard !hosts.isEmpty else { return }
        for (sessionID, host) in hosts where !closingSessionIDs.contains(sessionID) {
            guard let snapshot = host.extractSnapshot() else { continue }
            Task { [weak self] in
                try? await self?.core.recordCheckpointSnapshot(sessionID: sessionID, snapshot: snapshot)
            }
        }
    }

    private func updateIdleStates() {
        guard !hosts.isEmpty else { return }
        let threshold = Date().addingTimeInterval(-10)
        let newSet = Set(
            hosts.compactMap { (id, host) in
                guard let lastOutput = host.lastOutputTime else { return id }
                return lastOutput < threshold ? id : nil
            }
        )
        // Detect newly idle sessions for notifications
        let newlyIdle = newSet.subtracting(idleSessionIDs)
        if !newlyIdle.isEmpty {
            sendIdleNotifications(for: newlyIdle)
        }
        if newSet != idleSessionIDs { idleSessionIDs = newSet }
    }

    private func sendIdleNotifications(for sessionIDs: Set<String>) {
        guard NSApp.isActive else { return }
        for sessionID in sessionIDs {
            // Skip if this is the session the user is currently looking at
            guard sessionID != activeSessionID else { continue }
            guard let session = liveSessions.first(where: { $0.id == sessionID }) else { continue }

            let projName = projects.first { proj in
                proj.liveSessionDetails.contains { $0.id == sessionID }
            }?.name ?? "Terminal"

            let content = UNMutableNotificationContent()
            content.title = projName
            content.body = "\(session.title) is waiting for input"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "idle-\(sessionID)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func refreshGitBranches() {
        let paths = projects.flatMap { $0.liveSessionDetails.compactMap(\.lastCwd) }
        guard !paths.isEmpty else { return }
        Task {
            await gitBranchService.refreshBranches(for: paths)
            let updated = Dictionary(
                uniqueKeysWithValues: paths.compactMap { path in
                    gitBranchService.branch(for: path).map { (path, $0) }
                }
            )
            if updated != gitBranches { gitBranches = updated }
        }
    }

    func markActiveSessionOutput() {
        guard let id = activeSessionID, let host = hosts[id] else { return }
        host.markOutput()
    }

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

    // MARK: - Hook event handling

    func handleHookEvent(_ event: ClaudeHookEvent) {
        guard let cwd = event.cwd else { return }
        switch event.hookEventName {
        case "Stop":
            hookNeedsInputCwds.insert(cwd)
            if let proj = projectForCwd(cwd) {
                captureSnippet(for: proj)
                if proj.id != selectedProjectID {
                    sendHookNotification(for: proj, snippet: hookSnippets[proj.id])
                }
            }
        case "UserPromptSubmit":
            hookNeedsInputCwds.remove(cwd)
            if let proj = projectForCwd(cwd) {
                acknowledgedProjectIDs.remove(proj.id)
                hookSnippets.removeValue(forKey: proj.id)
            }
        case "SessionStart":
            hookNeedsInputCwds.remove(cwd)
        case "SessionEnd":
            hookNeedsInputCwds.remove(cwd)
        case "Notification":
            if let proj = projectForCwd(cwd) {
                let snippet = event.message ?? event.title ?? "Claude is waiting for your input"
                hookSnippets[proj.id] = String(snippet.prefix(120))
                hookNeedsInputCwds.insert(cwd)
                if proj.id != selectedProjectID {
                    sendHookNotification(for: proj, snippet: snippet)
                }
            }
        default:
            break
        }
    }

    private func captureSnippet(for project: ProjectSummaryViewData) {
        // Find the host for this project's session and extract last non-empty line
        for session in project.liveSessionDetails {
            guard let host = hosts[session.id],
                  let snapshot = host.extractSnapshot() else { continue }
            let lastLine = snapshot.lines
                .reversed()
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: .whitespaces)
            if let lastLine, !lastLine.isEmpty {
                hookSnippets[project.id] = String(lastLine.prefix(80))
                return
            }
        }
    }

    func acknowledgeProject(_ id: String) {
        acknowledgedProjectIDs.insert(id)
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["hook-needsinput-\(id)"])
    }

    private func projectForCwd(_ cwd: String) -> ProjectSummaryViewData? {
        // Exact match first
        if let proj = projects.first(where: { proj in
            proj.liveSessionDetails.contains { $0.lastCwd == cwd }
        }) { return proj }
        // Prefix fallback
        return projects.first(where: { proj in
            proj.liveSessionDetails.contains { session in
                guard let lastCwd = session.lastCwd else { return false }
                return cwd.hasPrefix(lastCwd) || lastCwd.hasPrefix(cwd)
            }
        })
    }

    private func sendHookNotification(for project: ProjectSummaryViewData, snippet: String? = nil) {
        guard !acknowledgedProjectIDs.contains(project.id) else { return }
        let content = UNMutableNotificationContent()
        content.title = project.name
        content.body = snippet ?? "Claude is waiting for your input"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "hook-needsinput-\(project.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func clearDetailState() {
        selectedProject = nil
        noteDraft = ""
        activeSessionID = nil
        liveSessions = []
        closedSessions = []
        noteSaveErrorMessage = nil
    }

    // MARK: - Claude hooks health check

    func checkClaudeHooksHealth() {
        claudeHooksStatus = ClaudeHooksManager.checkStatus()
    }

    func installClaudeHooks() {
        ClaudeHooksManager.install()
        _ = ClaudeHooksManager.installCLISymlink()
        checkClaudeHooksHealth()
    }
}

struct RecoveryActionViewData {
    let title: String
    let perform: () -> Void
}

extension AppModel: TerminalHostDelegate {
    func terminalHostDidClose(sessionID: String, snapshot: TerminalSnapshotViewData, closeReason: CloseReasonViewData) {
        guard let index = liveSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = liveSessions.remove(at: index)
        allSessions.removeAll { $0.id == sessionID }
        hosts.removeValue(forKey: sessionID)
        closingSessionIDs.remove(sessionID)

        if activeSessionID == sessionID {
            activeSessionID = liveSessions.isEmpty ? nil : liveSessions[max(0, index - 1)].id
        }

        let closed = ClosedSessionViewData(
            id: session.id,
            title: session.title,
            targetLabel: session.targetLabel,
            lastCwd: session.lastCwd,
            closeReason: closeReason,
            snapshotPreview: snapshot,
            restoreRecipe: session.restoreRecipe
        )
        closedSessions.insert(closed, at: 0)
        Task { try? await core.recordFinalSnapshotAndClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason) }
    }
}

extension AppModel: HookSocketServerDelegate {
    func hookServer(_ server: HookSocketServer, didReceive event: ClaudeHookEvent) {
        handleHookEvent(event)
    }
}
