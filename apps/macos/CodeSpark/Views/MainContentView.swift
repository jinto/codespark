import SwiftUI

struct MainContentView: View {
    @ObservedObject var model: AppModel
    var onToggleSidebar: (() -> Void)?
    @State private var showCloseSessionAlert = false
    @State private var showCloseProjectAlert = false
    @State private var showAddWorktreeSheet = false
    @State private var newWorktreeBranch = ""

    var body: some View {
        Group {
        if let project = model.selectedProject {
            VStack(spacing: 0) {
                SessionTabBarView(
                    sessions: model.visibleSessions,
                    activeSessionID: model.activeSessionID,
                    onSelect: { id in model.activeSessionID = id },
                    onClose: { id in model.closeSession(id: id) },
                    onNew: { Task { await model.newSession() } },
                    onNewWorktree: {
                        guard model.selectedProject?.transport == "local" else { return }
                        newWorktreeBranch = ""
                        showAddWorktreeSheet = true
                    },
                    canCreateWorktree: project.transport == "local",
                    visitingBranch: { model.visitingBranch(for: $0) }
                )
                .frame(height: 24)

                Divider().background(AppTheme.divider)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if model.pendingSSHReconnectProjectID != nil && model.liveSessions.isEmpty {
                            sshReconnectState
                        } else if model.liveSessions.isEmpty {
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
        .sheet(isPresented: $showAddWorktreeSheet) {
            if let project = model.selectedProject {
                AddWorktreeSheet(
                    branchName: $newWorktreeBranch,
                    projectPath: project.path,
                    onCreate: {
                        let branch = newWorktreeBranch
                        showAddWorktreeSheet = false
                        Task { await model.addWorktree(branch: branch) }
                    },
                    onCancel: { showAddWorktreeSheet = false }
                )
            }
        }
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
        .confirmationDialog(
            "Choose session",
            isPresented: Binding(
                get: { model.pendingWorkspaceRecoveryProjectID != nil },
                set: { if !$0 { model.pendingWorkspaceRecoveryProjectID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let projectID = model.pendingWorkspaceRecoveryProjectID,
               let project = model.selectedProject,
               project.id == projectID {
                let interruptedCount = project.interruptedSessions.count
                if model.liveSessions.isEmpty && interruptedCount > 0 {
                    Button("Restore \(interruptedCount) tab\(interruptedCount == 1 ? "" : "s")") {
                        Task { await model.restoreInterruptedTabs(projectID: projectID) }
                    }
                }

                Button("New Terminal") {
                    model.pendingWorkspaceRecoveryProjectID = nil
                    Task { await model.newSession() }
                }

                Button("New Claude session") {
                    model.pendingWorkspaceRecoveryProjectID = nil
                    Task { await model.newAgentSession(.claude) }
                }

                ForEach(model.resumableAgentSessions.filter { $0.agent == .claude }) { session in
                    Button("Resume \(session.label)") {
                        model.pendingWorkspaceRecoveryProjectID = nil
                        Task { await model.newAgentSession(.claude, resumeID: session.id) }
                    }
                }

                Button("New Codex session") {
                    model.pendingWorkspaceRecoveryProjectID = nil
                    Task { await model.newAgentSession(.codex) }
                }

                ForEach(model.resumableAgentSessions.filter { $0.agent == .codex }) { session in
                    Button("Resume \(session.label)") {
                        model.pendingWorkspaceRecoveryProjectID = nil
                        Task { await model.newAgentSession(.codex, resumeID: session.id) }
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                model.pendingWorkspaceRecoveryProjectID = nil
            }
        } message: {
            Text("Choose what to open in this workspace.")
        }
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(model.allSessions) { session in
                    #if GHOSTTY_FIRST
                    if let surfaceView = model.hosts[session.id]?.surfaceNSView as? GhosttyTerminalSurfaceView {
                        TerminalSurfaceHostView(surfaceView: surfaceView, isActive: session.id == model.activeSessionID)
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

    private var sshReconnectState: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("SSH Project")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let info = model.selectedProject.flatMap({ SSHConnectionInfo(uri: $0.path) }) {
                Text(info.displayLabel)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button("Connect") {
                Task { await model.newSession(); model.focusActiveTerminal() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("New Terminal") {
                Task { await model.newSession(); model.focusActiveTerminal() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
