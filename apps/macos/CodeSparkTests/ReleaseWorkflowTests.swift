import XCTest

/// 릴리즈는 `vendor/`를 커밋하지 않으므로 CI가 ghostty를 직접 받아온다.
/// 받아오는 지점이 커밋에 고정돼 있지 않으면 릴리즈 빌드는 **업스트림 main과
/// 경주한다** — 우리 쪽에서 아무것도 바꾸지 않아도 어느 날 갑자기 깨진다.
/// v1.1.4가 그렇게 죽었다: `ghostty_runtime_read_clipboard_cb`가 인자 3개에서
/// 6개로 늘어난 것을 CI만 알고 있었다(로컬 `vendor/ghostty`는 4월 트리라 멀쩡).
///
/// 어떤 유닛 테스트로도 안 보이는 종류라 워크플로 파일 자체를 검사한다.
/// `SidebarTypographyTests`와 같은 성격의 게이트다.
final class ReleaseWorkflowTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CodeSparkTests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // repo root
    }

    /// `git fetch --depth 1 origin <ref>`로 커밋을 집어오려면 **전체 40자 SHA**
    /// 여야 한다. 짧은 SHA도, 태그 이름도 shallow fetch에서는 거절당한다.
    func test_the_pinned_ghostty_is_a_full_commit_sha() throws {
        let pin = try String(contentsOf: repoRoot.appendingPathComponent(".ghostty-version"),
                             encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(
            pin.count, 40,
            """
            .ghostty-version = "\(pin)" — shallow fetch는 전체 40자 SHA만 받는다.
            `git -C vendor/ghostty rev-parse HEAD`의 출력을 그대로 넣을 것.
            """)
        XCTAssertNil(
            pin.range(of: "[^0-9a-f]", options: .regularExpression),
            ".ghostty-version = \"\(pin)\" — 커밋 SHA가 아니다")
    }

    /// 핀은 파일에만 있으면 소용없다. 받아오는 **모든** 지점이 그 파일을 읽어야 한다.
    /// 캐시 적중 분기도 마찬가지다 — 그쪽은 헤더만 받아오는데, 낡은 xcframework에
    /// 오늘자 헤더를 짝지어 주는 게 더 나쁘다.
    func test_every_ghostty_checkout_in_the_release_reads_the_pin() throws {
        let workflow = repoRoot
            .appendingPathComponent(".github/workflows/release.yml")
        let source = try String(contentsOf: workflow, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)

        let fetchesGhostty = lines.enumerated().filter {
            $0.element.contains("ghostty-org/ghostty")
        }
        XCTAssertFalse(
            fetchesGhostty.isEmpty,
            "release.yml이 ghostty를 받아오지 않는다 — 이 게이트가 무엇도 지키지 못한다")

        var unpinned: [String] = []
        for (index, line) in fetchesGhostty {
            // `git clone <url> <dir>`은 커밋을 가리킬 방법이 없다. 핀을 지키는
            // 유일한 형태는 remote를 걸고 SHA를 fetch하는 쪽이다.
            guard line.contains("git clone") else { continue }
            unpinned.append("release.yml:\(index + 1)  "
                + line.trimmingCharacters(in: .whitespaces))
        }
        XCTAssertTrue(
            unpinned.isEmpty,
            """
            ghostty를 핀 없이 clone한다 — 릴리즈가 업스트림 main과 경주한다:
            \(unpinned.joined(separator: "\n"))
            `git init` + `git fetch --depth 1 origin "$(cat .ghostty-version)"`로 받을 것.
            """)

        XCTAssertTrue(
            source.contains(".ghostty-version"),
            "받아오는 지점이 .ghostty-version을 읽지 않는다")
    }
}
