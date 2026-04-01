import AppKit
import Foundation
import UserNotifications

// MARK: - Session Monitoring (idle detection, git branches, checkpoints)

extension AppModel {

    func startMonitorTimers() {
        idleTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard NSApp.isActive else { return }
                self?.updateIdleStates()
                self?.refreshGitBranches()
                self?.refreshGitWorktrees()
            }
        checkpointTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.captureCheckpoints()
            }
    }

    func updateIdleStates() {
        guard !hosts.isEmpty else { return }
        let threshold = Date().addingTimeInterval(-10)
        let newSet = Set(
            hosts.compactMap { (id, host) in
                guard let lastOutput = host.lastOutputTime else { return id }
                return lastOutput < threshold ? id : nil
            }
        )
        let newlyIdle = newSet.subtracting(idleSessionIDs)
        if !newlyIdle.isEmpty {
            sendIdleNotifications(for: newlyIdle)
        }
        if newSet != idleSessionIDs { idleSessionIDs = newSet }
    }

    func sendIdleNotifications(for sessionIDs: Set<String>) {
        guard NSApp.isActive else { return }
        for sessionID in sessionIDs {
            guard sessionID != activeSessionID else { continue }
            guard let session = liveSessions.first(where: { $0.id == sessionID }) else { continue }

            let projName = projects.first { proj in
                proj.liveSessionDetails.contains { $0.id == sessionID }
            }?.name ?? "Terminal"

            let content = UNMutableNotificationContent()
            content.title = projName
            content.body = "\(session.title) is waiting for input"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "idle-\(sessionID)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    func refreshGitBranches() {
        let paths = Array(Set(projects.flatMap { $0.liveSessionDetails.compactMap(\.lastCwd) }))
        guard !paths.isEmpty else { return }
        Task {
            await gitBranchService.refreshBranches(for: paths)
            let updated = Dictionary(
                uniqueKeysWithValues: paths.compactMap { path in
                    gitBranchService.branch(for: path).map { (path, $0) }
                }
            )
            if updated != gitBranches { gitBranches = updated }
        }
    }

    func refreshGitWorktrees() {
        // Only refresh worktrees for the selected project to avoid unnecessary git spawns
        guard let selectedPath = selectedProject?.path, !selectedPath.isEmpty else { return }
        Task {
            await gitWorktreeService.refreshWorktrees(for: [selectedPath])
            recomputeWorkspaces()
        }
    }

    func captureCheckpoints() {
        guard !hosts.isEmpty else { return }
        for (sessionID, host) in hosts where !closingSessionIDs.contains(sessionID) {
            guard let snapshot = host.extractSnapshot() else { continue }
            Task { [weak self] in
                do {
                    try await self?.core.recordCheckpointSnapshot(sessionID: sessionID, snapshot: snapshot)
                } catch {
                    NSLog("[CodeSpark] checkpoint snapshot failed for session \(sessionID): \(error)")
                }
            }
        }
    }
}
