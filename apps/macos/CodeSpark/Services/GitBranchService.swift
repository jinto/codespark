import Foundation

final class GitBranchService: @unchecked Sendable {
    private var cache: [String: CacheEntry] = [:]
    private let normalTTL: TimeInterval = 30
    private let failureTTL: TimeInterval = 60
    private var isRefreshing = false

    private struct CacheEntry {
        let branch: String?
        let fetchedAt: Date
        let ttl: TimeInterval
        var isExpired: Bool { Date().timeIntervalSince(fetchedAt) > ttl }
    }

    func branch(for path: String) -> String? {
        cache[path]?.branch
    }

    @MainActor
    func refreshBranches(for paths: [String]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let uniquePaths = Set(paths)
        let stale = uniquePaths.filter { path in
            guard let entry = cache[path] else { return true }
            return entry.isExpired
        }
        // Prune entries no longer in active paths
        let activeSet = uniquePaths
        cache = cache.filter { activeSet.contains($0.key) }

        guard !stale.isEmpty else { return }

        await withTaskGroup(of: (String, String?).self) { group in
            for path in stale {
                group.addTask {
                    await Self.fetchBranch(at: path)
                }
            }
            for await (path, branch) in group {
                cache[path] = CacheEntry(
                    branch: branch,
                    fetchedAt: Date(),
                    ttl: branch != nil ? normalTTL : failureTTL
                )
            }
        }
    }

    private static func fetchBranch(at path: String) async -> (String, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            // Read stdout BEFORE waiting for termination to avoid pipe deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let exitStatus: Int32 = await withCheckedContinuation { cont in
                process.terminationHandler = { proc in
                    cont.resume(returning: proc.terminationStatus)
                }
            }
            guard exitStatus == 0 else { return (path, nil) }
            let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path, branch)
        } catch {
            return (path, nil)
        }
    }
}
