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
    private var selectionRequestID = 0

    init(core: WorkspaceCoreClientProtocol) {
        self.core = core
    }

    func load() async {
        do {
            let workspaces = try await core.listWorkspaceSummaries()
            self.workspaces = workspaces

            guard !workspaces.isEmpty else {
                selectionRequestID += 1
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
            selectionRequestID += 1
            workspaces = []
            selectedWorkspaceID = nil
            clearDetailState()
            loadErrorMessage = error.localizedDescription
        }
    }

    func selectWorkspace(id: String?) async {
        selectionRequestID += 1
        let requestID = selectionRequestID

        guard let id else {
            selectedWorkspaceID = nil
            clearDetailState()
            loadErrorMessage = nil
            return
        }

        selectedWorkspaceID = id

        do {
            let detail = try await core.workspaceDetail(id: id)
            guard requestID == selectionRequestID else {
                return
            }
            apply(detail: detail)
            loadErrorMessage = nil
        } catch {
            guard requestID == selectionRequestID else {
                return
            }
            clearDetailState()
            loadErrorMessage = error.localizedDescription
        }
    }

    func saveNote() async {
        guard var workspace = selectedWorkspace else {
            return
        }

        do {
            try await core.updateWorkspaceNote(id: workspace.id, noteBody: noteDraft)
            workspace.noteBody = noteDraft
            selectedWorkspace = workspace
            noteSaveErrorMessage = nil
        } catch {
            noteSaveErrorMessage = error.localizedDescription
        }
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
