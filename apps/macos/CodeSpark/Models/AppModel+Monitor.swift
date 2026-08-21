import AppKit
import Foundation
import UserNotifications

// MARK: - Session Monitoring (state detection, git branches, checkpoints)

extension AppModel {

    func startMonitorTimers() {
        idleTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard NSApp.isActive else { return }
                self?.updateSessionStates()
                self?.refreshGitBranches()
                self?.refreshGitWorktrees()
            }
        checkpointTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.captureCheckpoints()
            }
        // The tick above stands down while the app is in the background, so
        // worktrees made elsewhere in the meantime — by an agent in a tab, say —
        // would wait for the next tick after coming back. Ask on the way in.
        activationObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshGitBranches()
                self?.refreshGitWorktrees()
            }
    }

    // MARK: - Debounce

    /// Called when the active session produces output. Resets its 5s debounce.
    func resetDebounce(sessionID: String) {
        debounceTasks[sessionID]?.cancel()
        debounceTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.detectState(sessionID: sessionID)
        }
    }

    // MARK: - State Detection

    /// Detect terminal state for a single session using Level 1 (process) → Level 2 (screen).
    func detectState(sessionID: String) {
        guard let host = hosts[sessionID] else {
            sessionStates.removeValue(forKey: sessionID)
            return
        }

        let oldState = sessionStates[sessionID]
        let newState = TerminalStateDetector.detect(shellPID: host.shellPID) {
            host.extractSnapshot()
        }
        guard newState != oldState else { return }
        sessionStates[sessionID] = newState

        // Notify on transitions to idle/needsInput for non-active sessions
        if sessionID != activeSessionID,
           newState == .needsInput || newState == .idle,
           oldState == .running || oldState == nil {
            sendStateNotification(sessionID: sessionID, state: newState)
        }
    }

    /// Poll all sessions — called by the 10s timer for inactive sessions.
    func updateSessionStates() {
        guard !hosts.isEmpty else { return }
        for (sessionID, _) in hosts {
            // Active session uses debounce-driven detection; skip here unless no debounce is pending
            if sessionID == activeSessionID, debounceTasks[sessionID] != nil {
                continue
            }
            detectState(sessionID: sessionID)
        }
    }

    // MARK: - Notifications

    func sendStateNotification(sessionID: String, state: TerminalState) {
        guard NSApp.isActive else { return }
        guard let session = liveSessions.first(where: { $0.id == sessionID }) else { return }

        let projName = projects.first { proj in
            proj.liveSessionDetails.contains { $0.id == sessionID }
        }?.name ?? "Terminal"

        let content = UNMutableNotificationContent()
        content.title = projName
        content.body = state == .needsInput
            ? "\(session.title) needs input"
            : "\(session.title) is idle"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "state-\(sessionID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Git

    /// The directories worth asking git about.
    ///
    /// Project folders as well as the directories tabs are sitting in: the row
    /// under a project's name reports its branch, and asking only about cwds
    /// meant a project answered only while some tab happened to stand exactly at
    /// its root — every other project fell back to its path.
    ///
    /// Remote tabs are left out on both counts. Their cwd is a path on the other
    /// machine, and `git -C` runs here, so a remote `/srv/app` would be answered
    /// by whatever local directory happens to share the name. Now that a remote
    /// shell reports every `cd` it makes, that mistake would arrive constantly.
    var gitBranchQueryPaths: [String] {
        let cwds = projects
            .filter { $0.transport != "ssh" }
            .flatMap { $0.liveSessionDetails.compactMap(\.lastCwd) }
        return Array(Set(localProjectPaths + cwds))
    }

    /// Project folders on this machine. Kept apart from the query paths above
    /// because only a *project* can be labelled "non-git" — a tab that wandered
    /// into a directory outside any repo says nothing about the project it
    /// belongs to.
    var localProjectPaths: [String] {
        projects.filter { $0.transport != "ssh" && !$0.path.isEmpty }.map(\.path)
    }

    func refreshGitBranches() {
        let paths = gitBranchQueryPaths
        guard !paths.isEmpty else { return }
        Task {
            await gitBranchService.refreshBranches(for: paths)
            let updated = Dictionary(
                uniqueKeysWithValues: paths.compactMap { path in
                    gitBranchService.branch(for: path).map { (path, $0) }
                }
            )
            if updated != gitBranches { gitBranches = updated }
            let disowned = Set(localProjectPaths.filter { gitBranchService.isKnownNonRepo($0) })
            if disowned != nonGitProjectPaths { nonGitProjectPaths = disowned }
        }
    }

    func refreshGitWorktrees() {
        // Every project that can have worktrees, remote ones included, and not
        // just the selected one — an open tree keeps its rows while another
        // project has focus. Only stale entries respawn git.
        let paths = worktreeProjectPaths
        guard !paths.isEmpty else { return }
        Task {
            await gitWorktreeService.refreshWorktrees(for: paths)
            recomputeWorkspaces()
        }
    }

    // MARK: - Checkpoints

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
