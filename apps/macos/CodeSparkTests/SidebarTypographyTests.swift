import XCTest

/// 선택되면 굵어지는 라벨은 글자 폭이 함께 변한다. 클릭하는 순간 그 행의 글자들이
/// 커서 밑에서 제자리 리플로우되고, 클릭이 딸깍이 아니라 덜컹으로 읽힌다.
/// 배경과 글자색이 이미 선택을 말하고 있으므로 두께까지 흔들 이유가 없다.
///
/// 뷰를 만들어 값을 읽는 테스트로는 안 보이는 종류라 소스에서 패턴 자체를 막는다.
/// `keyboardShortcut("…")` 인라인 금지와 같은 성격의 게이트다.
final class SidebarTypographyTests: XCTestCase {
    func test_no_row_label_reweights_itself_when_selected() throws {
        // Every source file, not just `Views/`: rows are drawn from `Terminal/`
        // too, and a label that reweights itself is the same jitter wherever it
        // is written.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CodeSparkTests
            .deletingLastPathComponent()  // macos
            .appendingPathComponent("CodeSpark")

        // Catches `weight: isSelected ? …` and the other spellings of the same
        // thing: `.fontWeight(isActive ? …)`, `.bold(isSelected)`, and a whole
        // font swapped on state (`.font(isActive ? .headline : .caption)`).
        let reweight = try NSRegularExpression(
            pattern: #"(weight:\s*is\w+\s*\?|fontWeight\(\s*is\w+\s*\?|\.bold\(\s*is\w+|\.font\(\s*is\w+\s*\?)"#
        )
        var offenders: [String] = []

        let files = FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard reweight.firstMatch(in: line, range: range) != nil else { continue }
                offenders.append(
                    "\(file.lastPathComponent):\(index + 1)  "
                        + line.trimmingCharacters(in: .whitespaces))
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "상태에 따라 글꼴 두께가 바뀌면 글자가 움직인다. 두께는 고정하고 배경·색으로 구분할 것:\n"
                + offenders.joined(separator: "\n")
        )
    }
}
