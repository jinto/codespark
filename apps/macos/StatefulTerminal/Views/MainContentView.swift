import SwiftUI

struct MainContentView: View {
    @ObservedObject var model: AppModel
    @State private var showNote = false
    @State private var activePopoverSessionID: String?
    @State private var showCloseConfirm = false

    var body: some View {
        if let workspace = model.selectedWorkspace {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(workspace.name)
                        .font(.system(.title3, weight: .semibold))

                    if !model.liveSessions.isEmpty {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("\(model.liveSessions.count) live")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.1), in: Capsule())
                    }

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showNote.toggle()
                        }
                    } label: {
                        Image(systemName: showNote ? "sidebar.trailing" : "note.text")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle workspace note")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(AppTheme.toolbarBackground)

                Divider().background(AppTheme.divider)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if model.liveSessions.isEmpty && model.closedSessions.isEmpty {
                            emptyState
                        } else {
                            terminalArea
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
    }

    private var terminalArea: some View {
        VStack(spacing: 0) {
            SessionTabBarView(
                sessions: model.liveSessions,
                activeSessionID: model.activeSessionID,
                onSelect: { id in model.activeSessionID = id },
                onClose: { id in model.closeSession(id: id) },
                onNew: { Task { await model.newSession() } }
            )
            Divider().background(AppTheme.divider)

            ZStack {
                ForEach(model.liveSessions) { session in
                    #if GHOSTTY_FIRST
                    if let app = GhosttyRuntime.shared.app {
                        TerminalSurfaceHostView(session: session, app: app)
                            .opacity(session.id == model.activeSessionID ? 1 : 0)
                    }
                    #else
                    TerminalSurfaceHostView(session: session)
                        .opacity(session.id == model.activeSessionID ? 1 : 0)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.closedSessions.isEmpty {
                Divider().background(AppTheme.divider)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.closedSessions) { session in
                            RecentlyClosedSessionCardView(session: session)
                                .frame(width: 260)
                                .popover(isPresented: Binding(
                                    get: { activePopoverSessionID == session.id },
                                    set: { if !$0 { activePopoverSessionID = nil } }
                                )) {
                                    ClosedSessionInspectorView(
                                        session: session,
                                        actions: model.recoveryActions(for: session)
                                    )
                                    .frame(width: 300)
                                }
                                .onTapGesture { activePopoverSessionID = session.id }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .frame(height: 100)
                .background(Color.black.opacity(0.2))
            }
        }
        .onChange(of: model.pendingCloseSessionID) { _, newValue in
            showCloseConfirm = newValue != nil
        }
        .confirmationDialog(
            "Close session?",
            isPresented: $showCloseConfirm,
            titleVisibility: .visible
        ) {
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
