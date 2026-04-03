import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaces: [WorkspaceSummaryViewData] = []
    @Published var selectedWorkspaceID: String?
    @Published var selectedWorkspace: WorkspaceDetailViewData?
    @Published var noteDraft = ""
    @Published var liveSessions: [SessionViewData] = []
    @Published var closedSessions: [ClosedSessionViewData] = []
    @Published var loadErrorMessage: String?
    @Published var noteSaveErrorMessage: String?

    private let core: WorkspaceCoreClientProtocol
    private let terminalFactory: (SessionViewData) -> any TerminalHostProtocol
    private var hosts: [String: any TerminalHostProtocol] = [:]
    private var detailTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(
        core: WorkspaceCoreClientProtocol,
        terminalFactory: @escaping (SessionViewData) -> any TerminalHostProtocol = { _ in NoOpTerminalHost() }
    ) {
        self.core = core
        self.terminalFactory = terminalFactory
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
    }

    func load() async {
        do {
            let workspaces = try await core.listWorkspaceSummaries()
            self.workspaces = workspaces

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

    private func clearDetailState() {
        selectedWorkspace = nil
        noteDraft = ""
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
        // Fire-and-forget: persist snapshot and close event to Rust store
        Task { try? await core.recordFinalSnapshotAndClose(sessionID: sessionID, snapshot: snapshot, closeReason: closeReason) }
    }
}
