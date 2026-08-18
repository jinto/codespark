import XCTest
@testable import CodeSpark

final class RestoredScreenReplayTests: XCTestCase {

    func test_payload_clears_the_screen_first_to_hide_the_injected_command() {
        let payload = RestoredScreenReplay.payload(for: .fixture(lines: ["hello"]))
        XCTAssertTrue(payload.hasPrefix("\u{1B}[2J\u{1B}[H"))
    }

    func test_payload_carries_every_line_of_the_previous_screen() {
        let payload = RestoredScreenReplay.payload(
            for: .fixture(lines: ["jinto@m3 ~ % ls", "Desktop", "Downloads"])
        )
        XCTAssertTrue(payload.contains("jinto@m3 ~ % ls"))
        XCTAssertTrue(payload.contains("Desktop"))
        XCTAssertTrue(payload.contains("Downloads"))
    }

    func test_payload_dims_the_previous_screen() {
        let payload = RestoredScreenReplay.payload(for: .fixture(lines: ["hello"]))
        XCTAssertTrue(payload.contains("\u{1B}[2mhello\u{1B}[0m"))
    }

    func test_payload_drops_trailing_blank_lines() {
        let payload = RestoredScreenReplay.payload(for: .fixture(lines: ["hello", "", "   "]))
        XCTAssertEqual(payload.components(separatedBy: "\u{1B}[2m").count - 1, 2) // header + one line
    }

    func test_empty_screen_produces_no_payload() {
        XCTAssertTrue(RestoredScreenReplay.payload(for: .fixture(lines: [])).isEmpty)
        XCTAssertTrue(RestoredScreenReplay.payload(for: .fixture(lines: ["", "  "])).isEmpty)
    }

    func test_command_only_reads_the_file_so_screen_text_is_never_executed() {
        let command = RestoredScreenReplay.command(forPayloadAt: "/tmp/replay")
        XCTAssertEqual(command, "cat '/tmp/replay' && rm -f '/tmp/replay'\n")
    }

    func test_command_quotes_paths_containing_shell_metacharacters() {
        let command = RestoredScreenReplay.command(forPayloadAt: "/tmp/a b; rm -rf ~")
        XCTAssertEqual(command, "cat '/tmp/a b; rm -rf ~' && rm -f '/tmp/a b; rm -rf ~'\n")
    }

    func test_command_escapes_single_quotes_in_the_path() {
        let command = RestoredScreenReplay.command(forPayloadAt: "/tmp/it's")
        XCTAssertEqual(command, "cat '/tmp/it'\\''s' && rm -f '/tmp/it'\\''s'\n")
    }

    func test_prepare_writes_the_payload_where_the_shell_can_read_it() throws {
        let directory = NSTemporaryDirectory() + "cs-replay-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let command = try XCTUnwrap(
            RestoredScreenReplay.prepare(snapshot: .fixture(lines: ["restored"]), directory: directory)
        )

        let written = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: directory).first
        )
        let contents = try String(contentsOfFile: directory + "/" + written, encoding: .utf8)
        XCTAssertTrue(contents.contains("restored"))
        XCTAssertTrue(command.contains(written))
    }

    func test_prepare_returns_nil_for_an_empty_screen() {
        XCTAssertNil(RestoredScreenReplay.prepare(snapshot: .fixture(lines: [])))
    }

    // MARK: - Replay for a tab that reopens over ssh

    func test_inline_command_reproduces_the_payload_byte_for_byte() throws {
        // Screen text is data, not code: quotes, backslashes and percent signs
        // have to come out the far side unchanged.
        let snapshot = TerminalSnapshotViewData.fixture(
            lines: ["jinto@m3 % grep 'a\\b' *.txt", "100% done", "it's fine"]
        )
        let command = try XCTUnwrap(RestoredScreenReplay.inlineCommand(for: snapshot))

        XCTAssertEqual(try shellOutput(of: command), RestoredScreenReplay.payload(for: snapshot))
    }

    func test_inline_command_carries_no_local_file_the_remote_cannot_read() throws {
        let command = try XCTUnwrap(
            RestoredScreenReplay.inlineCommand(for: .fixture(lines: ["restored"]))
        )
        XCTAssertFalse(command.contains(NSTemporaryDirectory()))
    }

    func test_inline_command_returns_nil_for_an_empty_screen() {
        XCTAssertNil(RestoredScreenReplay.inlineCommand(for: .fixture(lines: [])))
    }

    private func shellOutput(of command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
