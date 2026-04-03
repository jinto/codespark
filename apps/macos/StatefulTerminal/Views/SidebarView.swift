import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
                Text("Spark")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().background(AppTheme.divider)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.workspaces) { workspace in
                        WorkspaceSidebarRow(
                            workspace: workspace,
                            isSelected: model.selectedWorkspaceID == workspace.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await model.selectWorkspace(id: workspace.id) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
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

    var body: some View {
        HStack(spacing: 10) {
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
