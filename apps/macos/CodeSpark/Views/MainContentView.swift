import SwiftUI

struct MainContentView: View {
    @ObservedObject var model: AppModel
    // Note panel removed in project simplification
    @State private var showCloseSessionAlert = false
    @State private var showCloseProjectAlert = false

    var body: some View {
        Group {
        if let project = model.selectedProject {
            VStack(spacing: 0) {
                WindowDragArea {
                    HStack(spacing: 0) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                            .padding(.leading, 16)
                            .padding(.trailing, 6)

                        Text(project.name)
                            .font(.system(.caption, weight: .semibold))
                            .lineLimit(1)

                        Divider()
                            .frame(height: 14)
                            .padding(.horizontal, 8)

                        SessionTabBarView(
                            sessions: model.liveSessions,
                            activeSessionID: model.activeSessionID,
                            onSelect: { id in model.activeSessionID = id },
                            onClose: { id in model.closeSession(id: id) },
                            onNew: { Task { await model.newSession() } }
                        )

                        Spacer()

                    }
                    .frame(height: 34)
                }
                .frame(height: 34)
                .background(AppTheme.toolbarBackground)

                Divider().background(AppTheme.divider)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if model.liveSessions.isEmpty {
                            emptyState
                        } else {
                            terminalContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                }
            }
            .background(AppTheme.surfaceBackground)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("Select a project")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let err = model.loadErrorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.surfaceBackground)
        }
        } // Group
        .onChange(of: model.pendingCloseSessionID) { _, newValue in
            showCloseSessionAlert = newValue != nil
        }
        .alert("Close session?", isPresented: $showCloseSessionAlert) {
            Button("Close", role: .destructive) {
                if let id = model.pendingCloseSessionID {
                    model.closeSession(id: id)
                }
                model.pendingCloseSessionID = nil
            }
            Button("Cancel", role: .cancel) {
                model.pendingCloseSessionID = nil
            }
        } message: {
            Text("This will close the terminal process.")
        }
        .onChange(of: model.pendingCloseProjectID) { _, newValue in
            showCloseProjectAlert = newValue != nil
        }
        .alert("Close project?", isPresented: $showCloseProjectAlert) {
            Button("Close", role: .destructive) {
                if let id = model.pendingCloseProjectID {
                    Task { await model.closeProject(id: id) }
                }
                model.pendingCloseProjectID = nil
            }
            Button("Cancel", role: .cancel) {
                model.pendingCloseProjectID = nil
            }
        } message: {
            Text("Sessions will be closed. You can reopen this project later.")
        }
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(model.allSessions) { session in
                    #if GHOSTTY_FIRST
                    if let app = GhosttyRuntime.shared.app {
                        TerminalSurfaceHostView(session: session, app: app, isActive: session.id == model.activeSessionID)
                    }
                    #else
                    TerminalSurfaceHostView(session: session, isActive: session.id == model.activeSessionID)
                        .opacity(session.id == model.activeSessionID ? 1 : 0)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("No sessions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Sessions will appear here when started")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
