import Foundation

struct SessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    let targetLabel: String
    let lastCwd: String?
}

struct WorkspaceSummaryViewData: Identifiable, Equatable {
    let id: String
    let name: String
    let liveSessions: Int
    let recentlyClosedSessions: Int
    let hasInterruptedSessions: Bool
    let liveSessionDetails: [SessionSummary]
}

struct RestoreRecipeViewData: Equatable {
    let launchCommand: String
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

    static func from(cReason: workspace_close_reason_t) -> Self {
        switch cReason {
        case WORKSPACE_CLOSE_REASON_USER_CLOSED: return .userClosed
        case WORKSPACE_CLOSE_REASON_PROCESS_EXITED: return .processExited
        case WORKSPACE_CLOSE_REASON_SSH_DISCONNECTED: return .sshDisconnected
        case WORKSPACE_CLOSE_REASON_APP_CRASHED: return .appCrashed
        case WORKSPACE_CLOSE_REASON_HOST_QUIT: return .hostQuit
        default: return .userClosed
        }
    }

    func toCReason() -> workspace_close_reason_t {
        switch self {
        case .userClosed: return WORKSPACE_CLOSE_REASON_USER_CLOSED
        case .processExited: return WORKSPACE_CLOSE_REASON_PROCESS_EXITED
        case .sshDisconnected: return WORKSPACE_CLOSE_REASON_SSH_DISCONNECTED
        case .appCrashed: return WORKSPACE_CLOSE_REASON_APP_CRASHED
        case .hostQuit: return WORKSPACE_CLOSE_REASON_HOST_QUIT
        }
    }
}

struct SessionViewData: Identifiable, Equatable {
    let id: String
    let title: String
    let targetLabel: String
    let lastCwd: String?
    let restoreRecipe: RestoreRecipeViewData

    static func fixture() -> SessionViewData {
        SessionViewData(
            id: "fixture-session",
            title: "fixture",
            targetLabel: "local",
            lastCwd: "/tmp",
            restoreRecipe: RestoreRecipeViewData(launchCommand: "zsh -l")
        )
    }
}

struct ClosedSessionViewData: Identifiable, Equatable {
    let id: String
    let title: String
    let targetLabel: String
    let lastCwd: String?
    let closeReason: CloseReasonViewData
    let snapshotPreview: TerminalSnapshotViewData
    let restoreRecipe: RestoreRecipeViewData
}

struct WorkspaceDetailViewData: Equatable {
    let id: String
    let name: String
    var noteBody: String
    let liveSessions: [SessionViewData]
    let closedSessions: [ClosedSessionViewData]
}
