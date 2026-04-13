import Darwin
import Foundation

enum TerminalState: Equatable {
    case running
    case idle
    case needsInput
}

enum TerminalStateDetector {

    // MARK: - Level 1: Process-based detection

    /// Returns true if the given PID has at least one child process.
    static func hasChildProcesses(shellPID: pid_t) -> Bool {
        proc_listchildpids(shellPID, nil, 0) > 0
    }

    // MARK: - Level 2: Screen-based detection

    /// Analyze terminal snapshot to determine state.
    /// Called only when Level 1 says "not-running" (no child processes).
    static func detectFromScreen(_ snapshot: TerminalSnapshotViewData) -> TerminalState {
        guard let lastLine = lastNonEmptyLine(snapshot.lines) else {
            return .running
        }

        let trimmed = lastLine.trimmingCharacters(in: .whitespaces)

        // Priority 1 & 2: ends with >
        if trimmed.hasSuffix(">") {
            let idx = lastNonEmptyLineIndex(snapshot.lines)!
            let contextStart = max(0, idx - 5)
            let contextLines = snapshot.lines[contextStart..<idx]
            let hasQuestion = contextLines.contains { $0.contains("?") }
            return hasQuestion ? .needsInput : .idle
        }

        // Priority 3: shell prompt ($, ❯, %)
        if trimmed.hasSuffix("$") || trimmed.hasSuffix("❯") || trimmed.hasSuffix("%") {
            return .idle
        }

        // Default
        return .running
    }

    // MARK: - Combined detection

    /// Level 1 → Level 2 pipeline.
    /// - shellPID nil: skip Level 1, use Level 2 only.
    /// - snapshot closure returns nil: return .idle (surface unavailable).
    static func detect(shellPID: pid_t?, snapshot: () -> TerminalSnapshotViewData?) -> TerminalState {
        // Level 1: process check
        if let pid = shellPID {
            if hasChildProcesses(shellPID: pid) {
                return .running
            }
        }

        // Level 2: screen parse
        guard let snap = snapshot() else {
            return .idle
        }
        return detectFromScreen(snap)
    }

    // MARK: - Private helpers

    private static func lastNonEmptyLine(_ lines: [String]) -> String? {
        lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private static func lastNonEmptyLineIndex(_ lines: [String]) -> Int? {
        lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}
