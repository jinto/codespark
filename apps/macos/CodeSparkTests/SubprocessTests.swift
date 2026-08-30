import XCTest
@testable import CodeSpark

/// The three ways spawning a child went wrong across this codebase, each one
/// asserted here so the single helper cannot regress into any of them.
final class SubprocessTests: XCTestCase {

    private let sh = "/bin/sh"

    func test_it_returns_what_the_child_said_on_both_streams() async throws {
        let result = try await Subprocess.run(
            sh, ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 10)

        XCTAssertEqual(result.out.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(result.err.trimmingCharacters(in: .whitespacesAndNewlines), "err")
        XCTAssertEqual(result.status, 3)
    }

    /// The deadlock. A pipe buffer is 64KB; fill stderr while the reader is
    /// working through stdout and the child blocks, stdout never reaches EOF,
    /// and the read waits for a process that is waiting for the read.
    ///
    /// This is not hypothetical here — `remoteAddWorktreeScript` sends `git
    /// worktree add`'s output to stderr on purpose, so on a large repo the
    /// chattiest stream was the one being read second.
    func test_a_child_that_floods_stderr_does_not_deadlock() async throws {
        let result = try await Subprocess.run(
            sh,
            ["-c", "yes ERR | head -c 300000 1>&2; yes OUT | head -c 300000"],
            timeout: 20)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 300_000, "stdout was truncated")
        XCTAssertEqual(result.stderr.count, 300_000, "stderr was truncated")
    }

    /// The race. `readDataToEndOfFile` returns when the child closes its write
    /// end — i.e. at exit — so a handler installed after that read has already
    /// missed the event it is waiting for. A child that exits immediately is the
    /// sharpest version of it.
    func test_a_child_that_exits_instantly_still_reports_its_status() async throws {
        for _ in 0..<20 {
            let result = try await Subprocess.run(sh, ["-c", "exit 7"], timeout: 10)
            XCTAssertEqual(result.status, 7)
        }
    }

    func test_a_child_that_never_finishes_is_cut_off() async throws {
        let started = Date()
        do {
            _ = try await Subprocess.run(sh, ["-c", "sleep 30"], timeout: 1)
            XCTFail("a command with no end to it returned")
        } catch Subprocess.Failure.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(started), 15,
                              "the deadline did not cut it off")
        }
    }

    func test_a_command_that_does_not_exist_throws_rather_than_hanging() async {
        do {
            _ = try await Subprocess.run("/nonexistent-\(UUID().uuidString)", [], timeout: 5)
            XCTFail("launching nothing succeeded")
        } catch Subprocess.Failure.couldNotLaunch {
            // The readers have to be released too, or this test would hang
            // rather than fail — which is the point of closing the write ends.
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
