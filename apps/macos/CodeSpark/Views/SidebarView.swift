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

    private func hotkeyIndex(for project: ProjectSummaryViewData) -> Int? {
        guard showHotkeys else { return nil }
        guard let idx = sortedProjects.firstIndex(where: { $0.id == project.id }), idx < 9 else { return nil }
        return idx + 1
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
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(sortedProjects) { project in
                        ProjectSidebarRow(
                            project: project,
                            isSelected: model.selectedProjectID == project.id,
                            status: model.projectStatus(for: project),
                            snippet: model.hookSnippets[project.id],
                            infoLine: projectInfoLine(for: project),
                            hotkeyIndex: hotkeyIndex(for: project)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.acknowledgeProject(project.id)
                            Task { await model.selectProject(id: project.id) }
                        }
                        .contextMenu {
                            Button("Rename") {
                                editProjectName = project.name
                                editingProjectID = project.id
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
    var snippet: String? = nil
    var infoLine: String? = nil
    var hotkeyIndex: Int? = nil

    private var displayInfoLine: String? {
        if status == .needsInput, let snippet, !snippet.isEmpty {
            return snippet
        }
        return infoLine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
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

            if let info = displayInfoLine {
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
