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

    // MARK: - harness

    /// Runs Apple's `/bin/bash` the way a Ghostty surface does: a login,
    /// interactive shell whose environment carries the reporter.
    private func runAppleBash(typing input: String) throws -> String {
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
        ]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
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
