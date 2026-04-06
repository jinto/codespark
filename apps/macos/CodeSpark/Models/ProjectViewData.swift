import Foundation
import SwiftUI

enum ProjectStatus: Equatable {
    case running
    case idle
    case needsInput

    var label: String {
        switch self {
        case .running: "Running"
        case .idle: "Idle"
        case .needsInput: "Needs input"
        }
    }

    var icon: String {
        switch self {
        case .running: "bolt.fill"
        case .idle: "circle.fill"
        case .needsInput: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running: AppTheme.statusRunning
        case .idle: AppTheme.statusIdle
        case .needsInput: AppTheme.statusNeedsInput
        }
    }
}

struct SessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    let targetLabel: String
    let lastCwd: String?
}

struct ProjectSummaryViewData: Identifiable, Equatable {
    let id: String
    var name: String
    let path: String
    let transport: String
    let liveSessions: Int
    let recentlyClosedSessions: Int
    let hasInterruptedSessions: Bool
    let liveSessionDetails: [SessionSummary]
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

    static func from(ffi reason: CloseReason) -> Self {
        switch reason {
        case .userClosed: return .userClosed
        case .processExited: return .processExited
        case .sshDisconnected: return .sshDisconnected
        case .appCrashed: return .appCrashed
        case .hostQuit: return .hostQuit
        }
    }

    static func from(cReason: project_close_reason_t) -> Self {
        switch cReason {
        case PROJECT_CLOSE_REASON_USER_CLOSED: return .userClosed
        case PROJECT_CLOSE_REASON_PROCESS_EXITED: return .processExited
        case PROJECT_CLOSE_REASON_SSH_DISCONNECTED: return .sshDisconnected
        case PROJECT_CLOSE_REASON_APP_CRASHED: return .appCrashed
        case PROJECT_CLOSE_REASON_HOST_QUIT: return .hostQuit
        default: return .userClosed
        }
    }

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
    let lastCwd: String?

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
}

// MARK: - Workspace

struct WorkspaceViewData: Identifiable, Equatable {
    let path: String
    let branch: String
    let isMainWorktree: Bool
    var sessions: [SessionSummary]

    var id: String { path }
}

extension WorkspaceViewData {
    /// Group sessions into workspaces based on their cwd matching worktree paths.
    /// - Non-git / single worktree: returns 1 workspace with all sessions
    /// - Multi-worktree: matches session.lastCwd to longest-prefix worktree path
    /// - Unmatched sessions: assigned to main worktree
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
                sessions: sessions
            )]
        }

        // Sort worktrees by path length descending for longest-prefix matching
        let sorted = worktrees.sorted { $0.path.count > $1.path.count }
        var buckets: [String: [SessionSummary]] = [:]
        for wt in worktrees { buckets[wt.path] = [] }

        let mainPath = worktrees.first(where: \.isMainWorktree)?.path ?? worktrees[0].path

        for session in sessions {
            let cwd = session.lastCwd ?? ""
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
                sessions: buckets[wt.path] ?? []
            )
        }
    }

    /// Check that cwd is exactly the worktree path or a subdirectory of it.
    /// Prevents "/projects/codespark-other" matching "/projects/codespark".
    private static func cwdBelongsTo(cwd: String, worktreePath: String) -> Bool {
        cwd == worktreePath || cwd.hasPrefix(worktreePath + "/")
    }
}
