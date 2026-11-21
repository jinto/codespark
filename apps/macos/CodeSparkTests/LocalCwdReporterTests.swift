import XCTest
@testable import CodeSpark

/// Local tabs lean on Ghostty's own shell integration for OSC 7 cwd reporting —
/// except that Ghostty refuses, by design, to inject into Apple's `/bin/bash`
/// (`shell_integration.zig`: SIP pins bash 3.2, whose ENV-based POSIX startup
/// the injection needs). On a machine whose login shell is `/bin/bash`, cwd
/// tracking was therefore silently dead: `last_cwd` froze at whatever directory
/// each tab was created with, and every restore opened the project folder.
///
/// The cure is the one ssh tabs already use: bash's `PROMPT_COMMAND` is a plain
/// string, and a plain string crosses as an environment variable — through
/// `login -flp` (the `p` preserves the environment) and `exec -l` alike. So the
/// surface environment plants the same reporter the remote launcher plants.
final class LocalCwdReporterTests: XCTestCase {
    func test_the_local_terminal_environment_plants_the_bash_reporter() {
        let env = GhosttyTerminalHost.terminalEnvironment()
        XCTAssertEqual(env["PROMPT_COMMAND"], RemoteCwdReporter.bashPromptCommand,
                       "a local Apple bash has no other way to report its cwd")
    }

    /// The string has to hold up on Apple's actual bash 3.2 — the one shell this
    /// exists for — not just on whatever bash the harness happens to find.
    func test_a_real_apple_bash_reports_through_the_planted_environment() throws {
        let awkward = try makeDirectory(named: "a%20b #1?x")
        defer { try? FileManager.default.removeItem(atPath: awkward) }

        let output = try runAppleBash(typing: "cd '\(awkward)'\nexit\n")

        XCTAssertTrue(reportedDirectories(in: output).contains(awkward),
                      "bash reported \(reportedDirectories(in: output)) for \(awkward)")
    }

    /// A shell that has no `PROMPT_COMMAND` at all must still work — the value
    /// arrives by environment, before any dotfile runs.
    func test_the_first_prompt_already_reports() throws {
        let output = try runAppleBash(typing: "exit\n")
        XCTAssertFalse(reportedDirectories(in: output).isEmpty,
                       "no report before the first prompt: \(output.debugDescription)")
    }

    /// A directory name is untrusted text. One carrying its own BEL ends our
    /// OSC 7 early, and the rest of the name becomes a sequence of its own —
    /// `x<BEL><ESC>]52;c;…<BEL>` writes the clipboard (GHSA-2r63-vmw6-3m3c, the
    /// same hole Ghostty 1.4.0 closed in its own integration). Control bytes are
    /// stripped before encoding, so the report is one frame with none inside.
    func test_a_directory_name_cannot_smuggle_a_sequence_out_of_the_report() throws {
        for name in OSC7Report.hostileNames + [OSC7Report.ordinaryName] {
            let dir = try makeDirectory(named: name)
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let (output, status) = try runAppleBashBytes(
                typing: "cd \"$CS_D\"\nexit\n", environment: ["CS_D": dir])

            XCTAssertEqual(status, 0, "bash failed for \(name.debugDescription)")
            // Typed `cd`: the first prompt reports home, the second the target.
            XCTAssertEqual(OSC7Report.frames(in: output).last, OSC7Report.expected(for: dir),
                           "bash reported \(OSC7Report.frames(in: output).map(\.debugDescription)) for \(name.debugDescription)")
        }
    }

    // MARK: - harness

    /// Runs Apple's `/bin/bash` the way a Ghostty surface does: a login,
    /// interactive shell whose environment carries the reporter.
    private func runAppleBash(typing input: String) throws -> String {
        String(decoding: try runAppleBashBytes(typing: input).output, as: UTF8.self)
    }

    private func runAppleBashBytes(
        typing input: String, environment extra: [String: String] = [:]
    ) throws -> (output: Data, status: Int32) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs-localbash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-l", "-i"]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TERM": "dumb",
            "PROMPT_COMMAND": GhosttyTerminalHost.terminalEnvironment()["PROMPT_COMMAND"] ?? "",
        ].merging(extra) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }

    private func makeDirectory(named name: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs-localodd-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The shell reports `$PWD`, the path after symlink resolution.
        return (url.path as NSString).resolvingSymlinksInPath
    }

    /// Every directory the output claims via OSC 7, percent-decoded the way
    /// Ghostty decodes it.
    private func reportedDirectories(in output: String) -> [String] {
        output.components(separatedBy: "\u{1B}]7;file://localhost").dropFirst().map { tail in
            let path = tail.prefix { $0 != "\u{07}" }
            return String(path).removingPercentEncoding ?? String(path)
        }
    }
}

/// What every OSC 7 reporter must emit, byte for byte — shared by the local
/// bash test above and the remote zsh/bash/fish tests.
enum OSC7Report {
    /// BEL ends an OSC; ESC starts the next sequence; CAN aborts one; LF split
    /// fish's command substitution into two reports.
    static let hostileNames = [
        "bel\u{07}x",
        "esc\u{07}\u{1B}]52;c;SGk=\u{07}y",
        "can\u{18}z",
        "lf\nw",
    ]
    /// Must come out exactly as before the fix.
    static let ordinaryName = "한글 a#?%"

    /// Every `ESC ] 7 ; … BEL` frame in the raw output, as bytes. `String ==`
    /// would compare 한글 by canonical equivalence and hide an NFC/NFD change.
    static func frames(in output: Data) -> [Data] {
        let open = Data("\u{1B}]7;".utf8)
        var frames: [Data] = []
        var cursor = output.startIndex
        while let start = output.range(of: open, in: cursor..<output.endIndex) {
            guard let end = output[start.upperBound...].firstIndex(of: 0x07) else { break }
            frames.append(output[start.lowerBound...end])
            cursor = output.index(after: end)
        }
        return frames
    }

    /// Control bytes stripped first, then `%`, `#`, `?` encoded — the order the
    /// reporters use.
    static func expected(for path: String) -> Data {
        let stripped = String(String.UnicodeScalarView(
            path.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        let encoded = stripped
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: "?", with: "%3F")
        return Data("\u{1B}]7;file://localhost\(encoded)\u{07}".utf8)
    }
}
