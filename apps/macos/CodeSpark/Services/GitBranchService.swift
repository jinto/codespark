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

    /// Whether git has been asked about this folder and reported no branch.
    /// Distinct from "not asked yet", which also has no branch — only one of the
    /// two is something to say out loud.
    func isKnownNonRepo(_ path: String) -> Bool {
        guard let entry = cache[path] else { return false }
        return entry.branch == nil
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

    /// This used to install the termination handler *after* reading stdout to
    /// EOF — that is, after git had already exited — and it had no deadline at
    /// all. A handler set that late may never fire, and the continuation waiting
    /// on it never resumes; `refreshBranches` latches `isRefreshing` on the way
    /// in and clears it in a `defer` that would then never run, so one missed
    /// callback froze every branch label for the life of the app.
    private static func fetchBranch(at path: String) async -> (String, String?) {
        do {
            let result = try await Subprocess.run(
                "/usr/bin/git",
                ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
                timeout: 10)
            guard result.status == 0 else { return (path, nil) }
            return (path, result.out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (path, nil)
        }
    }
}
