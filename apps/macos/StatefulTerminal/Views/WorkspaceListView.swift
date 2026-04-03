import SwiftUI

struct WorkspaceListView: View {
    @ObservedObject var model: AppModel

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedWorkspaceID },
            set: { newValue in
                Task {
                    await model.selectWorkspace(id: newValue)
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            ForEach(model.workspaces) { workspace in
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.name)
                        .font(.headline)
                    Text("\(workspace.liveSessions) live · \(workspace.recentlyClosedSessions) closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    if workspace.hasInterruptedSessions {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
                .tag(workspace.id as String?)
            }
        }
        .navigationTitle("Workspaces")
    }
}
