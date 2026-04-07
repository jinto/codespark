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
    @State private var showAddWorktreeSheet = false
    @State private var addWorktreeBranch = ""
    @State private var addWorktreeProjectPath = ""
    @State private var pendingRemoveWorktreePath: String?
    @State private var showRemoveWorktreeConfirmation = false
    @State private var showNewSSHSheet = false
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

    @ViewBuilder
    private func flatSessions(for project: ProjectSummaryViewData) -> some View {
        ForEach(project.liveSessionDetails) { session in
            sessionRow(session: session, projectID: project.id)
                .padding(.leading, 18)
        }
    }

    @ViewBuilder
    private func workspaceGroupedSessions(for project: ProjectSummaryViewData) -> some View {
        ForEach(model.workspaces) { workspace in
            WorkspaceSidebarRow(
                workspace: workspace,
                isExpanded: expandedWorkspacePaths.contains(workspace.path),
                isActive: model.activeSessionID.map { id in
                    workspace.sessions.contains { $0.id == id }
                } ?? false
            )
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectedWorkspacePath = workspace.path
                toggleWorkspaceExpanded(workspace.path)
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

            if expandedWorkspacePaths.contains(workspace.path) {
                ForEach(workspace.sessions) { session in
                    sessionRow(session: session, projectID: project.id)
                        .padding(.leading, 30)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(session: SessionSummary, projectID: String) -> some View {
        SessionSidebarRow(
            session: session,
            isActive: model.activeSessionID == session.id,
            isIdle: model.idleSessionIDs.contains(session.id),
            onSelect: {
                if model.selectedProjectID == projectID {
                    model.activeSessionID = session.id
                } else {
                    Task {
                        await model.selectProject(id: projectID)
                        model.activeSessionID = session.id
                    }
                }
            },
            onRename: { newTitle in
                Task { await model.renameSession(id: session.id, title: newTitle) }
            }
        )
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
                            showNewSSHSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                }
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sortedProjects.enumerated()), id: \.element.id) { index, project in
                        VStack(alignment: .leading, spacing: 0) {
                            ProjectSidebarRow(
                                project: project,
                                isSelected: model.selectedProjectID == project.id,
                                isExpanded: expandedProjectIDs.contains(project.id),
                                hotkeyIndex: index < 9 && showHotkeys ? index + 1 : nil,
                                status: model.projectStatus(for: project),
                                infoLine: projectInfoLine(for: project),
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
                                let isSelected = model.selectedProjectID == project.id
                                if isSelected && model.workspaces.count > 1 {
                                    workspaceGroupedSessions(for: project)
                                } else {
                                    flatSessions(for: project)
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
        .sheet(isPresented: $showNewSSHSheet) {
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
                    showNewSSHSheet = false
                    Task {
                        await model.createProject(
                            name: info.displayLabel,
                            path: info.uri,
                            transport: "ssh"
                        )
                    }
                },
                onCancel: { showNewSSHSheet = false }
            )
        }
    }
}

struct ProjectSidebarRow: View {
    let project: ProjectSummaryViewData
    let isSelected: Bool
    let isExpanded: Bool
    let hotkeyIndex: Int?
    let status: ProjectStatus
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
                    Text(project.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .accessibilityIdentifier("projectName")

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

struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceViewData
    let isExpanded: Bool
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 8)

            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? AppTheme.accent : .secondary)

            Text(workspace.branch)
                .font(.system(.caption, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? .white : .primary)
                .lineLimit(1)

            Spacer()

            if !workspace.sessions.isEmpty {
                Text("\(workspace.sessions.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .padding(.leading, 12)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? AppTheme.accentSubtle.opacity(0.5) : .clear)
        )
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
