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
    private var detailTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(core: WorkspaceCoreClientProtocol) {
        self.core = core
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

    private func clearDetailState() {
        selectedWorkspace = nil
        noteDraft = ""
        liveSessions = []
        closedSessions = []
        noteSaveErrorMessage = nil
    }
}
