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
}
