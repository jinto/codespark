import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    var onToggleSidebar: () -> Void
    @AppStorage(StorageKeys.expandedProjectIDs) private var expandedRaw: String = ""
    @State private var expandedProjectIDs: Set<String> = []
    @State private var editingProjectID: String?
    @State private var editProjectName = ""
    @State private var pendingDeleteProjectID: String?
    @State private var showDeleteConfirmation = false
    @State private var showHotkeys = false
    @State private var hotkeyMonitor: Any?
    @State private var expandedWorkspacePaths: Set<String> = []
    @State private var showInactiveWorkspaces = false
    @State private var showAddWorktreeSheet = false
    @State private var addWorktreeBranch = ""
    @State private var addWorktreeProjectPath = ""
    @State private var pendingRemoveWorktreePath: String?
    @State private var showRemoveWorktreeConfirmation = false
    @State private var sshHost = ""
    @State private var sshUser = ""
    @State private var sshPort = ""
    @State private var sshRemotePath = ""

    private var sortedProjects: [ProjectSummaryViewData] {
        let selected = model.selectedProjectID
        let needsInput = model.projects.filter {
            model.projectStatus(for: $0) == .needsInput && $0.id != selected
        }
        let rest = model.projects.filter {
            model.projectStatus(for: $0) != .needsInput || $0.id == selected
        }
        let sortedRest = rest.sorted { a, b in
            let sa = model.projectStatus(for: a)
            let sb = model.projectStatus(for: b)
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
        model.projects.filter { proj in
            guard proj.id != model.selectedProjectID else { return false }
            return model.projectStatus(for: proj) == .needsInput
                && !model.acknowledgedProjectIDs.contains(proj.id)
        }.count
    }

    private func projectInfoLine(for project: ProjectSummaryViewData) -> String? {
        if project.transport == "ssh" {
            if let info = SSHConnectionInfo(uri: project.path) {
                return info.displayLabel
            }
            return project.path
        }
        guard let cwd = project.liveSessionDetails.first?.lastCwd else { return nil }
        let path = abbreviatePath(cwd)
        if let branch = model.gitBranches[cwd] {
            return "\(branch) \u{2022} \(path)"
        }
        return path
    }

    private func abbreviatePath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Expand all workspaces with sessions on first encounter (no-op after that).
    private func autoExpandWorkspacesOnce() {
        let currentPaths = Set(model.workspaces.map(\.path))
        guard expandedWorkspacePaths.isDisjoint(with: currentPaths) else { return }
        for ws in model.workspaces where !ws.sessions.isEmpty {
            expandedWorkspacePaths.insert(ws.path)
        }
    }

    private func toggleWorkspaceExpanded(_ path: String) {
        if expandedWorkspacePaths.contains(path) {
            expandedWorkspacePaths.remove(path)
        } else {
            expandedWorkspacePaths.insert(path)
        }
    }

    /// All active workspaces across projects, in sidebar order — for hotkey numbering.
    private var activeWorkspaces: [WorkspaceViewData] {
        guard model.selectedProjectID != nil else { return [] }
        return model.workspaces.filter { !$0.sessions.isEmpty }
    }

    @ViewBuilder
    private func workspaceRows(for project: ProjectSummaryViewData) -> some View {
        let isSelected = model.selectedProjectID == project.id
        if isSelected {
            let active = model.workspaces.filter { !$0.sessions.isEmpty }
            let inactive = model.workspaces.filter { $0.sessions.isEmpty }

            ForEach(active) { workspace in
                WorkspaceSidebarRow(
                    workspace: workspace,
                    isActive: true,
                    isFocused: model.activeWorkspacePath == workspace.path,
                    hotkeyIndex: hotkeyIndex(for: workspace)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    model.activeWorkspacePath = workspace.path
                    model.selectedWorkspacePath = workspace.path
                }
                .contextMenu {
                    Button("New Terminal") {
                        Task { await model.newSession(inWorkspacePath: workspace.path) }
                    }
                    if !workspace.isMainWorktree {
                        Divider()
                        Button("Remove Worktree", role: .destructive) {
                            pendingRemoveWorktreePath = workspace.path
                            showRemoveWorktreeConfirmation = true
                        }
                    }
                }
            }

            if !inactive.isEmpty {
                InactiveWorkspaceSummaryRow(
                    count: inactive.count,
                    workspaces: inactive,
                    isExpanded: showInactiveWorkspaces,
                    onToggle: { showInactiveWorkspaces.toggle() },
                    onSelect: { ws in
                        model.activeWorkspacePath = ws.path
                        model.selectedWorkspacePath = ws.path
                    },
                    onNewTerminal: { ws in
                        Task { await model.newSession(inWorkspacePath: ws.path) }
                    },
                    onRemoveWorktree: { ws in
                        pendingRemoveWorktreePath = ws.path
                        showRemoveWorktreeConfirmation = true
                    }
                )
            }
        } else {
            let branch = model.gitBranches[project.path] ?? "default"
            let isActive = project.liveSessions > 0
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 6, height: 6)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(branch)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if project.liveSessions > 0 {
                    Text("\(project.liveSessions)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .padding(.leading, 16)
        }
    }

    private func hotkeyIndex(for workspace: WorkspaceViewData) -> Int? {
        guard showHotkeys, !workspace.sessions.isEmpty else { return nil }
        guard let idx = activeWorkspaces.firstIndex(where: { $0.id == workspace.id }), idx < 9 else { return nil }
        return idx + 1
    }

    private func toggleExpanded(_ id: String) {
        if expandedProjectIDs.contains(id) {
            expandedProjectIDs.remove(id)
        } else {
            expandedProjectIDs.insert(id)
        }
        expandedRaw = expandedProjectIDs.joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.claudeHooksStatus != .installed {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Initializing...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }

            ScrollView {
                if model.projects.isEmpty {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 40)
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("Open a project folder\nto get started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Open Project...") {
                            Task { await model.createProjectFromFolder() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("SSH Project...") {
                            sshHost = ""; sshUser = ""; sshPort = ""; sshRemotePath = ""
                            model.showNewSSHSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                }
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sortedProjects) { project in
                        VStack(alignment: .leading, spacing: 0) {
                            ProjectSidebarRow(
                                project: project,
                                isSelected: model.selectedProjectID == project.id,
                                isExpanded: expandedProjectIDs.contains(project.id),
                                status: model.projectStatus(for: project),
                                snippet: model.hookSnippets[project.id]
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleExpanded(project.id)
                                model.acknowledgeProject(project.id)
                                Task { await model.selectProject(id: project.id) }
                            }
                            .contextMenu {
                                Button("Rename") {
                                    editProjectName = project.name
                                    editingProjectID = project.id
                                }
                                if !project.path.isEmpty {
                                    Button("Add Worktree...") {
                                        addWorktreeBranch = ""
                                        addWorktreeProjectPath = project.path
                                        showAddWorktreeSheet = true
                                    }
                                }
                                Button("Close Project") {
                                    Task { await model.closeProject(id: project.id) }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    pendingDeleteProjectID = project.id
                                    showDeleteConfirmation = true
                                }
                            }

                            if expandedProjectIDs.contains(project.id) {
                                workspaceRows(for: project)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .onAppear {
                if !expandedRaw.isEmpty {
                    expandedProjectIDs = Set(expandedRaw.split(separator: ",").map(String.init))
                }
                if expandedProjectIDs.isEmpty, let first = model.projects.first {
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
            .onChange(of: model.workspaces) { _, _ in
                autoExpandWorkspacesOnce()
            }

            Spacer()

            Divider().background(AppTheme.divider)
            HStack {
                Text("\(model.projects.count) project\(model.projects.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(AppTheme.sidebarBackground)
        .confirmationDialog(
            "Delete project?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteProjectID {
                    Task { await model.deleteProject(id: id) }
                }
                pendingDeleteProjectID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteProjectID = nil
            }
        } message: {
            if let id = pendingDeleteProjectID,
               let proj = model.projects.first(where: { $0.id == id }) {
                Text("This will permanently delete \"\(proj.name)\" and all its sessions.")
            }
        }
        .sheet(isPresented: .init(
            get: { editingProjectID != nil },
            set: { if !$0 { editingProjectID = nil } }
        )) {
            RenameProjectSheet(
                name: $editProjectName,
                onRename: {
                    if let id = editingProjectID, !editProjectName.isEmpty {
                        Task { await model.renameProject(id: id, newName: editProjectName) }
                    }
                    editingProjectID = nil
                },
                onCancel: { editingProjectID = nil }
            )
        }
        .sheet(isPresented: $showAddWorktreeSheet) {
            AddWorktreeSheet(
                branchName: $addWorktreeBranch,
                projectPath: addWorktreeProjectPath,
                onCreate: {
                    let branch = addWorktreeBranch
                    showAddWorktreeSheet = false
                    Task { await model.addWorktree(branch: branch) }
                },
                onCancel: { showAddWorktreeSheet = false }
            )
        }
        .confirmationDialog(
            "Remove worktree?",
            isPresented: $showRemoveWorktreeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let path = pendingRemoveWorktreePath {
                    Task { await model.removeWorktree(path: path) }
                }
                pendingRemoveWorktreePath = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoveWorktreePath = nil
            }
        } message: {
            if let path = pendingRemoveWorktreePath,
               let ws = model.workspaces.first(where: { $0.path == path }) {
                let count = ws.sessions.count
                Text("This will close \(count) terminal\(count == 1 ? "" : "s") and remove the worktree directory.")
            }
        }
        .sheet(isPresented: $model.showNewSSHSheet) {
            NewSSHProjectSheet(
                host: $sshHost,
                user: $sshUser,
                port: $sshPort,
                remotePath: $sshRemotePath,
                onCreate: {
                    let info = SSHConnectionInfo(
                        host: sshHost,
                        user: sshUser.isEmpty ? nil : sshUser,
                        port: Int(sshPort),
                        remotePath: sshRemotePath.isEmpty ? nil : sshRemotePath
                    )
                    model.showNewSSHSheet = false
                    Task {
                        await model.createProject(
                            name: info.displayLabel,
                            path: info.uri,
                            transport: "ssh"
                        )
                    }
                },
                onCancel: { model.showNewSSHSheet = false }
            )
        }
    }
}

struct ProjectSidebarRow: View {
    let project: ProjectSummaryViewData
    let isSelected: Bool
    let isExpanded: Bool
    let status: ProjectStatus
    var snippet: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                .frame(width: 10)

            Text(project.name)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .accessibilityIdentifier("projectName")

            Spacer()

            if status == .needsInput {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? AppTheme.accentSubtle.opacity(0.3) : .clear)
        )
    }
}

struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceViewData
    let isActive: Bool
    var isFocused: Bool = false
    var hotkeyIndex: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)

            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(isFocused ? AppTheme.accent : .secondary)
                .opacity(isActive || isFocused ? 1 : 0.45)

            Text(workspace.branch)
                .font(.system(.caption, weight: isFocused ? .semibold : .medium))
                .foregroundStyle(isFocused ? .white : .primary)
                .opacity(isActive || isFocused ? 1 : 0.45)
                .lineLimit(1)

            Spacer()

            if !workspace.sessions.isEmpty {
                Text("\(workspace.sessions.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .padding(.leading, 16)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isFocused ? AppTheme.accentSubtle.opacity(0.5) : .clear)
        )
        .overlay(alignment: .trailing) {
            if let hotkeyIndex {
                Text("\u{2318}\(hotkeyIndex)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppTheme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.trailing, 6)
            }
        }
    }
}

struct InactiveWorkspaceSummaryRow: View {
    let count: Int
    let workspaces: [WorkspaceViewData]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSelect: (WorkspaceViewData) -> Void
    let onNewTerminal: (WorkspaceViewData) -> Void
    let onRemoveWorktree: (WorkspaceViewData) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 5, height: 5)
                Text("\(count) inactive")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .padding(.leading, 16)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if isExpanded {
                ForEach(workspaces) { workspace in
                    WorkspaceSidebarRow(workspace: workspace, isActive: false)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(workspace) }
                        .contextMenu {
                            Button("New Terminal") { onNewTerminal(workspace) }
                            if !workspace.isMainWorktree {
                                Divider()
                                Button("Remove Worktree", role: .destructive) { onRemoveWorktree(workspace) }
                            }
                        }
                }
            }
        }
    }
}

private struct RenameProjectSheet: View {
    @Binding var name: String
    let onRename: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Project")
                .font(.headline)
            TextField("Project name", text: $name)
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
