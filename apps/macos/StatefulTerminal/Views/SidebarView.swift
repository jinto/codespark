import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var expandedWorkspaceIDs: Set<String> = []

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
                                isExpanded: expandedWorkspaceIDs.contains(workspace.id)
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
                if let first = model.workspaces.first {
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(AppTheme.sidebarBackground)
    }
}

struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceSummaryViewData
    let isSelected: Bool
    let isExpanded: Bool

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
                Text(workspace.name)
                    .font(.system(.body, design: .default, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)

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
