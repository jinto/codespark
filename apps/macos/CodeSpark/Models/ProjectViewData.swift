import Foundation
import SwiftUI

enum ProjectStatus: Equatable {
    case running
    case idle
    case needsInput
    case interrupted

    var label: String {
        switch self {
        case .running: "Running"
        case .idle: "Idle"
        case .needsInput: "Needs input"
        case .interrupted: "Interrupted"
        }
    }

    var icon: String {
        switch self {
        case .running: "bolt.fill"
        case .idle: "circle.fill"
        case .needsInput: "exclamationmark.triangle.fill"
        case .interrupted: "arrow.clockwise"
        }
    }

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
    private static func cwdBelongsTo(cwd: String, worktreePath: String) -> Bool {
        cwd == worktreePath || cwd.hasPrefix(worktreePath + "/")
    }
}
