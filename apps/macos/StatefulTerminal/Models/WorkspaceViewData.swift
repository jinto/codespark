import Foundation

struct WorkspaceSummaryViewData: Identifiable, Equatable {
    let id: String
    let name: String
    let liveSessions: Int
    let recentlyClosedSessions: Int
    let hasInterruptedSessions: Bool
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
