import Foundation

/// Result of processing a Claude Code hook event.
enum HookEventResult {
    /// Claude stopped — session needs input at this cwd
    case needsInput(cwd: String, projectID: String?, snippet: String?)
    /// User submitted a prompt — session is running again
    case running(cwd: String, projectID: String?)
    /// Session started or ended — clear needsInput state
    case clearCwd(cwd: String)
    /// Notification from Claude — show message
    case notification(cwd: String, projectID: String?, message: String)
    /// Unknown or no-op event
    case ignored
}

/// Pure-logic processor for Claude Code hook events.
/// No side effects — returns a result that AppModel applies to its state.
enum HookEventProcessor {

    static func process(
        _ event: ClaudeHookEvent,
        projectForCwd: (String) -> ProjectSummaryViewData?
    ) -> HookEventResult {
        guard let cwd = event.cwd else { return .ignored }

        switch event.hookEventName {
        case "Stop":
            let proj = projectForCwd(cwd)
            return .needsInput(cwd: cwd, projectID: proj?.id, snippet: nil)

        case "UserPromptSubmit":
            let proj = projectForCwd(cwd)
            return .running(cwd: cwd, projectID: proj?.id)

        case "SessionStart", "SessionEnd":
            return .clearCwd(cwd: cwd)

        case "Notification":
            let proj = projectForCwd(cwd)
            let message = event.message ?? event.title ?? "Claude is waiting for your input"
            return .notification(cwd: cwd, projectID: proj?.id, message: message)

        default:
            return .ignored
        }
    }
}
