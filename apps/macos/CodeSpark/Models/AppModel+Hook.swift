import Foundation
import UserNotifications

// MARK: - Claude Code Hook Integration

extension AppModel {

    func handleHookEvent(_ event: ClaudeHookEvent) {
        guard let cwd = event.cwd else { return }
        switch event.hookEventName {
        case "Stop":
            hookNeedsInputCwds.insert(cwd)
            if let proj = projectForCwd(cwd) {
                captureSnippet(for: proj)
                if proj.id != selectedProjectID {
                    sendHookNotification(for: proj, snippet: hookSnippets[proj.id])
                }
            }
        case "UserPromptSubmit":
            hookNeedsInputCwds.remove(cwd)
            if let proj = projectForCwd(cwd) {
                acknowledgedProjectIDs.remove(proj.id)
                hookSnippets.removeValue(forKey: proj.id)
            }
        case "SessionStart":
            hookNeedsInputCwds.remove(cwd)
        case "SessionEnd":
            hookNeedsInputCwds.remove(cwd)
        case "Notification":
            if let proj = projectForCwd(cwd) {
                let snippet = event.message ?? event.title ?? "Claude is waiting for your input"
                hookSnippets[proj.id] = String(snippet.prefix(120))
                hookNeedsInputCwds.insert(cwd)
                if proj.id != selectedProjectID {
                    sendHookNotification(for: proj, snippet: snippet)
                }
            }
        default:
            break
        }
    }

    func captureSnippet(for project: ProjectSummaryViewData) {
        for session in project.liveSessionDetails {
            guard let host = hosts[session.id],
                  let snapshot = host.extractSnapshot() else { continue }
            let lastLine = snapshot.lines
                .reversed()
                .first { !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty }?
                .trimmingCharacters(in: CharacterSet.whitespaces)
            if let lastLine, !lastLine.isEmpty {
                hookSnippets[project.id] = String(lastLine.prefix(80))
                return
            }
        }
    }

    func acknowledgeProject(_ id: String) {
        acknowledgedProjectIDs.insert(id)
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["hook-needsinput-\(id)"])
    }

    func projectForCwd(_ cwd: String) -> ProjectSummaryViewData? {
        if let proj = projects.first(where: { proj in
            proj.liveSessionDetails.contains { $0.lastCwd == cwd }
        }) { return proj }
        return projects.first(where: { proj in
            proj.liveSessionDetails.contains { session in
                guard let lastCwd = session.lastCwd else { return false }
                return cwd.hasPrefix(lastCwd) || lastCwd.hasPrefix(cwd)
            }
        })
    }

    func sendHookNotification(for project: ProjectSummaryViewData, snippet: String? = nil) {
        guard !acknowledgedProjectIDs.contains(project.id) else { return }
        let content = UNMutableNotificationContent()
        content.title = project.name
        content.body = snippet ?? "Claude is waiting for your input"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "hook-needsinput-\(project.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func checkClaudeHooksHealth() {
        claudeHooksStatus = ClaudeHooksManager.checkStatus()
    }

    func installClaudeHooks() {
        ClaudeHooksManager.install()
        _ = ClaudeHooksManager.installCLISymlink()
        checkClaudeHooksHealth()
    }
}

extension AppModel: HookSocketServerDelegate {
    func hookServer(_ server: HookSocketServer, didReceive event: ClaudeHookEvent) {
        handleHookEvent(event)
    }
}
