import AppKit

enum TerminalFontSettings {
    static func resolvedFontFamily() -> String {
        let custom = UserDefaults.standard.string(forKey: "terminalFontFamily") ?? ""
        if !custom.isEmpty, NSFont(name: custom, size: 14) != nil { return custom }

        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let candidates: [(String, String)] = switch lang {
        case "ko": [("D2Coding", "D2Coding"), ("D2CodingLigature-Regular", "D2Coding Ligature")]
        case "ja": [("SarasaMono-J-Regular", "Sarasa Mono J"), ("NotoSansMonoCJKjp", "Noto Sans Mono CJK JP")]
        default: [("JetBrainsMono-Regular", "JetBrains Mono")]
        }
        for (psName, _) in candidates {
            if NSFont(name: psName, size: 14) != nil { return psName }
        }
        return "Menlo"
    }

    static func resolvedFontSize() -> Double {
        let custom = UserDefaults.standard.double(forKey: "terminalFontSize")
        if custom > 0 { return custom }
        return 13
    }

    /// Ships with macOS, in this order of preference. Named in the config so
    /// Hangul is answered by the font collection rather than by a search.
    static let hangulFallbackFamilies = ["Apple SD Gothic Neo", "AppleGothic"]

    /// The first Hangul-capable family this Mac has, or nil if it has none.
    ///
    /// Menlo — the default, and what most people leave the setting at — has no
    /// Hangul at all, so every Korean glyph in the terminal is found by
    /// Ghostty's runtime font discovery. That search is allowed to fail, and a
    /// failure is permanent: `SharedGrid.getIndex` caches the miss ("this even
    /// caches negative matches") for the life of the grid, and every surface in
    /// the app shares one grid. One unlucky lookup and Korean is blank in every
    /// tab — the cells still advance two columns, so the screen keeps its
    /// layout and only the glyphs are gone — until the app is relaunched.
    ///
    /// Naming the font here puts the face in the collection, where
    /// `CodepointResolver.getIndex` finds it before it ever reaches discovery.
    static func hangulFallbackFamily() -> String? {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return hangulFallbackFamilies.first { installed.contains($0) }
    }

    /// Repeating `font-family` appends a fallback rather than replacing the
    /// primary — Ghostty searches them in order.
    static func buildConfigString(primary: String = resolvedFontFamily()) -> String {
        var lines = ["font-family = \(primary)"]
        if let hangul = hangulFallbackFamily(), hangul != primary {
            lines.append("font-family = \(hangul)")
        }
        lines.append("font-size = \(Int(resolvedFontSize()))")
        return lines.joined(separator: "\n") + "\n"
    }
}
