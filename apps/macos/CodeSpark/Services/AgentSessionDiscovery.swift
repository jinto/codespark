import Foundation

/// What agent sessions there are to resume, and how to find them.
///
/// Split out of `AppModel` unchanged. It is the one part of that file that
/// touches neither the store, nor the selection, nor anything on screen — it
/// reads two directories on disk — so it was the first thing that could leave
/// without a decision attached.
///
/// Known cost, recorded rather than fixed here: `discoverCodex` walks
/// `~/.codex/sessions` recursively and opens every rollout file, and
/// `AppModel.refreshAgentSessions` calls it synchronously on the MainActor at
/// every project switch. Moving it off the main actor is its own change.

enum AgentKind: String, CaseIterable, Identifiable, Hashable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var command: String {
        rawValue
    }

    func resumeCommand(id: String) -> String {
        switch self {
        case .claude: "claude --resume \(id)"
        case .codex: "codex resume \(id)"
        }
    }
}

struct ResumableAgentSession: Identifiable, Equatable, Hashable {
    let id: String
    let agent: AgentKind
    let cwd: String
    let lastActivity: Date

    var label: String {
        let shortID = String(id.prefix(8))
        return "\(agent.title) • \(shortID)"
    }
}

enum AgentSessionDiscovery {
    static func discover(for paths: [String]) -> [ResumableAgentSession] {
        let normalizedPaths = Set(paths.map { ($0 as NSString).standardizingPath })
        let claude = normalizedPaths.flatMap { discoverClaude(for: $0) }
        let codex = discoverCodex(for: normalizedPaths)
        return Array(Set(claude + codex)).sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func discoverClaude(for path: String) -> [ResumableAgentSession] {
        let encodedPath = path.replacingOccurrences(of: "/", with: "-")
        let root = ("~/.claude/projects/\(encodedPath)" as NSString).expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }

        return files.filter { $0.hasSuffix(".jsonl") }.compactMap { file in
            let id = String(file.dropLast(6))
            guard !id.isEmpty else { return nil }
            let fullPath = (root as NSString).appendingPathComponent(file)
            return ResumableAgentSession(
                id: id,
                agent: .claude,
                cwd: path,
                lastActivity: modificationDate(of: fullPath)
            )
        }
    }

    private static func discoverCodex(for paths: Set<String>) -> [ResumableAgentSession] {
        let root = ("~/.codex/sessions" as NSString).expandingTildeInPath
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var sessions: [ResumableAgentSession] = []

        for case let relativePath as String in enumerator where relativePath.hasPrefix("rollout-") && relativePath.hasSuffix(".jsonl") {
            let fullPath = (root as NSString).appendingPathComponent(relativePath)
            guard let metadata = firstJSONLine(in: fullPath),
                  metadata["type"] as? String == "session_meta",
                  let payload = metadata["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String,
                  paths.contains((cwd as NSString).standardizingPath) else { continue }

            sessions.append(ResumableAgentSession(
                id: id,
                agent: .codex,
                cwd: cwd,
                lastActivity: modificationDate(of: fullPath)
            ))
        }
        return sessions
    }

    private static func firstJSONLine(in path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384),
              let line = String(data: data, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return json
    }

    private static func modificationDate(of path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}
