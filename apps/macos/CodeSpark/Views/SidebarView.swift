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

    private var sortedWorkspaces: [WorkspaceSummaryViewData] {
        let selected = model.selectedWorkspaceID
        let needsInput = model.workspaces.filter {
            model.workspaceStatus(for: $0) == .needsInput && $0.id != selected
        }
        let rest = model.workspaces.filter {
            model.workspaceStatus(for: $0) != .needsInput || $0.id == selected
        }
        let sortedRest = rest.sorted { a, b in
            let sa = model.workspaceStatus(for: a)
            let sb = model.workspaceStatus(for: b)
            if sa == .running && sb == .idle { return true }
            if sa == .idle && sb == .running { return false }
            return false
        }
        if sortedRest.first?.id == selected {
            var result = sortedRest
            result.insert(contentsOf: needsInput, at: min(1, result.count))
            return result
        } else {
            return needsInput + sortedRest
        }
    }

    private var needsInputCount: Int {
        model.workspaces.filter { ws in
            guard ws.id != model.selectedWorkspaceID else { return false }
            return model.workspaceStatus(for: ws) == .needsInput
                && !model.acknowledgedWorkspaceIDs.contains(ws.id)
        }.count
    }

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
                    if needsInputCount > 0 {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                            Text("\(needsInputCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Circle().fill(.red))
                                .offset(x: 5, y: -5)
                        }
                    }
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

            if model.claudeHooksStatus != .installed {
                Button {
                    model.installClaudeHooks()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("Claude hooks not configured")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Install")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sortedWorkspaces.enumerated()), id: \.element.id) { index, workspace in
                        VStack(alignment: .leading, spacing: 0) {
                            WorkspaceSidebarRow(
                                workspace: workspace,
                                isSelected: model.selectedWorkspaceID == workspace.id,
                                isExpanded: expandedWorkspaceIDs.contains(workspace.id),
                                hotkeyIndex: index < 9 && showHotkeys ? index + 1 : nil,
                                status: model.workspaceStatus(for: workspace),
                                infoLine: workspaceInfoLine(for: workspace),
                                snippet: model.hookSnippets[workspace.id]
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleExpanded(workspace.id)
                                model.acknowledgeWorkspace(workspace.id)
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
    var snippet: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                .frame(width: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .accessibilityIdentifier("workspaceName")

                    Spacer()

                    if let hotkeyIndex {
                        Text("\u{2318}\(hotkeyIndex)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    }
                }

                if status == .needsInput {
                    Text(snippet ?? "Claude is waiting for your input")
                        .font(.system(size: 10))
                        .foregroundStyle(status.color.opacity(0.8))
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Image(systemName: status.icon)
                        .font(.system(size: 7))
                        .foregroundStyle(status.color)
                    Text(status.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(status.color)
                }

                if let infoLine {
                    Text(infoLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppTheme.infoText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AppTheme.accentSubtle : AppTheme.sidebarItemBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? AppTheme.accent.opacity(0.5) : .clear, lineWidth: 1)
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
