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

    // MARK: - 게이트가 실제로 막는가
    //
    // 2026-08-30 전수조사에서 나온 것: 이 리포가 "테스트로 막는다"고 선언한
    // 게이트 셋이 **아무것도 막고 있지 않았다.** Stop 훅은 [BLOCKED]을 찍고
    // exit 0 했고, Zig 빌드 페이즈는 실패할 수 없었고, `zig build test`는
    // 어디서도 안 돌았다. 셋을 합치면 `store.zig`가 통째로 깨져도
    // pre-commit·pre-push·릴리즈가 전부 초록이었다.
    //
    // 게이트를 고치는 것과 그게 열린 걸 알아채는 것은 다른 일이라,
    // 여기서 파일을 직접 읽는다.

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Stop 훅은 **exit 2에서만** 막는다. 메시지를 찍고 스크립트 끝으로
    /// 떨어지면 exit 0이고, 그게 이 훅의 전 생애였다.
    func test_the_stop_hook_can_actually_block() throws {
        let hook = try contents(".claude/hooks/check-tests.sh")

        XCTAssertTrue(
            hook.contains("exit 2"),
            "check-tests.sh가 exit 2를 하지 않는다 — [BLOCKED]을 찍어도 통과시킨다")
        XCTAssertTrue(
            hook.contains("git diff HEAD"),
            "check-tests.sh가 unstaged만 본다 — git add 하는 순간 눈이 먼다")
    }

    /// 스크립트의 종료 상태는 마지막 명령의 것이다. 여기서는 `rm -rf`였고,
    /// 그건 거의 항상 성공한다 — 그래서 zig 컴파일 에러가 나도 Xcode 빌드가
    /// 초록이었고, 디스크에 있던 낡은 `.a`를 링크했다.
    func test_the_zig_build_phase_can_fail() throws {
        let pbxproj = try contents("apps/macos/CodeSpark.xcodeproj/project.pbxproj")

        XCTAssertTrue(
            pbxproj.contains("set -euo pipefail"),
            "Zig 빌드 페이즈에 set -e가 없다 — 컴파일 에러가 빌드를 멈추지 못한다")
        // `project.yml`은 xcodegen 스펙이고 실제로 도는 건 pbxproj다.
        // 둘이 벌어지면 `scripts/build-macos.sh`가 낡은 쪽으로 덮어쓴다.
        XCTAssertTrue(
            try contents("apps/macos/project.yml").contains("set -euo pipefail"),
            "스펙과 pbxproj가 벌어졌다 — xcodegen이 고친 것을 되돌린다")
    }

    /// 스토어는 모든 프로젝트와 세션을 들고 있는 유일한 것이다.
    /// 그 39개 테스트가 훅에도 CI에도 없었다.
    func test_the_store_tests_run_in_both_gates() throws {
        // `zig build test`가 아니라 `build test`를 찾는다: 두 게이트 모두
        // zig를 절대 경로로 찾아 `"$ZIG"`로 부른다 — /opt/homebrew/bin은
        // 로그인 셸에만 있어서 이름만으로는 못 찾는 자리가 있기 때문이다.
        XCTAssertTrue(
            try contents(".githooks/pre-commit").contains("build test"),
            "pre-commit이 workspace-core 테스트를 돌리지 않는다")
        XCTAssertTrue(
            try contents(".github/workflows/release.yml").contains("build test"),
            "릴리즈가 workspace-core 테스트를 돌리지 않는다")
    }

    /// Quoting for a remote shell lived in three files, byte for byte the same,
    /// and the tilde expression in three more. That is the duplication that
    /// matters most: it is where a directory name becomes shell syntax, so a
    /// correction landing in one copy and not the others is a hole that looks
    /// closed. The same family had already drifted — the two ssh option blocks
    /// still disagree about `ConnectTimeout`, with nothing saying which is meant.
    func test_only_one_file_knows_how_to_quote_for_a_remote_shell() throws {
        let services = repoRoot.appendingPathComponent("apps/macos/CodeSpark")
        let files = FileManager.default.enumerator(at: services, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "RemoteShell.swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no sources to scan — this gate would guard nothing")

        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Two tells, both free of backslashes so the pattern cannot drift
            // from what it is looking for: the single-quote escape dance, and
            // the leading-tilde expansion.
            // The opening quote of the dance, not just any single-quote
            // replacement: `RestoredScreenReplay` legitimately rewrites `'` as
            // `\047` for `printf`, which is a different job.
            if source.contains(##""'" + "##)
                || source.contains(##"hasPrefix("~/")"##) {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(offenders.joined(separator: ", "))가 자기만의 원격 셸 따옴표/틸드 전개를 갖고 있다.
            `RemoteShell.quoted` / `RemoteShell.pathExpression`을 쓸 것 — 사본이 갈라지면
            한쪽만 고쳐놓고 고쳤다고 믿게 된다.
            """)
    }

    /// 두 겹이 함께여야 한다. `create-dmg … || true`가 실패를 삼키고,
    /// 업로드 액션의 `fail_on_unmatched_files` 기본값이 false라
    /// **DMG 없는 초록 릴리즈**가 나올 수 있었다.
    func test_a_release_cannot_publish_without_its_dmg() throws {
        let workflow = try contents(".github/workflows/release.yml")

        // create-dmg 호출의 마지막 인자가 "$APP_PATH"다. 여기서 `[\\s\\S]*?`로
        // 훑으면 뒤에 있는 keychain 정리의 정당한 `|| true`까지 걸리고,
        // 심지어 이 규칙을 설명하는 주석 자신에도 걸린다.
        XCTAssertNil(
            workflow.range(of: "\"\\$APP_PATH\"\\s*\\|\\| true", options: .regularExpression),
            "create-dmg의 실패가 삼켜진다 — DMG 없는 릴리즈가 발행된다")
        XCTAssertTrue(
            workflow.contains("fail_on_unmatched_files: true"),
            "붙일 DMG가 없어도 업로드가 성공한다 (기본값이 false다)")
    }
}
