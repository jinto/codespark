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

    /// Ceiling for one remote lookup, in case the connection lives but the
    /// remote git does not answer.
    private static let remoteTimeout: TimeInterval = 20

    /// A poll over several remote projects should not open one connection per
    /// project all at once.
    private static let maxConcurrentLookups = 4

    private var cache: [String: CacheEntry] = [:]
    private let normalTTL: TimeInterval = 30
    private let failureTTL: TimeInterval = 60
    private var isRefreshing = false

    private struct CacheEntry {
        let worktrees: [GitWorktree]?
        let fetchedAt: Date
        let ttl: TimeInterval
        var isExpired: Bool { Date().timeIntervalSince(fetchedAt) > ttl }
    }

    func worktrees(for projectPath: String) -> [GitWorktree]? {
        cache[projectPath]?.worktrees
    }

    @MainActor
    func refreshWorktrees(for projectPaths: [String]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let uniquePaths = Set(projectPaths)
        let stale = uniquePaths.filter { path in
            guard let entry = cache[path] else { return true }
            return entry.isExpired
        }
        cache = cache.filter { uniquePaths.contains($0.key) }

        guard !stale.isEmpty else { return }

        await withTaskGroup(of: (String, [GitWorktree]?).self) { group in
            let pending = Array(stale)
            var next = 0
            while next < pending.count && next < Self.maxConcurrentLookups {
                let path = pending[next]
                group.addTask { await Self.fetchWorktrees(at: path) }
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
    func primeCache(_ worktrees: [GitWorktree], for projectPath: String) {
        cache[projectPath] = CacheEntry(worktrees: worktrees, fetchedAt: Date(), ttl: normalTTL)
    }

    /// Ages every entry past its TTL so the next refresh re-runs the lookup.
    /// Only tests call this.
    func expireCacheForTesting() {
        cache = cache.mapValues {
            CacheEntry(worktrees: $0.worktrees, fetchedAt: .distantPast, ttl: 0)
        }
    }

    // MARK: - Remote git

    static func remoteSSHArguments(_ info: SSHConnectionInfo, remoteCommand: String) -> [String] {
        var argv = remoteSSHOptions
        if let port = info.port { argv.append(contentsOf: ["-p", "\(port)"]) }
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
        "git -C \(SSHConnectionInfo.shellQuoted(repoPath)) worktree list --porcelain"
    }

    /// Tilde expansion is the one thing quoting must not swallow — `'~/wt'` is
    /// a literal directory named `~`. Everything after the tilde is still
    /// quoted.
    static func remoteRootExpression(_ root: String) -> String {
        if root == "~" { return "\"$HOME\"" }
        if root.hasPrefix("~/") {
            return "\"$HOME\"/" + SSHConnectionInfo.shellQuoted(String(root.dropFirst(2)))
        }
        return SSHConnectionInfo.shellQuoted(root)
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
        let quotedName = SSHConnectionInfo.shellQuoted(name)
        return """
        root=\(rootExpr); p="$root"/\(quotedName); \
        if [ -e "$p" ]; then exit \(remoteNameTakenExitCode); fi; \
        mkdir -p "$root" || exit 1; \
        git -C \(SSHConnectionInfo.shellQuoted(repoPath)) worktree add -b \(SSHConnectionInfo.shellQuoted(branch)) "$p" 1>&2 || exit 1; \
        cd "$p" && pwd -P
        """
    }

    /// Runs one remote command and returns its stdout, or throws with the
    /// remote's own stderr so the failure reads like git's.
    private static func runRemote(_ info: SSHConnectionInfo, command: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.arguments = remoteSSHArguments(info, remoteCommand: command)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let exitStatus: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
        }
        guard exitStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "GitWorktree",
                code: Int(exitStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "remote git failed" : message]
            )
        }
        return String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                    path: info.workspaceURI(forRemotePath: created),
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
                } else if line == "prunable" {
                    isPrunable = true
                }
            }

            guard let worktreePath = path, !isPrunable else {
                if path != nil { isFirst = false }
                continue
            }

            let displayBranch = branch ?? headSHA.map { "HEAD@\(String($0.prefix(8)))" } ?? "unknown"
            result.append(GitWorktree(path: worktreePath, branch: displayBranch, isMainWorktree: isFirst))
            isFirst = false
        }

        return result
    }

    // MARK: - Mutate

    func invalidateCache(for projectPath: String) {
        cache.removeValue(forKey: projectPath)
    }

    /// Ask for a fresh answer without throwing away the one we have. Callers
    /// that mean "re-read this now" want this, not `invalidateCache` — dropping
    /// the entry outright means a lookup that then fails leaves nothing, and
    /// over ssh that failure is routine.
    func expireCache(for projectPath: String) {
        guard let entry = cache[projectPath] else { return }
        cache[projectPath] = CacheEntry(worktrees: entry.worktrees, fetchedAt: .distantPast, ttl: 0)
    }

    /// Creates a new worktree at `~/worktrees/<repo>-<branch>-<id>` on a new branch.
    /// The generated ID is part of the directory name, so it remains available
    /// without a second metadata store when the app is relaunched.
    static func addWorktree(
        projectPath: String,
        branch: String,
        worktreeRoot: String? = nil,
        id: String? = nil
    ) async throws -> GitWorktreeCreation {
        if let info = SSHConnectionInfo(uri: projectPath), let repoPath = info.remotePath {
            return try await addRemoteWorktree(
                info: info,
                repoPath: repoPath,
                branch: branch,
                root: worktreeRoot ?? configuredWorktreeRoot,
                id: id
            )
        }
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
    /// the repository.
    static func repoName(forProjectPath projectPath: String) -> String {
        let path = SSHConnectionInfo.remotePath(fromWorkspaceURI: projectPath) ?? projectPath
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

    static func removeWorktree(projectPath: String, worktreePath: String) async throws {
        if let info = SSHConnectionInfo(uri: projectPath),
           let repoPath = info.remotePath,
           let target = SSHConnectionInfo.remotePath(fromWorkspaceURI: worktreePath) {
            _ = try await runRemote(info, command: """
            git -C \(SSHConnectionInfo.shellQuoted(repoPath)) worktree remove \(SSHConnectionInfo.shellQuoted(target))
            """)
            return
        }
        try await runGit(["-C", projectPath, "worktree", "remove", worktreePath])
    }

    // MARK: - Git process

    private static func runGit(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let exitStatus: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { proc in
                cont.resume(returning: proc.terminationStatus)
            }
        }
        guard exitStatus == 0 else {
            let msg = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "git failed"
            throw NSError(domain: "GitWorktree", code: Int(exitStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private static func fetchWorktrees(at path: String) async -> (String, [GitWorktree]?) {
        // The one place local and remote part ways. Everything downstream —
        // cache, parser, grouping — sees the same shapes either way.
        if let info = SSHConnectionInfo(uri: path) {
            guard let repoPath = info.remotePath else { return (path, nil) }
            return (path, await fetchRemoteWorktrees(info: info, repoPath: repoPath))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "worktree", "list", "--porcelain"]
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            // Read stdout BEFORE waiting for termination to avoid pipe deadlock.
            // If the process writes more than the pipe buffer (64KB), it blocks
            // until the reader drains — so we must read first, then wait.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let exitStatus: Int32 = await withCheckedContinuation { cont in
                process.terminationHandler = { proc in
                    cont.resume(returning: proc.terminationStatus)
                }
            }
            guard exitStatus == 0 else { return (path, nil) }
            guard let output = String(data: data, encoding: .utf8) else { return (path, nil) }
            let worktrees = parseWorktreeList(output)
            return (path, worktrees.isEmpty ? nil : worktrees)
        } catch {
            return (path, nil)
        }
    }

    private static func fetchRemoteWorktrees(
        info: SSHConnectionInfo,
        repoPath: String
    ) async -> [GitWorktree]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.arguments = remoteSSHArguments(
            info,
            remoteCommand: remoteWorktreeListCommand(repoPath: repoPath)
        )
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let deadline = Task {
                try await Task.sleep(nanoseconds: UInt64(remoteTimeout * 1_000_000_000))
                if process.isRunning { process.terminate() }
            }
            defer { deadline.cancel() }
            // Read before waiting: a process that outgrows the pipe buffer
            // blocks until someone drains it.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let exitStatus: Int32 = await withCheckedContinuation { cont in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            }
            guard exitStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
            // Remote git answers in its own filesystem's terms; the app speaks
            // workspace addresses.
            let worktrees = parseWorktreeList(output).map { worktree in
                GitWorktree(
                    path: info.workspaceURI(forRemotePath: worktree.path),
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
