import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    var onToggleSidebar: () -> Void
    @State private var editingProjectID: String?
    @State private var editProjectName = ""
    @State private var pendingDeleteProjectID: String?
    @State private var showDeleteConfirmation = false
    @State private var showHotkeys = false
    @State private var hotkeyMonitor: Any?
    @State private var sshHost = ""
    @State private var sshUser = ""
    @State private var sshPort = ""
    @State private var sshRemotePath = ""
    @State private var changeFolderProjectID: String?
    @State private var changeFolderPath = ""
    /// Where a dragged row would land right now — nil when nothing is over the list.
    @State private var dropTarget: ProjectDropTarget?

    private func projectInfoLine(for project: ProjectSummaryViewData) -> String? {
        if project.transport == "ssh" {
            if let info = SSHConnectionInfo(uri: project.path) {
                return info.displayLabel
            }
            return project.path
        }
        guard !project.path.isEmpty else { return nil }
        if let branch = model.gitBranches[project.path] {
            return branch
        }
        return abbreviatePath(project.path)
    }

    private func abbreviatePath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func hotkeyIndex(for project: ProjectSummaryViewData) -> Int? {
        guard showHotkeys else { return nil }
        guard let idx = model.orderedProjects.firstIndex(where: { $0.id == project.id }), idx < 9 else { return nil }
        return idx + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.orderedProjects) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            ProjectSidebarRow(
                                project: project,
                                isSelected: model.selectedProjectID == project.id,
                                status: model.projectStatus(for: project),
                                infoLine: projectInfoLine(for: project),
                                hotkeyIndex: hotkeyIndex(for: project),
                                isExpanded: model.sidebarWorktrees(for: project).isEmpty
                                    ? nil
                                    : model.expandedProjectIDs.contains(project.id),
                                onToggleExpansion: { model.toggleWorktrees(projectID: project.id) }
                            )
                            .contentShape(Rectangle())
                            .overlay(alignment: .top) {
                                DropInsertionLine(isShowing: dropTarget == .before(project.id))
                            }
                            .draggable(project.id)
                            .dropDestination(for: String.self) { droppedIDs, _ in
                                dropTarget = nil
                                guard let draggedID = droppedIDs.first else { return false }
                                model.moveProject(id: draggedID, to: .before(project.id))
                                return true
                            } isTargeted: { targeted in
                                // Nothing else can clear it: the row that loses the
                                // pointer is the one that reports leaving.
                                if targeted {
                                    dropTarget = .before(project.id)
                                } else if dropTarget == .before(project.id) {
                                    dropTarget = nil
                                }
                            }
                            .onTapGesture {
                                Task { await model.selectProject(id: project.id, promptForRecovery: true) }
                            }
                            .onTapGesture(count: 2) {
                                Task {
                                    await model.selectProject(id: project.id)
                                    model.presentSessionChooser()
                                }
                            }
                            .contextMenu {
                                Button("Rename") {
                                    editProjectName = project.name
                                    editingProjectID = project.id
                                }
                                if project.transport == "ssh" {
                                    Button("Change Remote Folder...") {
                                        if let info = SSHConnectionInfo(uri: project.path) {
                                            changeFolderPath = info.remotePath ?? ""
                                        } else {
                                            changeFolderPath = ""
                                        }
                                        changeFolderProjectID = project.id
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

                            // Shown while the project is expanded, selected or not:
                            // switching projects must not fold someone's tree.
                            if model.expandedProjectIDs.contains(project.id) {
                                ForEach(model.sidebarWorktrees(for: project)) { workspace in
                                    WorktreeSidebarRow(
                                        workspace: workspace,
                                        isSelected: model.selectedProjectID == project.id
                                            && model.activeWorkspacePath == workspace.path,
                                        status: model.workspaceStatus(for: workspace)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        Task {
                                            await model.selectWorktree(
                                                projectID: project.id,
                                                path: workspace.path
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Past the last row there is nothing to sit in front of, so
                    // the end of the list needs a target of its own.
                    if !model.projects.isEmpty {
                        Color.clear
                            .frame(height: 24)
                            .overlay(alignment: .top) {
                                DropInsertionLine(isShowing: dropTarget == .end)
                            }
                            .dropDestination(for: String.self) { droppedIDs, _ in
                                dropTarget = nil
                                guard let draggedID = droppedIDs.first else { return false }
                                model.moveProject(id: draggedID, to: .end)
                                return true
                            } isTargeted: { targeted in
                                if targeted {
                                    dropTarget = .end
                                } else if dropTarget == .end {
                                    dropTarget = nil
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .onAppear {
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
        .sheet(isPresented: .init(
            get: { changeFolderProjectID != nil },
            set: { if !$0 { changeFolderProjectID = nil } }
        )) {
            if let projectID = changeFolderProjectID,
               let project = model.projects.first(where: { $0.id == projectID }),
               let info = SSHConnectionInfo(uri: project.path) {
                ChangeRemoteFolderSheet(
                    host: info.displayLabel,
                    remotePath: $changeFolderPath,
                    sshInfo: info,
                    onSave: {
                        let updatedInfo = SSHConnectionInfo(
                            host: info.host,
                            user: info.user,
                            port: info.port,
                            remotePath: changeFolderPath.isEmpty ? nil : changeFolderPath
                        )
                        Task {
                            await model.updateProjectPath(id: projectID, newPath: updatedInfo.uri)
                        }
                        changeFolderProjectID = nil
                    },
                    onCancel: { changeFolderProjectID = nil }
                )
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
    let status: ProjectStatus
    var infoLine: String? = nil
    var hotkeyIndex: Int? = nil
    /// nil when the repo has a single worktree — there is no tree to open.
    var isExpanded: Bool? = nil
    var onToggleExpansion: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let isExpanded {
                    Button(action: onToggleExpansion) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 8, height: 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("worktreeDisclosure")
                }

                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)

                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .accessibilityIdentifier("projectName")

                Spacer()

                if project.liveSessions > 0 {
                    Text("\(project.liveSessions)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.10), in: Capsule())
                        .layoutPriority(-1)
                }
            }

            if let info = infoLine {
                Text(info)
                    .font(.system(size: 10))
                    .foregroundStyle(
                        status == .needsInput
                            ? status.color
                            : (isSelected ? .white.opacity(0.6) : .white.opacity(0.4))
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? AppTheme.accent.opacity(0.3) : Color.white.opacity(0.04))
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

/// Where a dragged project row would land. Drawn on top of a row rather than
/// between rows, so the list never shifts under the pointer while you aim.
private struct DropInsertionLine: View {
    let isShowing: Bool

    var body: some View {
        Capsule()
            .fill(AppTheme.accent)
            .frame(height: 2)
            .padding(.horizontal, 4)
            .offset(y: -2)
            .opacity(isShowing ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isShowing)
            .allowsHitTesting(false)
    }
}

/// A worktree nested under its project. Only drawn when the repo has more than
/// one — a lone worktree is the project row itself.
struct WorktreeSidebarRow: View {
    let workspace: WorkspaceViewData
    let isSelected: Bool
    let status: ProjectStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 5, height: 5)

            Text(workspace.branch)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("worktreeBranch")

            Spacer()

            if !workspace.sessions.isEmpty {
                Text("\(workspace.sessions.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    // Two characters that must stay readable — a long branch name
                    // truncates instead of shaving the badge down to a sliver.
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? AppTheme.accent.opacity(0.22) : Color.white.opacity(0.02))
        )
        .padding(.leading, 12)
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

private struct ChangeRemoteFolderSheet: View {
    let host: String
    @Binding var remotePath: String
    let sshInfo: SSHConnectionInfo
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    private var previewCommand: String {
        SSHConnectionInfo(
            host: sshInfo.host,
            user: sshInfo.user,
            port: sshInfo.port,
            remotePath: remotePath.isEmpty ? nil : remotePath
        ).sshCommand()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Remote Folder")
                .font(.headline)

            Text(host)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("/home/user/project", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(onSave)
            }

            Text(previewCommand)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }
}
