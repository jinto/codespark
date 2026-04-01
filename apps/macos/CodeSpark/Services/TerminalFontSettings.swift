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

    static func buildConfigString() -> String {
        "font-family = \(resolvedFontFamily())\nfont-size = \(Int(resolvedFontSize()))\n"
    }
}
