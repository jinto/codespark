import Foundation

struct GitWorktree: Identifiable, Equatable {
    let path: String
    let branch: String
    let isMainWorktree: Bool

    var id: String { path }
}

final class GitWorktreeService: @unchecked Sendable {
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
            for path in stale {
                group.addTask { await Self.fetchWorktrees(at: path) }
            }
            for await (path, result) in group {
                cache[path] = CacheEntry(
                    worktrees: result,
                    fetchedAt: Date(),
                    ttl: result != nil ? normalTTL : failureTTL
                )
            }
        }
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

    /// Creates a new worktree at `<projectPath>/.worktrees/<name>/` on a new branch.
    /// Returns the worktree filesystem path on success.
    static func addWorktree(projectPath: String, name: String, branch: String) async throws -> String {
        let worktreePath = (projectPath as NSString).appendingPathComponent(".worktrees/\(name)")
        try await runGit(["-C", projectPath, "worktree", "add", "-b", branch, worktreePath])
        return worktreePath
    }

    static func removeWorktree(projectPath: String, worktreePath: String) async throws {
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
}
