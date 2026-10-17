import XCTest
@testable import CodeSpark

final class TerminalStateDetectorTests: XCTestCase {

    // MARK: - detectFromScreen (Level 2)

    // AC-2: shell prompt ($, ❯, %) → .idle
    func test_detectFromScreen_shellPrompt_dollar_idle() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [
            "user@host:~/projects$ "
        ])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .idle)
    }

    func test_detectFromScreen_shellPrompt_chevron_idle() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [
            "~/projects ❯ "
        ])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .idle)
    }

    func test_detectFromScreen_shellPrompt_percent_idle() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [
            "host% "
        ])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .idle)
    }

    // AC-3: > with ? in upper 5 lines → .needsInput
    func test_detectFromScreen_angleBracket_with_question_needsInput() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [
            "Some output line",
            "Do you want to continue?",
            "> "
        ])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .needsInput)
    }

    func test_detectFromScreen_angleBracket_with_question_further_up_needsInput() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [
            "Line 1",
            "Are you sure? (y/n)",
            "Line 3",
            "Line 4",
            "Line 5",
            "> "
        ])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .needsInput)
    }

    // AC-4: > without ? → .idle
    func test_detectFromScreen_angleBracket_without_question_idle() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [
            "Some output line",
            "Another line",
            "> "
        ])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .idle)
    }

    // AC-5: no pattern match → .running
    func test_detectFromScreen_noPatternMatch_running() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [
            "Building project...",
            "Compiling main.swift",
            "Linking..."
        ])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .running)
    }

    // Edge: empty/nil snapshot
    func test_detectFromScreen_emptyLines_running() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .running)
    }

    func test_detectFromScreen_onlyBlankLines_running() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: ["", "   ", ""])
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .running)
    }

    // Edge: question mark beyond 5-line context window
    func test_detectFromScreen_angleBracket_question_beyond_5lines_idle() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: [
            "Are you sure?",
            "Line 2",
            "Line 3",
            "Line 4",
            "Line 5",
            "Line 6",
            "Line 7",
            "> "
        ])
        // Question is 7 lines above >, beyond the 5-line context window → idle, not needsInput
        XCTAssertEqual(TerminalStateDetector.detectFromScreen(snapshot), .idle)
    }

    // MARK: - detect (Combined Level 1 → Level 2)

    func test_detect_nilShellPID_fallsToLevel2() {
        let snapshot = TerminalSnapshotViewData.fixture(lines: ["user@host:~$ "])
        let state = TerminalStateDetector.detect(shellPID: nil) { snapshot }
        XCTAssertEqual(state, .idle)
    }

    func test_detect_nilSnapshot_returnsIdle() {
        let state = TerminalStateDetector.detect(shellPID: nil) { nil }
        XCTAssertEqual(state, .idle)
    }

    // MARK: - A prompt asked from inside a running program

    /// Codex waiting on an approval is still a child of the shell, and it sends
    /// nothing when it asks (no OSC 9/777, no BEL — measured). Its footer is the
    /// only tell, and it has to win over "a child is running".
    func test_a_codex_approval_prompt_needs_input_while_codex_runs() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        let me = ProcessInfo.processInfo.processIdentifier

        let asking = TerminalSnapshotViewData.fixture(lines: [
            "  Would you like to run the following command?",
            "  $ touch /tmp/probe",
            "› 1. Yes, proceed (y)",
            "  3. No, and tell Codex what to do differently (esc)",
            "  Press enter to confirm or esc to cancel",
            "",
        ])
        XCTAssertEqual(TerminalStateDetector.detect(shellPID: me) { asking }, .needsInput)

        let working = TerminalSnapshotViewData.fixture(lines: ["• Working (3s • esc to interrupt)"])
        XCTAssertEqual(TerminalStateDetector.detect(shellPID: me) { working }, .running)
    }

    // MARK: - Which process is the shell

    /// Ghostty starts tabs through `login(1)`; login always has a child (the
    /// shell), so asking login "anything running?" always said yes.
    func test_a_tab_started_through_login_is_watched_at_its_shell() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(GhosttyTerminalHost.shell(startedBy: me), me, "anything but login is the shell itself")

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "login"]
        let out = Pipe()
        pgrep.standardOutput = out
        try pgrep.run()
        pgrep.waitUntilExit()
        let logins = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0) }
        guard let login = logins.first(where: { !TerminalStateDetector.childPIDs(of: $0).isEmpty }) else {
            throw XCTSkip("no login(1) with a child on this machine")
        }
        XCTAssertEqual(GhosttyTerminalHost.shell(startedBy: login),
                       TerminalStateDetector.childPIDs(of: login).first)
    }

    func test_a_child_is_seen_and_a_leaf_has_none() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }

        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(TerminalStateDetector.childPIDs(of: me).contains(child.processIdentifier))
        XCTAssertFalse(TerminalStateDetector.hasChildProcesses(shellPID: child.processIdentifier),
                       "sleep has no children — a leaf must not read as busy")
    }
}
