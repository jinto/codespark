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
                // The same guard as the tick above, which this was missing: a
                // checkpoint reads every open tab's whole viewport out of
                // Ghostty and writes it to the store. In the background that ran
                // forever, once every thirty seconds per tab, for snapshots
                // nobody was going to look at.
                guard NSApp.isActive else { return }
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
        var newState = TerminalStateDetector.detect(shellPID: host.shellPID) { host.extractSnapshot() }
        // An ask outranks the poll — the asking program is a running child —
        // until the shell is back: then whoever asked is gone, keystroke or not.
        if newState == .idle {
            sessionsAwaitingAnswer.remove(sessionID)
        } else if sessionsAwaitingAnswer.contains(sessionID) {
            newState = .needsInput
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

    /// A program in the tab asked through the terminal — Claude Code posts
    /// OSC 777 when it wants a permission or has sat idle for a minute.
    func sessionDidAskForInput(sessionID: String) {
        guard hosts[sessionID] != nil else { return }
        sessionsAwaitingAnswer.insert(sessionID)
        detectState(sessionID: sessionID)
    }

    func terminalHostDidReceiveKey(sessionID: String) {
        guard sessionsAwaitingAnswer.remove(sessionID) != nil else { return }
        detectState(sessionID: sessionID)
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
    var gitBranchQueryPaths: [WorkspaceAddress] {
        // The transport filter stays, and it is not redundant with the address:
        // a remote tab reports its directory as a bare path, which no amount of
        // reading the text distinguishes from one here. `WorkspaceAddress`
        // catches every URI; only the project a tab belongs to knows about the
        // rest. `refreshBranches` then drops anything that is not local anyway,
        // so it takes both to be wrong.
        let cwds = projects
            .filter { $0.transport != "ssh" }
            .flatMap { $0.liveSessionDetails.compactMap(\.lastCwd) }
            .map(WorkspaceAddress.init)
        return Array(Set(localProjectPaths + cwds))
    }

    /// Project folders on this machine. Kept apart from the query paths above
    /// because only a *project* can be labelled "non-git" — a tab that wandered
    /// into a directory outside any repo says nothing about the project it
    /// belongs to.
    var localProjectPaths: [WorkspaceAddress] {
        projects
            .filter { $0.transport != "ssh" && !$0.path.isEmpty }
            .map { WorkspaceAddress($0.path) }
            .filter { $0.localPath != nil }
    }

    func refreshGitBranches() {
        let addresses = gitBranchQueryPaths
        guard !addresses.isEmpty else { return }
        Task {
            await gitBranchService.refreshBranches(for: addresses)
            let updated = Dictionary(
                uniqueKeysWithValues: addresses.compactMap { address in
                    gitBranchService.branch(for: address).map { (address.storageKey, $0) }
                }
            )
            if updated != gitBranches { gitBranches = updated }
            let disowned = Set(
                localProjectPaths
                    .filter { gitBranchService.isKnownNonRepo($0) }
                    .map(\.storageKey)
            )
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
            // The scrollback read is ~20ms under the renderer lock; the live
            // screen is free. A screen that hasn't moved has nothing new.
            guard let screen = host.extractSnapshot()?.lines,
                  screen != checkpointedScreens[sessionID],
                  let snapshot = host.extractRestoreSnapshot() else { continue }
            Task { [weak self] in
                do {
                    try await self?.core.recordCheckpointSnapshot(sessionID: sessionID, snapshot: snapshot)
                    // Only once it's stored — a failed write must be retried.
                    self?.checkpointedScreens[sessionID] = screen
                } catch {
                    NSLog("[CodeSpark] checkpoint snapshot failed for session \(sessionID): \(error)")
                }
            }
        }
    }
}
