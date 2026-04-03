import AppKit
import Combine
import Foundation

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

    private let core: WorkspaceCoreClientProtocol
    private let terminalFactory: (SessionViewData) -> any TerminalHostProtocol
    private var hosts: [String: any TerminalHostProtocol] = [:]
    private var detailTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var idleTimer: AnyCancellable?

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
            }
    }

    func attachLiveSessions() async {
        guard let workspace = selectedWorkspace else { return }
        liveSessions = workspace.liveSessions
        closedSessions = workspace.closedSessions
        for session in liveSessions {
            var host = terminalFactory(session)
            host.delegate = self
            host.attach(sessionID: session.id)
            hosts[session.id] = host
        }
        activeSessionID = liveSessions.first?.id
    }

    func load() async {
        do {
            let workspaces = try await core.listWorkspaceSummaries()
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
        closedSessions = detail.closedSessions
        activeSessionID = liveSessions.first?.id
        noteSaveErrorMessage = nil
    }

    func recoveryActions(for session: ClosedSessionViewData) -> [RecoveryActionViewData] {
        [
            RecoveryActionViewData(title: "Open local shell here") { [core] in
                Task { try? await core.openLocalShellHere(sessionID: session.id) }
            },
            RecoveryActionViewData(title: "Reconnect SSH") { [core] in
                Task { try? await core.reconnectSSH(sessionID: session.id, cdIntoDirectory: false) }
            },
            RecoveryActionViewData(title: "Reconnect SSH and cd here") { [core] in
                Task { try? await core.reconnectSSH(sessionID: session.id, cdIntoDirectory: true) }
            },
            RecoveryActionViewData(title: "Copy session recipe") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.restoreRecipe.launchCommand, forType: .string)
            },
        ]
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
            host.attach(sessionID: sessionID)
            hosts[sessionID] = host
            activeSessionID = sessionID
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func closeSession(id: String) {
        guard let host = hosts[id] else { return }
        host.close(sessionID: id)
    }

    func renameSession(id: String, title: String) async {
        if let index = liveSessions.firstIndex(where: { $0.id == id }) {
            liveSessions[index] = SessionViewData(
                id: liveSessions[index].id,
                title: title,
                targetLabel: liveSessions[index].targetLabel,
                lastCwd: liveSessions[index].lastCwd,
                restoreRecipe: liveSessions[index].restoreRecipe
            )
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

    private func updateIdleStates() {
        let threshold = Date().addingTimeInterval(-10)
        idleSessionIDs = Set(
            hosts.compactMap { (id, host) in
                guard let lastOutput = host.lastOutputTime else { return id }
                return lastOutput < threshold ? id : nil
            }
        )
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
