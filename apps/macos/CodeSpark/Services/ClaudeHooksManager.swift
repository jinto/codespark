import Foundation

enum ClaudeHooksStatus: Equatable {
    case installed
    case missingHooks
    case missingCLI
    case missingBoth
}

enum ClaudeHooksManager {
    private static let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
    private static let cliBinDir = NSHomeDirectory() + "/.local/bin"
    private static let cliPath = NSHomeDirectory() + "/.local/bin/codespark-hook"

    private static let hookEvents: [(String, String)] = [
        ("Stop", cliPath + " stop"),
        ("UserPromptSubmit", cliPath + " prompt-submit"),
        ("SessionStart", cliPath + " session-start"),
        ("SessionEnd", cliPath + " session-end"),
        ("Notification", cliPath + " notification"),
    ]

    // MARK: - Health check

    static func checkStatus() -> ClaudeHooksStatus {
        let hasHooks = settingsContainHook()
        let hasCLI = FileManager.default.isExecutableFile(atPath: cliPath)
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

    // MARK: - Install / Uninstall

    static func install() {
        installCLI()
        installHooks()
    }

    private static func installCLI() {
        guard let srcURL = Bundle.main.url(forResource: "bin", withExtension: nil)?
            .appendingPathComponent("codespark-hook") else { return }

        // Ensure ~/.local/bin/ exists
        try? FileManager.default.createDirectory(
            atPath: cliBinDir, withIntermediateDirectories: true)

        // Copy binary (overwrite if exists)
        let destURL = URL(fileURLWithPath: cliPath)
        try? FileManager.default.removeItem(at: destURL)
        try? FileManager.default.copyItem(at: srcURL, to: destURL)

        // Ensure executable
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: cliPath)
    }

    private static func installHooks() {
        var settings = readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, command) in hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Remove old entries (bare command or different path)
            entries.removeAll { entry in
                guard let list = entry["hooks"] as? [[String: Any]] else { return false }
                return list.contains { ($0["command"] as? String)?.contains("codespark-hook") == true }
            }
            // Add with absolute path
            entries.append([
                "matcher": "",
                "hooks": [["type": "command", "command": command, "timeout": 3] as [String: Any]]
            ] as [String: Any])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        writeSettings(settings)
    }

    static func fullUninstall() {
        uninstall()
        // Remove CLI binary
        try? FileManager.default.removeItem(atPath: cliPath)
        // Remove app data
        let appSupport = NSHomeDirectory() + "/Library/Application Support"
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: appSupport) {
            for dir in contents where dir.hasPrefix("com.jinto.codespark") {
                try? fm.removeItem(atPath: appSupport + "/" + dir)
            }
        }
        // Reset UserDefaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
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

    @discardableResult
    static func installCLISymlink() -> Bool {
        installCLI()
        return FileManager.default.isExecutableFile(atPath: cliPath)
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
