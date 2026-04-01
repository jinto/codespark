import XCTest
import AppKit
@testable import CodeSpark

final class ClipboardImageHandlerTests: XCTestCase {

    func test_hasImage_returns_false_for_text_only() {
        let pb = NSPasteboard(name: .init("test_text"))
        pb.clearContents()
        pb.setString("hello", forType: .string)
        XCTAssertFalse(ClipboardImageHandler.hasImage(pasteboard: pb))
    }

    func test_hasImage_returns_true_for_png() {
        let pb = NSPasteboard(name: .init("test_png"))
        pb.clearContents()
        // Create a tiny 1x1 PNG
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not create PNG"); return
        }
        pb.setData(png, forType: .png)
        XCTAssertTrue(ClipboardImageHandler.hasImage(pasteboard: pb))
    }

    func test_saveImageToTempFile_creates_file_with_correct_path_pattern() {
        let pb = NSPasteboard(name: .init("test_save"))
        pb.clearContents()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.blue.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not create PNG"); return
        }
        pb.setData(png, forType: .png)

        let path = ClipboardImageHandler.saveImageToTempFile(pasteboard: pb)
        XCTAssertNotNil(path)
        guard let path else { return }

        // Path format: {NSTemporaryDirectory()}clipboard-{timestamp}-{UUID}.png
        XCTAssertTrue(path.hasPrefix(NSTemporaryDirectory()), "Path should start with temp dir")
        XCTAssertTrue(path.contains("clipboard-"), "Path should contain 'clipboard-'")
        XCTAssertTrue(path.hasSuffix(".png"))

        // File actually exists and has content
        let data = FileManager.default.contents(atPath: path)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)

        // Cleanup
        try? FileManager.default.removeItem(atPath: path)
    }

    func test_saveImageToTempFile_returns_nil_for_text_clipboard() {
        let pb = NSPasteboard(name: .init("test_noimg"))
        pb.clearContents()
        pb.setString("just text", forType: .string)

        let path = ClipboardImageHandler.saveImageToTempFile(pasteboard: pb)
        XCTAssertNil(path)
    }

    // MARK: - SCP arguments

    func test_scpArguments_basic() {
        let info = SSHConnectionInfo(host: "example.com", user: "alice")
        let (args, remotePath) = ClipboardImageHandler.scpArguments(
            localPath: "/tmp/clipboard-2026-04-08-120000-ABCD1234.png",
            sshInfo: info
        )
        XCTAssertEqual(args, [
            "/tmp/clipboard-2026-04-08-120000-ABCD1234.png",
            "alice@example.com:/tmp/clipboard-2026-04-08-120000-ABCD1234.png"
        ])
        XCTAssertEqual(remotePath, "/tmp/clipboard-2026-04-08-120000-ABCD1234.png")
    }

    func test_scpArguments_with_port() {
        let info = SSHConnectionInfo(host: "example.com", user: "bob", port: 2222)
        let (args, remotePath) = ClipboardImageHandler.scpArguments(
            localPath: "/var/folders/xx/T/clipboard-test.png",
            sshInfo: info
        )
        XCTAssertEqual(args, ["-P", "2222", "/var/folders/xx/T/clipboard-test.png", "bob@example.com:/tmp/clipboard-test.png"])
        XCTAssertEqual(remotePath, "/tmp/clipboard-test.png")
    }

    func test_scpArguments_no_user() {
        let info = SSHConnectionInfo(host: "myserver.local")
        let (args, _) = ClipboardImageHandler.scpArguments(
            localPath: "/tmp/test.png",
            sshInfo: info
        )
        XCTAssertEqual(args, ["/tmp/test.png", "myserver.local:/tmp/test.png"])
    }

    func test_saveImageToTempFile_handles_tiff_clipboard() {
        let pb = NSPasteboard(name: .init("test_tiff"))
        pb.clearContents()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.green.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else {
            XCTFail("Could not create TIFF"); return
        }
        pb.setData(tiff, forType: .tiff)

        let path = ClipboardImageHandler.saveImageToTempFile(pasteboard: pb)
        XCTAssertNotNil(path, "TIFF clipboard should be convertible to PNG file")

        if let path { try? FileManager.default.removeItem(atPath: path) }
    }
}
