import SwiftUI

struct MainContentView: View {
    @ObservedObject var model: AppModel
    @State private var showNote = false
    @State private var activePopoverSessionID: String?
    @State private var showCloseSessionAlert = false
    @State private var showCloseWorkspaceAlert = false

    var body: some View {
        Group {
        if let workspace = model.selectedWorkspace {
            VStack(spacing: 0) {
                WindowDragArea {
                    HStack(spacing: 0) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                            .padding(.leading, 16)
                            .padding(.trailing, 6)

                        Text(workspace.name)
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

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showNote.toggle()
                            }
                        } label: {
                            Image(systemName: showNote ? "sidebar.trailing" : "note.text")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle workspace note")
                        .padding(.trailing, 12)
                    }
                    .frame(height: 34)
                }
                .frame(height: 34)
                .background(AppTheme.toolbarBackground)

                Divider().background(AppTheme.divider)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if model.liveSessions.isEmpty && model.closedSessions.isEmpty {
                            emptyState
                        } else {
                            terminalContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showNote {
                        Divider().background(AppTheme.divider)
                        noteInspector
                            .frame(width: 280)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .background(AppTheme.surfaceBackground)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("Select a workspace")
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
        .onChange(of: model.pendingCloseWorkspaceID) { _, newValue in
            showCloseWorkspaceAlert = newValue != nil
        }
        .alert("Close workspace?", isPresented: $showCloseWorkspaceAlert) {
            Button("Close", role: .destructive) {
                if let id = model.pendingCloseWorkspaceID {
                    Task { await model.closeWorkspace(id: id) }
                }
                model.pendingCloseWorkspaceID = nil
            }
            Button("Cancel", role: .cancel) {
                model.pendingCloseWorkspaceID = nil
            }
        } message: {
            Text("Sessions will be closed. You can reopen this workspace later.")
        }
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(model.liveSessions) { session in
                    #if GHOSTTY_FIRST
                    if let app = GhosttyRuntime.shared.app {
                        TerminalSurfaceHostView(session: session, app: app, isActive: session.id == model.activeSessionID)
                            .opacity(session.id == model.activeSessionID ? 1 : 0)
                    }
                    #else
                    TerminalSurfaceHostView(session: session, isActive: session.id == model.activeSessionID)
                        .opacity(session.id == model.activeSessionID ? 1 : 0)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.pendingRestoreSessions.isEmpty {
                Divider().background(AppTheme.divider)
                HStack(spacing: 12) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.pendingRestoreSessions.count) previous session\(model.pendingRestoreSessions.count == 1 ? "" : "s")")
                            .font(.system(.body, weight: .medium))
                        Text("Restore them?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") {
                        Task { await model.restoreAllClosedSessions() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .controlSize(.small)
                    Button("Dismiss") {
                        model.dismissRestorePrompt()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.2))
            }
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

    private var noteInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                Text("Note")
                    .font(.system(.subheadline, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            TextEditor(text: $model.noteDraft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)

            HStack {
                if let err = model.noteSaveErrorMessage {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
                Spacer()
                Button("Save") {
                    Task { await model.saveNote() }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(AppTheme.toolbarBackground)
    }
}
