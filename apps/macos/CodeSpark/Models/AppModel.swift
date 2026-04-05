import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaces: [WorkspaceSummaryViewData] = []
    @Published var selectedWorkspaceID: String?
    @Published var selectedWorkspace: WorkspaceDetailViewData?
    @Published var noteDraft = ""
    @Published var activeSessionID: String?
    @Published var liveSessions: [SessionViewData] = []
    @Published var closedSessions: [ClosedSessionViewData] = []
    @Published var loadErrorMessage: String?
    @Published var noteSaveErrorMessage: String?
    @Published var idleSessionIDs: Set<String> = []
    @Published var pendingCloseSessionID: String?
    @Published var pendingCloseWorkspaceID: String?
    @Published var pendingRestoreSessions: [ClosedSessionViewData] = []
    @Published var hiddenWorkspaceIDs: Set<String> = []
    @Published var hiddenWorkspaceNames: [String: String] = [:]
    @Published var gitBranches: [String: String] = [:]

    private let core: WorkspaceCoreClientProtocol
    private let terminalFactory: (SessionViewData) -> any TerminalHostProtocol
    private var hosts: [String: any TerminalHostProtocol] = [:]
    private var detailTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var idleTimer: AnyCancellable?
    private var checkpointTimer: AnyCancellable?
    private var hasReconciledOnLaunch = false
    private let gitBranchService = GitBranchService()

    init(
        core: WorkspaceCoreClientProtocol,
        terminalFactory: @escaping (SessionViewData) -> any TerminalHostProtocol = { _ in NoOpTerminalHost() }
    ) {
        self.core = core
        self.terminalFactory = terminalFactory
        self.idleTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
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
        guard let workspace = selectedWorkspace else { return }
        liveSessions = workspace.liveSessions
        closedSessions = workspace.closedSessions
        for session in liveSessions {
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
            let allWorkspaces = try await core.listWorkspaceSummaries()
            let workspaces = allWorkspaces.filter { !hiddenWorkspaceIDs.contains($0.id) }
            self.workspaces = workspaces

            if workspaces.isEmpty {
                let wsId = try await core.createWorkspace(name: "Default")
                let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                _ = try await core.startSession(
                    workspaceId: wsId,
                    transport: "local",
                    targetLabel: "local",
                    title: "Terminal",
                    shell: shell,
                    initialCwd: homeDir
                )
                let refreshed = try await core.listWorkspaceSummaries()
                self.workspaces = refreshed
            }

            guard !workspaces.isEmpty else {
                cancelInflightWork()
                selectedWorkspaceID = nil
                clearDetailState()
                loadErrorMessage = nil
                return
            }

            let resolvedWorkspaceID = if let selectedWorkspaceID,
                                         workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
                selectedWorkspaceID
            } else {
                workspaces[0].id
            }

            await selectWorkspace(id: resolvedWorkspaceID)
        } catch {
            cancelInflightWork()
            workspaces = []
            selectedWorkspaceID = nil
            clearDetailState()
            loadErrorMessage = error.localizedDescription
        }
    }

    func selectWorkspace(id: String?) async {
        cancelInflightWork()

        guard let id else {
            selectedWorkspaceID = nil
            clearDetailState()
            loadErrorMessage = nil
            return
        }

        selectedWorkspaceID = id

        let task = Task {
            do {
                let detail = try await core.workspaceDetail(id: id)
                guard !Task.isCancelled else { return }
                apply(detail: detail)
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
        guard var workspace = selectedWorkspace else {
            return
        }

        let task = Task {
            do {
                try await core.updateWorkspaceNote(id: workspace.id, noteBody: noteDraft)
                guard !Task.isCancelled else { return }
                workspace.noteBody = noteDraft
                selectedWorkspace = workspace
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

    private func apply(detail: WorkspaceDetailViewData) {
        selectedWorkspace = detail
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
            Task { await self.recoverLocalSession(from: session) }
        })

        if session.targetLabel != "local" {
            actions.append(RecoveryActionViewData(title: "Reconnect SSH and cd here") { [weak self] in
                guard let self else { return }
                Task { await self.recoverSSHSession(from: session) }
            })
        }

        actions.append(RecoveryActionViewData(title: "Copy session recipe") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.restoreRecipe.launchCommand, forType: .string)
        })

        return actions
    }

    func recoverLocalSession(from closed: ClosedSessionViewData) async {
        guard let workspaceID = selectedWorkspaceID else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        do {
            let sessionID = try await core.startSession(
                workspaceId: workspaceID,
                transport: "local",
                targetLabel: "local",
                title: closed.lastCwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal",
                shell: shell,
                initialCwd: closed.lastCwd
            )
            guard selectedWorkspaceID == workspaceID else { return }
            let session = SessionViewData(
                id: sessionID,
                title: closed.lastCwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal",
                targetLabel: "local",
                lastCwd: closed.lastCwd,
                restoreRecipe: RestoreRecipeViewData(launchCommand: "\(shell) -l")
            )
            liveSessions.append(session)
            var host = terminalFactory(session)
            host.delegate = self
            host.attach(sessionID: sessionID, command: nil)
            hosts[sessionID] = host
            activeSessionID = sessionID
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func recoverSSHSession(from closed: ClosedSessionViewData) async {
        guard let workspaceID = selectedWorkspaceID else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        do {
            let sessionID = try await core.startSession(
                workspaceId: workspaceID,
                transport: "ssh",
                targetLabel: closed.targetLabel,
                title: closed.title,
                shell: shell,
                initialCwd: closed.lastCwd
            )
            guard selectedWorkspaceID == workspaceID else { return }
            let session = SessionViewData(
                id: sessionID,
                title: closed.title,
                targetLabel: closed.targetLabel,
                lastCwd: closed.lastCwd,
                restoreRecipe: closed.restoreRecipe
            )
            liveSessions.append(session)
            var host = terminalFactory(session)
            host.delegate = self
            host.attach(sessionID: sessionID, command: closed.restoreRecipe.launchCommand)
            hosts[sessionID] = host
            activeSessionID = sessionID
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func reopenLastClosedSession() async {
        guard let closed = closedSessions.first else { return }
        closedSessions.removeFirst()
        if closed.targetLabel != "local" {
            await recoverSSHSession(from: closed)
        } else {
            await recoverLocalSession(from: closed)
        }
    }

    func restoreAllClosedSessions() async {
        let sessions = pendingRestoreSessions
        pendingRestoreSessions = []
        closedSessions = []
        for session in sessions {
            if session.targetLabel != "local" {
                await recoverSSHSession(from: session)
            } else {
                await recoverLocalSession(from: session)
            }
        }
    }

    func dismissRestorePrompt() {
        pendingRestoreSessions = []
    }

    // MARK: - Workspace lifecycle

    func createWorkspace(name: String) async {
        do {
            let newID = try await core.createWorkspace(name: name)
            let newWorkspace = WorkspaceSummaryViewData(
                id: newID,
                name: name,
                liveSessions: 0,
                recentlyClosedSessions: 0,
                hasInterruptedSessions: false,
                liveSessionDetails: []
            )
            if let activeIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) {
                workspaces.insert(newWorkspace, at: activeIndex + 1)
            } else {
                workspaces.append(newWorkspace)
            }
            await selectWorkspace(id: newID)
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func renameWorkspace(id: String, newName: String) async {
        if let index = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[index].name = newName
        }
        if selectedWorkspace?.id == id {
            selectedWorkspace = selectedWorkspace.map {
                WorkspaceDetailViewData(id: $0.id, name: newName, noteBody: $0.noteBody, liveSessions: $0.liveSessions, closedSessions: $0.closedSessions)
            }
        }
        try? await core.renameWorkspace(id: id, newName: newName)
    }

    func closeWorkspace(id: String) async {
        if selectedWorkspaceID == id {
            for session in liveSessions {
                closeSession(id: session.id)
            }
        }

        if let ws = workspaces.first(where: { $0.id == id }) {
            hiddenWorkspaceNames[id] = ws.name
        }
        hiddenWorkspaceIDs.insert(id)
        workspaces.removeAll(where: { $0.id == id })

        if selectedWorkspaceID == id {
            if let next = workspaces.first {
                await selectWorkspace(id: next.id)
            } else {
                await selectWorkspace(id: nil)
            }
        }
    }

    func reopenWorkspace(id: String) async {
        hiddenWorkspaceIDs.remove(id)
        hiddenWorkspaceNames.removeValue(forKey: id)
        await load()
        await selectWorkspace(id: id)
    }

    func deleteWorkspace(id: String) async {
        if selectedWorkspaceID == id {
            for session in liveSessions {
                closeSession(id: session.id)
            }
        }

        workspaces.removeAll(where: { $0.id == id })

        var deleteError: String?
        do {
            try await core.deleteWorkspace(id: id)
        } catch {
            deleteError = error.localizedDescription
        }

        if selectedWorkspaceID == id {
            if let next = workspaces.first {
                await selectWorkspace(id: next.id)
            } else {
                await selectWorkspace(id: nil)
            }
        }

        if let deleteError {
            loadErrorMessage = deleteError
        }
    }

    // MARK: - Session lifecycle

    func newSession() async {
        guard let workspaceID = selectedWorkspaceID else { return }
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        do {
            let sessionID = try await core.startSession(
                workspaceId: workspaceID,
                transport: "local",
                targetLabel: "local",
                title: "Terminal",
                shell: shell,
                initialCwd: homeDir
            )
            let session = SessionViewData(
                id: sessionID,
                title: "Terminal",
                targetLabel: "local",
                lastCwd: homeDir,
                restoreRecipe: RestoreRecipeViewData(launchCommand: "\(shell) -l")
            )
            liveSessions.append(session)
            var host = terminalFactory(session)
            host.delegate = self
            host.attach(sessionID: sessionID, command: nil)
            hosts[sessionID] = host
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

            let wsName = workspaces.first { ws in
                ws.liveSessionDetails.contains { $0.id == sessionID }
            }?.name ?? "Terminal"

            let content = UNMutableNotificationContent()
            content.title = wsName
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
        let paths = workspaces.flatMap { $0.liveSessionDetails.compactMap(\.lastCwd) }
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

    func workspaceStatus(for workspace: WorkspaceSummaryViewData) -> WorkspaceStatus {
        if workspace.hasInterruptedSessions { return .needsInput }
        if workspace.liveSessions > 0 {
            let sessionIDs = Set(workspace.liveSessionDetails.map(\.id))
            let allIdle = !sessionIDs.isEmpty && sessionIDs.isSubset(of: idleSessionIDs)
            return allIdle ? .idle : .running
        }
        return .idle
    }

    private func clearDetailState() {
        selectedWorkspace = nil
        noteDraft = ""
        activeSessionID = nil
        liveSessions = []
        closedSessions = []
        noteSaveErrorMessage = nil
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
