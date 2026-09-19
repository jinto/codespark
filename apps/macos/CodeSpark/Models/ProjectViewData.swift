import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ProjectStatus: Equatable {
    case running
    case idle
    case needsInput
    case interrupted

    var color: Color {
        switch self {
        case .running: AppTheme.statusRunning
        case .idle: AppTheme.statusIdle
        case .needsInput: AppTheme.statusNeedsInput
        case .interrupted: .gray
        }
    }
}

struct SessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    let targetLabel: String
    let lastCwd: String?
    /// Workspace the tab was opened in. Empty for rows predating the column.
    var workspacePath: String = ""
}

/// A workspace reachable by Cmd+1…9. Identified by its project as well as its
/// path, since the digit has to bring the right project along.
/// Where a dragged project row will land. `end` is its own case because there is
/// no row to sit in front of past the last one.
enum ProjectDropTarget: Equatable {
    case before(String)
    case end
    /// Onto a group's header: into that group, last.
    case group(String)
}

/// The user's groups of projects. A project filed in none of them is in the
/// default group, which is not stored — it is whatever is left — and draws no
/// header, so a sidebar nobody has grouped looks the way it always has.
///
/// Order inside a group is the one drag order (`projectOrder`); this only says
/// which group a project is in.
struct ProjectGroups: Codable, Equatable {
    struct Group: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var isCollapsed = false
    }

    var groups: [Group] = []
    /// Project id → group id. Absent means the default group.
    var membership: [String: String] = [:]

    /// nil for the default group — including a project still filed under a
    /// group that has since been deleted.
    func groupID(of projectID: String) -> String? {
        guard let id = membership[projectID], groups.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    mutating func file(_ projectID: String, in groupID: String?) {
        membership[projectID] = groupID
    }

    /// Deleting a group deletes a label: its projects fall back to the default group.
    mutating func delete(_ groupID: String) {
        groups.removeAll { $0.id == groupID }
        membership = membership.filter { $0.value != groupID }
    }
}

/// A tab in flight between the tab bar and a sidebar row. Carried as JSON,
/// which keeps it apart from the plain-text `String` a project row drags to
/// reorder — sharing that would let a dropped tab be read as a project and
/// vice versa. Not a custom UTType: an identifier the bundle does not declare
/// is one the drop side silently never targets.
struct SessionDragPayload: Codable, Transferable {
    let sessionID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// What can land on a project row: a tab being refiled, or a project row being
/// reordered. One type for both because a view gets ONE `dropDestination` —
/// the innermost wins for every drag and swallows payloads it cannot read, so
/// stacking a destination per payload type leaves one of them dead.
enum ProjectRowDrop: Transferable {
    case tab(sessionID: String)
    case projectRow(id: String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (payload: SessionDragPayload) in
            ProjectRowDrop.tab(sessionID: payload.sessionID)
        })
        ProxyRepresentation(importing: { (id: String) in
            ProjectRowDrop.projectRow(id: id)
        })
    }
}

/// Somewhere a tab can be refiled to: a worktree of a project on the same host.
/// `workspacePath` is carried verbatim — it is the string the store files the
/// tab under, and remote URIs only work because nothing respells them.
struct SessionMoveTarget: Identifiable, Equatable {
    let projectID: String
    let projectName: String
    /// Named only when the project has several worktrees to tell apart.
    let branch: String?
    let workspacePath: String

    var id: String { workspacePath }
    var label: String { branch.map { "\(projectName) — \($0)" } ?? projectName }
}

struct ProjectSummaryViewData: Identifiable, Equatable {
    let id: String
    var name: String
    var path: String
    let transport: String
    var liveSessions: Int
    let recentlyClosedSessions: Int
    var hasInterruptedSessions: Bool
    var liveSessionDetails: [SessionSummary]
}

struct TerminalSnapshotViewData: Equatable {
    let cols: Int
    let rows: Int
    let lines: [String]

    static func fixture(lines: [String]) -> TerminalSnapshotViewData {
        TerminalSnapshotViewData(cols: 80, rows: 24, lines: lines)
    }
}

enum CloseReasonViewData: Equatable {
    case userClosed
    case processExited
    case sshDisconnected
    case appCrashed
    case hostQuit

    func toCReason() -> project_close_reason_t {
        switch self {
        case .userClosed: return PROJECT_CLOSE_REASON_USER_CLOSED
        case .processExited: return PROJECT_CLOSE_REASON_PROCESS_EXITED
        case .sshDisconnected: return PROJECT_CLOSE_REASON_SSH_DISCONNECTED
        case .appCrashed: return PROJECT_CLOSE_REASON_APP_CRASHED
        case .hostQuit: return PROJECT_CLOSE_REASON_HOST_QUIT
        }
    }
}

struct SessionViewData: Identifiable, Equatable {
    let id: String
    var title: String
    let targetLabel: String
    var lastCwd: String?
    /// Workspace the tab was opened in. Empty for rows predating the column.
    var workspacePath: String = ""

    static func fixture() -> SessionViewData {
        SessionViewData(
            id: "fixture-session",
            title: "fixture",
            targetLabel: "local",
            lastCwd: "/tmp"
        )
    }
}

struct ProjectDetailViewData: Equatable {
    let id: String
    let name: String
    let path: String
    let transport: String
    let liveSessions: [SessionViewData]
    let interruptedSessions: [SessionSummary]

    init(
        id: String,
        name: String,
        path: String,
        transport: String,
        liveSessions: [SessionViewData],
        interruptedSessions: [SessionSummary] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.transport = transport
        self.liveSessions = liveSessions
        self.interruptedSessions = interruptedSessions
    }
}

// MARK: - Workspace

extension SessionViewData {
    /// Whether this tab belongs to a workspace. Membership is fixed at creation
    /// in `workspacePath`; only rows written before that column existed fall
    /// back to their cwd, matching how `groupSessions` places them.
    func belongs(to workspacePath: String) -> Bool {
        let workspace = WorkspaceAddress(workspacePath)
        guard self.workspacePath.isEmpty else {
            return WorkspaceAddress(self.workspacePath) == workspace
        }
        guard let cwd = lastCwd else { return false }
        return workspace.contains(WorkspaceAddress(cwd))
    }
}

struct WorkspaceViewData: Identifiable, Equatable {
    let path: String
    let branch: String
    let isMainWorktree: Bool
    let worktreeID: String
    var sessions: [SessionSummary]

    var id: String { worktreeID }

    init(
        path: String,
        branch: String,
        isMainWorktree: Bool,
        sessions: [SessionSummary],
        worktreeID: String? = nil
    ) {
        self.path = path
        self.branch = branch
        self.isMainWorktree = isMainWorktree
        self.worktreeID = worktreeID ?? GitWorktreeService.worktreeID(from: path)
        self.sessions = sessions
    }
}

extension WorkspaceViewData {
    /// Group sessions into workspaces by the workspace each tab was opened in.
    /// - Non-git / single worktree: returns 1 workspace with all sessions
    /// - Multi-worktree: honours `session.workspacePath` so a `cd` never moves a tab
    /// - Empty `workspacePath` (rows predating the column): falls back to matching
    ///   `lastCwd` against the longest worktree path prefix
    /// - Still unmatched (e.g. the worktree was removed): assigned to main worktree
    static func groupSessions(
        _ sessions: [SessionSummary],
        into worktrees: [GitWorktree]?,
        projectPath: String
    ) -> [WorkspaceViewData] {
        guard let worktrees, worktrees.count > 1 else {
            let ws = worktrees?.first
            return [WorkspaceViewData(
                path: ws?.path ?? projectPath,
                branch: ws?.branch ?? "default",
                isMainWorktree: true,
                sessions: sessions,
                worktreeID: ws?.worktreeID
            )]
        }

        // Sort worktrees by path length descending for longest-prefix matching
        let sorted = worktrees.sorted { $0.path.count > $1.path.count }
        var buckets: [String: [SessionSummary]] = [:]
        for wt in worktrees { buckets[wt.path] = [] }

        let mainPath = worktrees.first(where: \.isMainWorktree)?.path ?? worktrees[0].path

        for session in sessions {
            if !session.workspacePath.isEmpty,
               worktrees.contains(where: { $0.path == session.workspacePath }) {
                buckets[session.workspacePath, default: []].append(session)
                continue
            }
            let cwd = session.workspacePath.isEmpty ? (session.lastCwd ?? "") : ""
            if let match = sorted.first(where: { cwdBelongsTo(cwd: cwd, worktreePath: $0.path) }) {
                buckets[match.path, default: []].append(session)
            } else {
                buckets[mainPath, default: []].append(session)
            }
        }

        return worktrees.map { wt in
            WorkspaceViewData(
                path: wt.path,
                branch: wt.branch,
                isMainWorktree: wt.isMainWorktree,
                sessions: buckets[wt.path] ?? [],
                worktreeID: wt.worktreeID
            )
        }
    }

    /// Check that cwd is exactly the worktree path or a subdirectory of it.
    /// Prevents "/projects/codespark-other" matching "/projects/codespark".
    /// The workspace whose worktree holds `cwd`. Deepest path first, so a
    /// worktree nested inside another wins over its container.
    static func containing(cwd: String, in workspaces: [WorkspaceViewData]) -> WorkspaceViewData? {
        guard !cwd.isEmpty else { return nil }
        return workspaces
            .sorted { $0.path.count > $1.path.count }
            .first { cwdBelongsTo(cwd: cwd, worktreePath: $0.path) }
    }

    private static func cwdBelongsTo(cwd: String, worktreePath: String) -> Bool {
        cwd == worktreePath || cwd.hasPrefix(worktreePath + "/")
    }
}
