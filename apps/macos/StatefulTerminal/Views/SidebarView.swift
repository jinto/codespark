import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("Spark")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.06))

            // Workspace list
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

            // Footer
            Divider()
                .background(Color.white.opacity(0.06))
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
        .background(Color(nsColor: .init(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)))
    }
}

struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceSummaryViewData
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
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
                .fill(isSelected ? Color.purple.opacity(0.25) : Color.clear)
        )
    }

    private var statusColor: Color {
        if workspace.liveSessions > 0 { return .green }
        if workspace.hasInterruptedSessions { return .orange }
        return .gray.opacity(0.4)
    }
}
