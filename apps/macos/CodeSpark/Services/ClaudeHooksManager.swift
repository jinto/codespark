import Foundation

enum ClaudeHooksStatus: Equatable {
    case installed
    case missingHooks
    case missingCLI
    case missingBoth
}

enum ClaudeHooksManager {
    private static let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
    private static let hookEvents: [(String, String)] = [
        ("Stop", "codespark-hook stop"),
        ("UserPromptSubmit", "codespark-hook prompt-submit"),
        ("SessionStart", "codespark-hook session-start"),
        ("SessionEnd", "codespark-hook session-end"),
        ("Notification", "codespark-hook notification"),
    ]

    // MARK: - Health check

    static func checkStatus() -> ClaudeHooksStatus {
        let hasHooks = settingsContainHook()
        let hasCLI = cliFoundInPath()
        return switch (hasHooks, hasCLI) {
        case (true, true): .installed
        case (false, true): .missingHooks
        case (true, false): .missingCLI
        case (false, false): .missingBoth
        }
    }

    private static func settingsContainHook() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("codespark-hook")
    }

    private static func cliFoundInPath() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codespark-hook"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    // MARK: - Install / Uninstall

    static func install() {
        var settings = readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, command) in hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let exists = entries.contains { entry in
                guard let list = entry["hooks"] as? [[String: Any]] else { return false }
                return list.contains { ($0["command"] as? String)?.contains("codespark-hook") == true }
            }
            if !exists {
                entries.append([
                    "matcher": "",
                    "hooks": [["type": "command", "command": command, "timeout": 3] as [String: Any]]
                ] as [String: Any])
            }
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        writeSettings(settings)
    }

    static func uninstall() {
        var settings = readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for (event, _) in hookEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let list = entry["hooks"] as? [[String: Any]] else { return false }
                return list.contains { ($0["command"] as? String)?.contains("codespark-hook") == true }
            }
            hooks[event] = entries.isEmpty ? nil : entries
        }

        settings["hooks"] = hooks
        writeSettings(settings)
    }

    static func installCLISymlink() -> Bool {
        guard let binURL = Bundle.main.url(forResource: "bin", withExtension: nil)?
            .appendingPathComponent("codespark-hook") else { return false }
        let linkPath = "/usr/local/bin/codespark-hook"
        try? FileManager.default.removeItem(atPath: linkPath)
        do {
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: binURL.path)
            return true
        } catch { return false }
    }

    // MARK: - Helpers

    private static func readSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func writeSettings(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: settingsPath))
    }
}
