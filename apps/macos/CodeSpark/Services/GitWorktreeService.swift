import Foundation

struct GitWorktree: Identifiable, Equatable {
    let path: String
    let branch: String
    let isMainWorktree: Bool
    /// Stable identifier encoded in CodeSpark-created worktree directory names.
    /// Existing worktrees fall back to their path until they are recreated.
    let worktreeID: String

    var id: String { worktreeID }

    init(path: String, branch: String, isMainWorktree: Bool, worktreeID: String? = nil) {
        self.path = path
        self.branch = branch
        self.isMainWorktree = isMainWorktree
        self.worktreeID = worktreeID ?? GitWorktreeService.worktreeID(from: path)
    }
}

struct GitWorktreeCreation: Equatable {
    let id: String
    let name: String
    let path: String
    let branch: String
}

final class GitWorktreeService: @unchecked Sendable {
    static let defaultWorktreeRoot = "~/worktrees"

    /// Overridden by tests so remote lookups can be exercised without a server.
    static var sshExecutablePath = "/usr/bin/ssh"

    /// A background poll must never block on a prompt, and `ConnectTimeout`
    /// only covers getting connected — `ServerAlive*` is what notices a session
    /// that went quiet after that.
    static let remoteSSHOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=2",
    ]

    /// Ceiling for one remote command, in case the connection lives but the
    /// remote git does not answer. `BatchMode`/`ConnectTimeout`/`ServerAlive*`
    /// cover getting there and losing the link; none of them cover a remote that
    /// accepted the command and went quiet. Shortened by tests.
    static var remoteTimeout: TimeInterval = 20

    /// Local git had no deadline at all. It is usually instant, but `index.lock`
    /// held by another process, or a repository on a stalled network mount, is
    /// enough to wedge it — and refreshes queue behind one another, so one stuck
    /// lookup took every later one with it.
    static var localTimeout: TimeInterval = 30

    /// A poll over several remote projects should not open one connection per
    /// project all at once.
    private static let maxConcurrentLookups = 4

    private var cache: [String: CacheEntry] = [:]
    private let normalTTL: TimeInterval = 30
    private let failureTTL: TimeInterval = 60
    /// Refreshes queue behind each other instead of being dropped. A queued
    /// duplicate is nearly free — it finds nothing stale and returns — while a
    /// dropped one loses the answer the sidebar is waiting for, which is
    /// exactly the refresh that follows creating or removing a worktree.
    private var inFlight: Task<Void, Never>?

    private struct CacheEntry {
        let worktrees: [GitWorktree]?
        let fetchedAt: Date
        let ttl: TimeInterval
        var isExpired: Bool { Date().timeIntervalSince(fetchedAt) > ttl }
    }

    /// Cache reads take the address as written down anywhere — the store, a
    /// project row, a session's `workspacePath` — and settle its spelling on the
    /// way in, so both sides of every lookup are the same string.
    @MainActor
    func worktrees(for projectPath: String) -> [GitWorktree]? {
        cache[WorkspaceAddress(projectPath).storageKey]?.worktrees
    }

    @MainActor
    func refreshWorktrees(for projectPaths: [String]) async {
        let addresses = projectPaths.map(WorkspaceAddress.init)
        let previous = inFlight
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performRefresh(for: addresses)
        }
        inFlight = task
        await task.value
    }

    @MainActor
    private func performRefresh(for addresses: [WorkspaceAddress]) async {
        let unique = Set(addresses)
        let keys = Set(unique.map(\.storageKey))
        let stale = unique.filter { address in
            guard let entry = cache[address.storageKey] else { return true }
            return entry.isExpired
        }
        cache = cache.filter { keys.contains($0.key) }

        guard !stale.isEmpty else { return }

        await withTaskGroup(of: (String, [GitWorktree]?).self) { group in
            let pending = Array(stale)
            var next = 0
            while next < pending.count && next < Self.maxConcurrentLookups {
                let address = pending[next]
                group.addTask { await Self.fetchWorktrees(at: address) }
                next += 1
            }
            for await (path, result) in group {
                // A failure is "we could not ask", not "the worktrees are gone".
                // Keeping the last good answer is what stops a dropped
                // connection from regrouping every tab under one workspace and
                // blanking the main area for the length of the failure TTL.
                cache[path] = CacheEntry(
                    worktrees: result ?? cache[path]?.worktrees,
                    fetchedAt: Date(),
                    ttl: result != nil ? normalTTL : failureTTL
                )
                if next < pending.count {
                    let queued = pending[next]
                    group.addTask { await Self.fetchWorktrees(at: queued) }
                    next += 1
                }
            }
        }
    }

    /// Seeds the cache so multi-worktree behaviour can be exercised without a
    /// real repository. Only tests call this — `refreshWorktrees` is the
    /// production path.
    @MainActor
    func primeCache(_ worktrees: [GitWorktree], for projectPath: String) {
        cache[WorkspaceAddress(projectPath).storageKey] = CacheEntry(
            worktrees: worktrees.map(Self.canonicalised),
            fetchedAt: Date(),
            ttl: normalTTL)
    }

    /// Ages every entry past its TTL so the next refresh re-runs the lookup.
    /// Only tests call this.
    @MainActor
    func expireCacheForTesting() {
        cache = cache.mapValues {
            CacheEntry(worktrees: $0.worktrees, fetchedAt: .distantPast, ttl: 0)
        }
    }

    // MARK: - Remote git

    static func remoteSSHArguments(_ info: SSHConnectionInfo, remoteCommand: String) -> [String] {
        var argv = remoteSSHOptions
        if let port = info.port { argv.append(contentsOf: ["-p", "\(port)"]) }
        // Anything after `--` is a destination, never an option — see
        // `SSHConnectionInfo.isAddressable`.
        argv.append("--")
        if let user = info.user {
            argv.append("\(user)@\(info.host)")
        } else {
            argv.append(info.host)
        }
        argv.append(remoteCommand)
        return argv
    }

    /// The remote side hands this to a shell, so the repository path has to
    /// survive as a single word.
    static func remoteWorktreeListCommand(repoPath: String) -> String {
        "git -C \(RemoteShell.quoted(repoPath)) worktree list --porcelain"
    }

    /// Tilde expansion is the one thing quoting must not swallow — `'~/wt'` is
    /// a literal directory named `~`. Everything after the tilde is still
    /// quoted.
    static func remoteRootExpression(_ root: String) -> String {
        RemoteShell.pathExpression(root)
    }

    /// Exit code the create script uses for "that name is already taken".
    static let remoteNameTakenExitCode = 3

    /// Creating a worktree on the other machine is one script because three
    /// facts have to agree and all three live over there: where `$HOME` is,
    /// whether the name is taken, and the absolute path git ended up using.
    ///
    /// `git worktree add` chatters on stdout, so it is redirected — stdout
    /// carries exactly one thing, the path.
    ///
    /// That path is printed with `pwd -P`, not as it was composed: git records
    /// the symlink-resolved directory, so composing the address ourselves would
    /// spell the same worktree differently from every later scan — and two
    /// spellings are two workspaces, one of which no tab is keyed to.
    static func remoteAddWorktreeScript(
        repoPath: String,
        branch: String,
        root: String,
        name: String
    ) -> String {
        let rootExpr = remoteRootExpression(root)
        let quotedName = RemoteShell.quoted(name)
        return """
        root=\(rootExpr); p="$root"/\(quotedName); \
        if [ -e "$p" ]; then exit \(remoteNameTakenExitCode); fi; \
        mkdir -p "$root" || exit 1; \
        git -C \(RemoteShell.quoted(repoPath)) worktree add -b \(RemoteShell.quoted(branch)) "$p" 1>&2 || exit 1; \
        cd "$p" && pwd -P
        """
    }

    /// Runs one remote command and returns its stdout, or throws with the
    /// remote's own stderr so the failure reads like git's.
    private static func runRemote(_ info: SSHConnectionInfo, command: String) async throws -> String {
        let result = try await Subprocess.run(
            sshExecutablePath,
            remoteSSHArguments(info, remoteCommand: command),
            timeout: remoteTimeout)
        guard result.status == 0 else {
            let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "GitWorktree",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "remote git failed" : message]
            )
        }
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func addRemoteWorktree(
        info: SSHConnectionInfo,
        repoPath: String,
        branch: String,
        root: String,
        id: String?
    ) async throws -> GitWorktreeCreation {
        // The local existence loop cannot run over here, so the check moved into
        // the script. One retry covers a genuine collision; a second failure is
        // the user's to see.
        var attemptID = id ?? makeWorktreeID()
        for attempt in 0..<2 {
            let name = makeWorktreeName(projectPath: repoPath, branch: branch, id: attemptID)
            do {
                let created = try await runRemote(info, command: remoteAddWorktreeScript(
                    repoPath: repoPath, branch: branch, root: root, name: name
                ))
                return GitWorktreeCreation(
                    id: attemptID,
                    name: name,
                    path: info.address(forRemotePath: created).storageKey,
                    branch: branch
                )
            } catch let error as NSError where error.code == remoteNameTakenExitCode
                && attempt == 0 && id == nil {
                attemptID = makeWorktreeID()
            }
        }
        throw NSError(
            domain: "GitWorktree",
            code: remoteNameTakenExitCode,
            userInfo: [NSLocalizedDescriptionKey: "A worktree directory with that name already exists on the remote."]
        )
    }

    // MARK: - Parsing

    /// git prints the resolved directory — `/private/tmp/proj`, never
    /// `/tmp/proj` — while a project keeps whatever spelling it was added with.
    /// Two spellings are two workspaces, and the tabs of one of them end up
    /// belonging to a row nothing can select: `recomputeWorkspaces` matches
    /// through `sameWorkspace(as:)` and correctly leaves the selection alone,
    /// then `visibleSessions` compares with `==`, finds nothing, and the main
    /// area offers "New Terminal" over a running tab.
    ///
    /// Local only — and the address decides which it is, so this no longer has
    /// to ask. `parseWorktreeList` is shared with the remote scan, and resolving
    /// a path from another machine against this one's filesystem is the
    /// namespace confusion this is meant to end.
    private static func canonicalised(_ worktree: GitWorktree) -> GitWorktree {
        GitWorktree(
            path: WorkspaceAddress(worktree.path).storageKey,
            branch: worktree.branch,
            isMainWorktree: worktree.isMainWorktree,
            worktreeID: worktree.worktreeID
        )
    }

    static func parseWorktreeList(_ output: String) -> [GitWorktree] {
        let stanzas = output.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result: [GitWorktree] = []
        var isFirst = true

        for stanza in stanzas {
            let lines = stanza.components(separatedBy: "\n")
            var path: String?
            var branch: String?
            var headSHA: String?
            var isPrunable = false

            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                } else if line.hasPrefix("HEAD ") {
                    headSHA = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("prunable") {
                    // git writes `prunable <reason>`, never a bare `prunable`,
                    // so the exact match this replaces never fired once: a
                    // worktree whose directory is gone kept its sidebar row, and
                    // selecting it landed on a path that no longer exists.
                    isPrunable = true
                }
            }

            guard let worktreePath = path, !isPrunable else {
                // Deliberately *not* clearing `isFirst`: the flag means "the
                // first worktree we are keeping", and clearing it here left a
                // list with no main worktree at all whenever the first stanza
                // was skipped. `projectIdentityLine` reads
                // `.first(where: \.isMainWorktree)?.branch`, so a remote row
                // silently fell back to naming only its host.
                continue
            }

            let displayBranch = branch ?? headSHA.map { "HEAD@\(String($0.prefix(8)))" } ?? "unknown"
            result.append(GitWorktree(path: worktreePath, branch: displayBranch, isMainWorktree: isFirst))
            isFirst = false
        }

        return result
    }

    // MARK: - Mutate

    @MainActor
    func invalidateCache(for projectPath: String) {
        cache.removeValue(forKey: projectPath)
    }

    /// Ask for a fresh answer without throwing away the one we have. Callers
    /// that mean "re-read this now" want this, not `invalidateCache` — dropping
    /// the entry outright means a lookup that then fails leaves nothing, and
    /// over ssh that failure is routine.
    func expireCache(for projectPath: String) {
        let key = WorkspaceAddress(projectPath).storageKey
        guard let entry = cache[key] else { return }
        cache[key] = CacheEntry(worktrees: entry.worktrees, fetchedAt: .distantPast, ttl: 0)
    }

    /// Creates a new worktree at `~/worktrees/<repo>-<branch>-<id>` on a new branch.
    /// The generated ID is part of the directory name, so it remains available
    /// without a second metadata store when the app is relaunched.
    static func addWorktree(
        at project: WorkspaceAddress,
        branch: String,
        worktreeRoot: String? = nil,
        id: String? = nil
    ) async throws -> GitWorktreeCreation {
        if let info = project.remote {
            guard let repoPath = info.remotePath else {
                throw NSError(domain: "GitWorktree", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "This remote project does not say where its repository is."
                ])
            }
            return try await addRemoteWorktree(
                info: info,
                repoPath: repoPath,
                branch: branch,
                root: worktreeRoot ?? configuredWorktreeRoot,
                id: id
            )
        }
        // Local from here down, and the type is what says so — `git -C` below
        // takes `localPath`, which the remote arm does not have.
        let projectPath = project.localPath ?? ""
        let rootPath = expandedWorktreeRoot(worktreeRoot ?? configuredWorktreeRoot)
        try FileManager.default.createDirectory(
            atPath: rootPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var worktreeID = id ?? makeWorktreeID()
        var worktreeName = makeWorktreeName(projectPath: projectPath, branch: branch, id: worktreeID)
        var worktreePath = (rootPath as NSString).appendingPathComponent(worktreeName)
        while id == nil && FileManager.default.fileExists(atPath: worktreePath) {
            worktreeID = makeWorktreeID()
            worktreeName = makeWorktreeName(projectPath: projectPath, branch: branch, id: worktreeID)
            worktreePath = (rootPath as NSString).appendingPathComponent(worktreeName)
        }
        try await runGit(["-C", projectPath, "worktree", "add", "-b", branch, worktreePath])
        return GitWorktreeCreation(id: worktreeID, name: worktreeName, path: worktreePath, branch: branch)
    }

    static var configuredWorktreeRoot: String {
        let configured = UserDefaults.standard.string(forKey: StorageKeys.worktreeRoot) ?? ""
        return configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultWorktreeRoot
            : configured
    }

    static func expandedWorktreeRoot(_ root: String) -> String {
        (root as NSString).expandingTildeInPath
    }

    static func makeWorktreeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased()
    }

    /// The repository's own name, whichever namespace the project lives in. A
    /// remote project is addressed by URI, but it is the remote path that names
    /// the repository — and the address is what knows the difference.
    static func repoName(forProjectPath projectPath: String) -> String {
        let address = WorkspaceAddress(projectPath)
        let path = address.localPath ?? address.remote?.remotePath ?? projectPath
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func makeWorktreeName(projectPath: String, branch: String, id: String) -> String {
        [
            sanitizeComponent(repoName(forProjectPath: projectPath)),
            sanitizeComponent(branch),
            sanitizeComponent(id),
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    static func previewWorktreeName(projectPath: String, branch: String) -> String {
        [
            sanitizeComponent(repoName(forProjectPath: projectPath)),
            sanitizeComponent(branch),
            "<id>",
        ].joined(separator: "-")
    }

    /// What the create sheet shows. The root setting is the same string either
    /// way — on a remote project it names a directory on the other machine.
    static func previewWorktreePath(projectPath: String, branch: String) -> String {
        "\(configuredWorktreeRoot)/\(previewWorktreeName(projectPath: projectPath, branch: branch))"
    }

    static func worktreeID(from path: String) -> String {
        let component = URL(fileURLWithPath: path).lastPathComponent
        let pieces = component.split(separator: "-")
        guard let suffix = pieces.last,
              suffix.count == 4,
              suffix.allSatisfy({ $0.isHexDigit }) else {
            return path
        }
        return String(suffix).lowercased()
    }

    private static func sanitizeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let sanitized = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return sanitized.isEmpty ? "worktree" : sanitized
    }

    static func removeWorktree(at project: WorkspaceAddress, worktree: WorkspaceAddress) async throws {
        if let info = project.remote,
           let repoPath = info.remotePath,
           let target = worktree.remote?.remotePath {
            _ = try await runRemote(info, command: """
            git -C \(RemoteShell.quoted(repoPath)) worktree remove \(RemoteShell.quoted(target))
            """)
            return
        }
        guard let projectPath = project.localPath, let worktreePath = worktree.localPath else {
            throw NSError(domain: "GitWorktree", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "A remote worktree cannot be removed through a local repository."
            ])
        }
        try await runGit(["-C", projectPath, "worktree", "remove", worktreePath])
    }

    // MARK: - Git process

    private static func runGit(_ arguments: [String]) async throws {
        let result = try await Subprocess.run("/usr/bin/git", arguments, timeout: localTimeout)
        guard result.status == 0 else {
            let msg = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "GitWorktree", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "git failed" : msg])
        }
    }

    /// A failure is reported once and then held. The lookup reruns every TTL, so
    /// a project folder that is not a repository would otherwise write the same
    /// line every minute for as long as the app is open. Clearing on success
    /// means a folder that comes back reports its next failure again.
    private static let failureLog = FailureLog()

    private final class FailureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var reported: Set<String> = []

        func shouldReport(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return reported.insert(path).inserted
        }

        func clear(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            reported.remove(path)
        }
    }

    private static func noteFailure(at path: String, status: Int32, stderr: String) {
        guard failureLog.shouldReport(path) else { return }
        NSLog("[CodeSpark] git worktree list failed (%d) for %@: %@", status, path, stderr)
    }

    private static func fetchWorktrees(at address: WorkspaceAddress) async -> (String, [GitWorktree]?) {
        // The one place local and remote part ways, and the address has already
        // said which. Everything downstream — cache, parser, grouping — sees the
        // same shapes either way.
        let path = address.storageKey
        if let info = address.remote {
            guard let repoPath = info.remotePath else { return (path, nil) }
            return (path, await fetchRemoteWorktrees(info: info, repoPath: repoPath))
        }

        do {
            let result = try await Subprocess.run(
                "/usr/bin/git",
                ["-C", path, "worktree", "list", "--porcelain"],
                timeout: localTimeout)
            guard result.status == 0 else {
                // Kept rather than dropped on the floor: a failure here empties
                // a project's worktree rows, and with stderr discarded there was
                // nothing to say why.
                noteFailure(
                    at: path,
                    status: result.status,
                    stderr: result.err.trimmingCharacters(in: .whitespacesAndNewlines))
                return (path, nil)
            }
            failureLog.clear(path)
            let worktrees = parseWorktreeList(result.out).map(canonicalised)
            return (path, worktrees.isEmpty ? nil : worktrees)
        } catch {
            noteFailure(at: path, status: -1, stderr: error.localizedDescription)
            return (path, nil)
        }
    }

    private static func fetchRemoteWorktrees(
        info: SSHConnectionInfo,
        repoPath: String
    ) async -> [GitWorktree]? {
        do {
            let result = try await Subprocess.run(
                sshExecutablePath,
                remoteSSHArguments(
                    info,
                    remoteCommand: remoteWorktreeListCommand(repoPath: repoPath)),
                timeout: remoteTimeout)
            guard result.status == 0 else { return nil }
            // Remote git answers in its own filesystem's terms; the app speaks
            // workspace addresses.
            let worktrees = parseWorktreeList(result.out).map { worktree in
                GitWorktree(
                    path: info.address(forRemotePath: worktree.path).storageKey,
                    branch: worktree.branch,
                    isMainWorktree: worktree.isMainWorktree
                )
            }
            return worktrees.isEmpty ? nil : worktrees
        } catch {
            return nil
        }
    }
}
