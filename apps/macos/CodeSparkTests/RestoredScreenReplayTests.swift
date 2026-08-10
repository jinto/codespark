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
}
