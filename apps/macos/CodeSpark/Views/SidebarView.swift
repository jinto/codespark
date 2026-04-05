import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @AppStorage("expandedWorkspaceIDs") private var expandedRaw: String = ""
    @State private var expandedWorkspaceIDs: Set<String> = []
    @State private var editingWorkspaceID: String?
    @State private var editWorkspaceName = ""
    @State private var pendingDeleteWorkspaceID: String?
    @State private var showDeleteConfirmation = false
    @State private var showHotkeys = false
    @State private var hotkeyMonitor: Any?

    private func toggleExpanded(_ id: String) {
        if expandedWorkspaceIDs.contains(id) {
            expandedWorkspaceIDs.remove(id)
        } else {
            expandedWorkspaceIDs.insert(id)
        }
        expandedRaw = expandedWorkspaceIDs.joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea {
                HStack {
                    Image(systemName: "terminal.fill")
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                    Text("CodeSpark")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }

            Divider().background(AppTheme.divider)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        VStack(alignment: .leading, spacing: 0) {
                            WorkspaceSidebarRow(
                                workspace: workspace,
                                isSelected: model.selectedWorkspaceID == workspace.id,
                                isExpanded: expandedWorkspaceIDs.contains(workspace.id),
                                hotkeyIndex: index < 9 && showHotkeys ? index + 1 : nil,
                                editingWorkspaceID: $editingWorkspaceID,
                                editWorkspaceName: $editWorkspaceName,
                                onRename: { newName in
                                    Task { await model.renameWorkspace(id: workspace.id, newName: newName) }
                                }
                            )
                            .contentShape(Rectangle())
                            .gesture(
                                TapGesture(count: 2).onEnded {
                                    editWorkspaceName = workspace.name
                                    editingWorkspaceID = workspace.id
                                }.exclusively(before:
                                    TapGesture().onEnded {
                                        toggleExpanded(workspace.id)
                                        Task { await model.selectWorkspace(id: workspace.id) }
                                    }
                                )
                            )
                            .contextMenu {
                                Button("Rename") {
                                    editWorkspaceName = workspace.name
                                    editingWorkspaceID = workspace.id
                                }
                                Button("Close Workspace") {
                                    Task { await model.closeWorkspace(id: workspace.id) }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    pendingDeleteWorkspaceID = workspace.id
                                    showDeleteConfirmation = true
                                }
                            }

                            if expandedWorkspaceIDs.contains(workspace.id) {
                                ForEach(workspace.liveSessionDetails) { session in
                                    SessionSidebarRow(
                                        session: session,
                                        isActive: model.activeSessionID == session.id,
                                        isIdle: model.idleSessionIDs.contains(session.id),
                                        onSelect: {
                                            model.activeSessionID = session.id
                                            Task { await model.selectWorkspace(id: workspace.id) }
                                        },
                                        onRename: { newTitle in
                                            Task { await model.renameSession(id: session.id, title: newTitle) }
                                        }
                                    )
                                    .padding(.leading, 18)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .onAppear {
                if !expandedRaw.isEmpty {
                    expandedWorkspaceIDs = Set(expandedRaw.split(separator: ",").map(String.init))
                }
                if expandedWorkspaceIDs.isEmpty, let first = model.workspaces.first {
                    toggleExpanded(first.id)
                }
                hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    showHotkeys = event.modifierFlags.contains(.command)
                    return event
                }
            }
            .onDisappear {
                if let monitor = hotkeyMonitor {
                    NSEvent.removeMonitor(monitor)
                    hotkeyMonitor = nil
                }
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
                if !model.hiddenWorkspaceIDs.isEmpty {
                    Menu {
                        ForEach(Array(model.hiddenWorkspaceIDs), id: \.self) { id in
                            Button(model.hiddenWorkspaceNames[id] ?? id.prefix(8) + "...") {
                                Task { await model.reopenWorkspace(id: id) }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reopen closed workspace")
                }
                Button {
                    Task { await model.createWorkspace(name: "New Workspace") }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New workspace (\u{2318}N)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(AppTheme.sidebarBackground)
        .confirmationDialog(
            "Delete workspace?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteWorkspaceID {
                    Task { await model.deleteWorkspace(id: id) }
                }
                pendingDeleteWorkspaceID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteWorkspaceID = nil
            }
        } message: {
            if let id = pendingDeleteWorkspaceID,
               let ws = model.workspaces.first(where: { $0.id == id }) {
                Text("This will permanently delete \"\(ws.name)\" and all its sessions.")
            }
        }
    }
}

struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceSummaryViewData
    let isSelected: Bool
    let isExpanded: Bool
    let hotkeyIndex: Int?
    @Binding var editingWorkspaceID: String?
    @Binding var editWorkspaceName: String
    let onRename: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                if editingWorkspaceID == workspace.id {
                    TextField("", text: $editWorkspaceName, onCommit: {
                        if !editWorkspaceName.isEmpty {
                            onRename(editWorkspaceName)
                        }
                        editingWorkspaceID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .default, weight: .medium))
                    .onExitCommand { editingWorkspaceID = nil }
                } else {
                    Text(workspace.name)
                        .font(.system(.body, design: .default, weight: .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .accessibilityIdentifier("workspaceName")
                }

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

            if let index = hotkeyIndex {
                Text("⌘\(index)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
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
