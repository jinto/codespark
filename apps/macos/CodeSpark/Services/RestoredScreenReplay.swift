import Foundation

/// Replays a restored tab's previous screen as real terminal output, so it lands
/// in scrollback above the new prompt instead of covering it.
///
/// Ghostty exposes no way to write into the display, and wrapping the shell in
/// `sh -c '…; exec $SHELL'` would swallow the shell-integration environment —
/// its zsh bootstrap unsets `ZDOTDIR` and skips the integration for the
/// non-interactive outer shell, which would silently kill cwd tracking. So the
/// shell is launched untouched and the replay is injected as startup input.
///
/// The screen text is never parsed by the shell: it lives in its own file that
/// the injected command only ever `cat`s.
enum RestoredScreenReplay {

    /// Written to the pty once the shell starts. `cat` emits the payload — whose
    /// first bytes clear the echoed command line — then the file removes itself.
    static func command(forPayloadAt path: String) -> String {
        "cat \(shellQuoted(path)) && rm -f \(shellQuoted(path))\n"
    }

    /// Terminal bytes for the replay: clear the screen (hiding the echoed
    /// command), then the previous screen dimmed, then a blank separator line.
    static func payload(for snapshot: TerminalSnapshotViewData) -> String {
        let lines = trimmingTrailingBlanks(snapshot.lines)
        guard !lines.isEmpty else { return "" }

        let clear = "\u{1B}[2J\u{1B}[H"
        let dim = "\u{1B}[2m"
        let reset = "\u{1B}[0m"
        let body = lines
            .map { "\(dim)\($0)\(reset)\n" }
            .joined()
        return "\(clear)\(dim)──── before restart ────\(reset)\n\(body)\n"
    }

    /// Writes the payload somewhere the shell can read it once. Returns nil when
    /// there is nothing worth replaying or the write fails — the tab then just
    /// opens normally.
    static func prepare(
        snapshot: TerminalSnapshotViewData,
        directory: String = NSTemporaryDirectory()
    ) -> String? {
        let text = payload(for: snapshot)
        guard !text.isEmpty else { return nil }

        let path = (directory as NSString)
            .appendingPathComponent("codespark-restore-\(UUID().uuidString.prefix(8))")
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[CodeSpark] could not stage restore replay: \(error)")
            return nil
        }
        return command(forPayloadAt: path)
    }

    private static func trimmingTrailingBlanks(_ lines: [String]) -> [String] {
        var result = lines
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
