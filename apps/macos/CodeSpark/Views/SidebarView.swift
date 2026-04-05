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

    private func workspaceInfoLine(for workspace: WorkspaceSummaryViewData) -> String? {
        guard let cwd = workspace.liveSessionDetails.first?.lastCwd else { return nil }
        let path = abbreviatePath(cwd)
        if let branch = model.gitBranches[cwd] {
            return "\(branch) \u{2022} \(path)"
        }
        return path
    }

    private func abbreviatePath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

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
                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        Task { await model.createWorkspace(name: "New Workspace") }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            if showHotkeys {
                                Text("\u{2318}N")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("New workspace (\u{2318}N)")
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
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
                                status: model.workspaceStatus(for: workspace),
                                infoLine: workspaceInfoLine(for: workspace)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleExpanded(workspace.id)
                                Task { await model.selectWorkspace(id: workspace.id) }
                            }
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
                Text("\(model.workspaces.count) workspace\(model.workspaces.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
        .sheet(isPresented: .init(
            get: { editingWorkspaceID != nil },
            set: { if !$0 { editingWorkspaceID = nil } }
        )) {
            RenameWorkspaceSheet(
                name: $editWorkspaceName,
                onRename: {
                    if let id = editingWorkspaceID, !editWorkspaceName.isEmpty {
                        Task { await model.renameWorkspace(id: id, newName: editWorkspaceName) }
                    }
                    editingWorkspaceID = nil
                },
                onCancel: { editingWorkspaceID = nil }
            )
        }
    }
}

struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceSummaryViewData
    let isSelected: Bool
    let isExpanded: Bool
    let hotkeyIndex: Int?
    let status: WorkspaceStatus
    let infoLine: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(workspace.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .accessibilityIdentifier("workspaceName")

                    Spacer()

                    Text(hotkeyIndex.map { "\u{2318}\($0)" } ?? "")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(hotkeyIndex != nil ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .opacity(hotkeyIndex != nil ? 1 : 0)
                }

                Label(status.label, systemImage: status.icon)
                    .font(.caption2)
                    .foregroundStyle(status.color)

                if let infoLine {
                    Text(infoLine)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.infoText)
                        .lineLimit(1)
                } else {
                    Text(" ").font(.caption2).hidden()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AppTheme.accent.opacity(0.25) : Color.clear)
        )
    }
}

private struct RenameWorkspaceSheet: View {
    @Binding var name: String
    let onRename: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Workspace")
                .font(.headline)
            TextField("Workspace name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(onRename)
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: onRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear { isFocused = true }
    }
}
