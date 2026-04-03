import SwiftUI

struct WorkspaceDetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let workspace = model.selectedWorkspace {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(workspace.name)
                            .font(.largeTitle)

                        ForEach(model.liveSessions) { session in
                            TerminalSurfaceHostView(session: session)
                                .frame(height: 180)
                        }

                        ForEach(model.closedSessions) { session in
                            RecentlyClosedSessionCardView(session: session)
                        }

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        WorkspaceNoteView(noteBody: $model.noteDraft) {
                            Task {
                                await model.saveNote()
                            }
                        }
                        if let noteSaveErrorMessage = model.noteSaveErrorMessage {
                            Text(noteSaveErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(width: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView("Select a workspace", systemImage: "rectangle.on.rectangle")
                    if let loadErrorMessage = model.loadErrorMessage {
                        Text(loadErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(model.selectedWorkspace?.name ?? "Workspace")
    }
}
