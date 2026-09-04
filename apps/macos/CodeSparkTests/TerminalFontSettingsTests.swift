import XCTest
import AppKit
import CoreText
@testable import CodeSpark

/// Ghostty renders a codepoint no font in its collection claims as *nothing* —
/// the cell still advances, so a screen full of Korean keeps its layout and
/// loses only its glyphs. Whether Hangul reaches the collection at all is
/// decided by the config string these tests read.
final class TerminalFontSettingsTests: XCTestCase {

    private func families(in config: String) -> [String] {
        config.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("font-family = ") else { return nil }
            return String(line.dropFirst("font-family = ".count))
        }
    }

    private func canDrawHangul(_ family: String) -> Bool {
        guard let font = NSFont(name: family, size: 13) else { return false }
        var characters = Array("가".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count)
    }

    func test_the_config_names_a_font_that_can_draw_hangul() {
        // Menlo is the default and has no Hangul at all. Without a family that
        // does, every Korean glyph depends on Ghostty's runtime search — and a
        // search that fails once is cached as a miss for the life of the app.
        let named = families(in: TerminalFontSettings.buildConfigString(primary: "Menlo"))
        XCTAssertTrue(
            named.contains(where: canDrawHangul),
            "no font in \(named) has a glyph for 가 — Korean would be left to font discovery"
        )
    }

    func test_the_primary_font_stays_first() {
        // Ghostty takes its metrics and its ASCII from the first family; the
        // fallback is appended, never substituted.
        let named = families(in: TerminalFontSettings.buildConfigString(primary: "Menlo"))
        XCTAssertEqual(named.first, "Menlo")
    }

    func test_a_hangul_primary_is_not_repeated_as_its_own_fallback() throws {
        let primary = try XCTUnwrap(TerminalFontSettings.hangulFallbackFamily())
        let named = families(in: TerminalFontSettings.buildConfigString(primary: primary))
        XCTAssertEqual(named, [primary])
    }

    func test_the_declared_fallbacks_exist_on_this_mac() {
        // A name macOS does not know is silently no font at all, which is the
        // failure this whole change is trying to stop being possible.
        XCTAssertNotNil(
            TerminalFontSettings.hangulFallbackFamily(),
            "none of \(TerminalFontSettings.hangulFallbackFamilies) is installed"
        )
    }
}
