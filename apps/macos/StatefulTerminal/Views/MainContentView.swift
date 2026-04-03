import SwiftUI

struct MainContentView: View {
    @ObservedObject var model: AppModel
    @State private var showNote = false

    var body: some View {
        if let workspace = model.selectedWorkspace {
            VStack(spacing: 0) {
                // Toolbar
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
                .background(Color(nsColor: .init(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)))

                Divider().background(Color.white.opacity(0.06))

                // Main area
                HStack(spacing: 0) {
                    // Terminal area
                    VStack(spacing: 0) {
                        if model.liveSessions.isEmpty && model.closedSessions.isEmpty {
                            emptyState
                        } else {
                            terminalArea
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Note inspector
                    if showNote {
                        Divider().background(Color.white.opacity(0.06))
                        noteInspector
                            .frame(width: 280)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .background(Color(nsColor: .init(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)))
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
            .background(Color(nsColor: .init(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)))
        }
    }

    // MARK: - Terminal Area

    private var terminalArea: some View {
        VStack(spacing: 0) {
            // Live sessions — terminal fills available space
            ForEach(model.liveSessions) { session in
                #if GHOSTTY_FIRST
                if let app = GhosttyRuntime.shared.app {
                    TerminalSurfaceHostView(session: session, app: app)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #else
                TerminalSurfaceHostView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }

            // Closed sessions — compact cards at bottom
            if !model.closedSessions.isEmpty {
                Divider().background(Color.white.opacity(0.06))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.closedSessions) { session in
                            RecentlyClosedSessionCardView(session: session)
                                .frame(width: 260)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .frame(height: 100)
                .background(Color.black.opacity(0.2))
            }
        }
    }

    // MARK: - Empty State

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

    // MARK: - Note Inspector

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
                .tint(.purple)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color(nsColor: .init(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)))
    }
}
