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
