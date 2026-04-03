import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var expandedWorkspaceIDs: Set<String> = []
    @State private var editingWorkspaceID: String?
    @State private var editWorkspaceName = ""
    @State private var pendingDeleteWorkspaceID: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea {
                HStack {
                    Image(systemName: "terminal.fill")
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                    Text("Code Spark")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }

            Divider().background(AppTheme.divider)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 0) {
                            WorkspaceSidebarRow(
                                workspace: workspace,
                                isSelected: model.selectedWorkspaceID == workspace.id,
                                isExpanded: expandedWorkspaceIDs.contains(workspace.id),
                                editingWorkspaceID: $editingWorkspaceID,
                                editWorkspaceName: $editWorkspaceName,
                                onRename: { newName in
                                    Task { await model.renameWorkspace(id: workspace.id, newName: newName) }
                                }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if expandedWorkspaceIDs.contains(workspace.id) {
                                    expandedWorkspaceIDs.remove(workspace.id)
                                } else {
                                    expandedWorkspaceIDs.insert(workspace.id)
                                }
                                Task { await model.selectWorkspace(id: workspace.id) }
                            }
                            .onTapGesture(count: 2) {
                                editWorkspaceName = workspace.name
                                editingWorkspaceID = workspace.id
                            }
                            .contextMenu {
                                Button("Rename") {
                                    editWorkspaceName = workspace.name
                                    editingWorkspaceID = workspace.id
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    pendingDeleteWorkspaceID = workspace.id
                                    showDeleteConfirmation = true
                                }
                            }

                            if expandedWorkspaceIDs.contains(workspace.id) {
                                ForEach(workspace.liveSessionDetails) { session in
                                    SessionSidebarRow(
                                        session: session,
                                        isActive: model.activeSessionID == session.id,
                                        isIdle: model.idleSessionIDs.contains(session.id),
                                        onSelect: {
                                            model.activeSessionID = session.id
                                            Task { await model.selectWorkspace(id: workspace.id) }
                                        },
                                        onRename: { newTitle in
                                            Task { await model.renameSession(id: session.id, title: newTitle) }
                                        }
                                    )
                                    .padding(.leading, 18)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .onAppear {
                if expandedWorkspaceIDs.isEmpty, let first = model.workspaces.first {
                    expandedWorkspaceIDs.insert(first.id)
                }
            }

            Spacer()

            Divider().background(AppTheme.divider)
            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("\(model.workspaces.count) workspace\(model.workspaces.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.createWorkspace(name: "New Workspace") }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New workspace (\u{2318}N)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(AppTheme.sidebarBackground)
        .confirmationDialog(
            "Delete workspace?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteWorkspaceID {
                    Task { await model.deleteWorkspace(id: id) }
                }
                pendingDeleteWorkspaceID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteWorkspaceID = nil
            }
        } message: {
            if let id = pendingDeleteWorkspaceID,
               let ws = model.workspaces.first(where: { $0.id == id }) {
                Text("This will permanently delete \"\(ws.name)\" and all its sessions.")
            }
        }
    }
}

struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceSummaryViewData
    let isSelected: Bool
    let isExpanded: Bool
    @Binding var editingWorkspaceID: String?
    @Binding var editWorkspaceName: String
    let onRename: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                if editingWorkspaceID == workspace.id {
                    TextField("", text: $editWorkspaceName, onCommit: {
                        if !editWorkspaceName.isEmpty {
                            onRename(editWorkspaceName)
                        }
                        editingWorkspaceID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .default, weight: .medium))
                    .onExitCommand { editingWorkspaceID = nil }
                } else {
                    Text(workspace.name)
                        .font(.system(.body, design: .default, weight: .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                }

                HStack(spacing: 6) {
                    if workspace.liveSessions > 0 {
                        Label("\(workspace.liveSessions)", systemImage: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if workspace.recentlyClosedSessions > 0 {
                        Label("\(workspace.recentlyClosedSessions)", systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if workspace.hasInterruptedSessions {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AppTheme.accent.opacity(0.25) : Color.clear)
        )
    }

    private var statusColor: Color {
        if workspace.liveSessions > 0 { return .green }
        if workspace.hasInterruptedSessions { return .orange }
        return .gray.opacity(0.4)
    }
}
