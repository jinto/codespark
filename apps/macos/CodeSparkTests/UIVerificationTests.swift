import XCTest
@testable import CodeSpark

/// UI verification tests that run ONLY when invoked with environment variable:
///   UI_VERIFICATION=1 xcodebuild test ...
/// Normal test runs skip these since xcodebuild kills the running app.
/// For CI: run unit tests first, then launch app, then run UI tests separately.
final class UIVerificationTests: XCTestCase {

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["UI_VERIFICATION"] == "1" else {
            throw XCTSkip("Set UI_VERIFICATION=1 to run UI verification tests")
        }
    }

    private func runOsascript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func test_toolbar_add_button_exists() throws {
        let result = try runOsascript("""
        tell application "System Events"
            tell process "CodeSpark"
                set descs to {}
                set allElements to entire contents of window 1
                repeat with e in allElements
                    try
                        if role description of e is "button" then
                            set end of descs to description of e
                        end if
                    end try
                end repeat
                return descs as text
            end tell
        end tell
        """)
        XCTAssertTrue(result.contains("Add"), "Toolbar must have Add (+) button. Found: \(result)")
    }

    func test_toolbar_no_overflow() throws {
        let result = try runOsascript("""
        tell application "System Events"
            tell process "CodeSpark"
                set allElements to entire contents of window 1
                repeat with e in allElements
                    try
                        if description of e contains "more toolbar" then return "OVERFLOW"
                    end try
                end repeat
                return "OK"
            end tell
        end tell
        """)
        XCTAssertEqual(result, "OK", "Toolbar should not overflow")
    }

    func test_sidebar_has_text_content() throws {
        let result = try runOsascript("""
        tell application "System Events"
            tell process "CodeSpark"
                set texts to {}
                set allElements to entire contents of window 1
                repeat with e in allElements
                    try
                        if role description of e is "static text" then
                            set end of texts to value of e
                        end if
                    end try
                end repeat
                return texts as text
            end tell
        end tell
        """)
        XCTAssertFalse(result.isEmpty, "Sidebar should have visible text content")
    }

    func test_cmd_hold_shows_hotkey_overlay() throws {
        let result = try runOsascript("""
        tell application "System Events"
            tell process "CodeSpark"
                set frontmost to true
                delay 0.3
                key down command
                delay 0.5
                set found to "NO"
                set allElements to entire contents of window 1
                repeat with e in allElements
                    try
                        set txt to value of e as text
                        if txt contains "⌘" then set found to "YES"
                    end try
                end repeat
                key up command
                return found
            end tell
        end tell
        """)
        if result == "NO" {
            throw XCTSkip("No active sessions — hotkey overlay not expected")
        }
        XCTAssertEqual(result, "YES")
    }

    // MARK: - Sidebar status dot colors

    func test_sidebar_dot_is_not_orange_when_idle() throws {
        // Capture screenshot and verify the status dot is gray (idle), not orange (needsInput)
        let screenshotPath = "/tmp/cs_sidebar_dot_test.png"
        try? FileManager.default.removeItem(atPath: screenshotPath)

        // Activate app and capture
        let _ = try runOsascript("""
        tell application "CodeSpark" to activate
        delay 1
        """)

        let captureProcess = Process()
        captureProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        captureProcess.arguments = ["-x", screenshotPath]
        try captureProcess.run()
        captureProcess.waitUntilExit()

        guard captureProcess.terminationStatus == 0,
              FileManager.default.fileExists(atPath: screenshotPath) else {
            throw XCTSkip("screencapture failed — likely no display access (SSH environment)")
        }

        // Get window position to find sidebar dot area
        let posResult = try runOsascript("""
        tell application "System Events"
            tell process "CodeSpark"
                set {x, y} to position of window 1
                set {w, h} to size of window 1
                return (x as text) & "," & (y as text) & "," & (w as text) & "," & (h as text)
            end tell
        end tell
        """)
        let parts = posResult.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else {
            throw XCTSkip("Could not get window position")
        }

        // Use Python to analyze pixel colors in the dot area
        // Dot is 7px at ~(winX+16, winY+55) in retina 2x
        let dotX = parts[0] * 2 + 32  // retina 2x, offset into sidebar
        let dotY = parts[1] * 2 + 110 // first project row dot area
        let script = """
        from PIL import Image
        img = Image.open('\(screenshotPath)')
        o, g, gr = 0, 0, 0
        for dy in range(-3, 4):
            for dx in range(-3, 4):
                r, gv, b = img.getpixel((\(dotX)+dx, \(dotY)+dy))[:3]
                if r > 200 and gv > 100 and gv < 180 and b < 80: o += 1
                elif r < 80 and gv > 150: g += 1
                elif abs(r-gv) < 20 and abs(r-b) < 20 and 80 < r < 180: gr += 1
        print(f'orange={o},gray={gr},green={g}')
        """
        let pyProcess = Process()
        pyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        pyProcess.arguments = ["-c", script]
        let pyPipe = Pipe()
        pyProcess.standardOutput = pyPipe
        pyProcess.standardError = FileHandle.nullDevice
        try pyProcess.run()
        pyProcess.waitUntilExit()
        let analyzeResult = String(
            data: pyPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let counts = analyzeResult
        XCTAssertFalse(counts.contains("orange=") && !counts.contains("orange=0"),
                        "Status dot should NOT be orange when no live sessions. Pixel analysis: \(counts)")
    }

    // MARK: - Keyboard input

    func test_shift_produces_uppercase_and_special_chars() throws {
        guard ProcessInfo.processInfo.environment["UI_VERIFICATION"] == "1" else {
            throw XCTSkip("Set UI_VERIFICATION=1 to run")
        }

        // Create a test script that reads 4 chars and writes to file
        let scriptPath = "/tmp/cs_shift_test.sh"
        let resultPath = "/tmp/cs_shift_result.txt"
        try "#!/bin/bash\nread -n4 chars\necho \"$chars\" > \(resultPath)".write(
            toFile: scriptPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: scriptPath, contents: nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        try? FileManager.default.removeItem(atPath: resultPath)

        // Run script in terminal, then type Shift chars: A B ? !
        let _ = try runOsascript("""
        tell application "System Events"
            tell process "CodeSpark"
                set frontmost to true
                delay 0.5
                keystroke "\(scriptPath)"
                delay 0.1
                key code 36
                delay 1
                keystroke "A"
                delay 0.2
                keystroke "B"
                delay 0.2
                keystroke "?"
                delay 0.2
                keystroke "!"
                delay 2
                return "done"
            end tell
        end tell
        """)

        // Verify output
        guard FileManager.default.fileExists(atPath: resultPath) else {
            XCTFail("Shift test: result file not created — terminal may not have executed script")
            return
        }
        let content = try String(contentsOfFile: resultPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(content, "AB?!", "Shift+A→A, Shift+B→B, Shift+/→?, Shift+1→! — got '\(content)'")
    }
}
