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
                    VStack(spacing: 0) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.blue)

                            Text(project.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            if let ws = model.workspaces.first(where: { $0.path == model.selectedWorkspacePath }),
                               model.workspaces.count > 1 {
                                Text("›")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.35))
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.7))
                                Text(ws.branch)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(AppTheme.sidebarBackground)

                        SessionTabBarView(
                            sessions: model.liveSessions,
                            activeSessionID: model.activeSessionID,
                            onSelect: { id in model.activeSessionID = id },
                            onClose: { id in model.closeSession(id: id) },
                            onNew: { Task { await model.newSession() } }
                        )
                        .frame(height: 24)
                        .background(AppTheme.toolbarBackground)
                    }
                }

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
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("No projects open")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Open Project...") {
                    Task { await model.createProjectFromFolder() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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
