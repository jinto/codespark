import AppKit
import XCTest
@testable import CodeSpark

/// Ghostty가 표면에 대해 우리에게 말을 거는 두 순간 — "이 탭 닫아라"와 "다시
/// 그려라" — 을 소스에서 고정한다.
///
/// 둘 다 실행 중인 앱에서만 드러난다. 유닛 테스트 환경에서는
/// `GhosttyRuntime.initialize()`가 통째로 건너뛰므로 표면 자체가 없고, 만들
/// 수 있다 해도 검증 대상은 "우리가 넘긴 포인터를 Ghostty가 콜백에 되돌려
/// 주는가"와 "프레임이 실제로 다시 칠해지는가"라 화면을 봐야 한다. 그래서
/// `test_no_row_label_reweights_itself_when_selected`와 같은 성격의 소스
/// 게이트다 — 실측 오라클은 각 테스트 주석에 적어 둔다.
final class SurfaceLifecycleTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CodeSparkTests
            .deletingLastPathComponent()  // macos
            .appendingPathComponent("CodeSpark/Terminal/\(name)")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// `close_surface_cb`가 받는 유일한 포인터는 `config.userdata`다.
    /// `config.platform.macos.nsview`는 Ghostty가 그림을 그리는 대상일 뿐 콜백에
    /// 되돌아오지 않는다. 비워 두면 콜백이 nil을 받아 첫 줄에서 돌아가고,
    /// 셸이 끝난 탭(`exit`, 끊긴 ssh)은 "Process exited. Press any key to close
    /// the terminal."을 찍은 채 영영 남는다 — 그 키 입력도 같은 close로 가서
    /// 같이 버려지므로 어떤 키로도 못 닫는다.
    ///
    /// 실측 오라클: 로컬 탭에서 `exit` → 탭이 사라져야 한다.
    func test_a_surface_hands_its_own_view_to_the_close_callback() throws {
        let source = try source("GhosttyTerminalSurfaceView.swift")
        XCTAssertTrue(
            source.contains("config.userdata = Unmanaged.passUnretained(view).toOpaque()"),
            """
            표면이 자기 뷰를 `config.userdata`로 넘기지 않으면 close 콜백이 nil을 \
            받는다. 셸이 끝난 탭을 아무도 정리하지 못하고, 키로도 닫히지 않는다.
            """
        )
    }

    /// libghostty는 표면을 **포커스된 채로** 만들고(`renderer/Thread.zig`
    /// `focused: bool = true`), `set_focus(false)`를 받아야만 display link를 멈춘다.
    /// 우리 미러가 `false`로 시작하면 한 번도 포커스를 못 받은 탭 — 프로젝트를
    /// 열 때 한꺼번에 만들어지는 나머지 탭들 — 에는 그 호출이 영영 안 간다.
    /// 앱이 배경일 때도 마찬가지라 창의 key 변화도 들어야 한다.
    ///
    /// 실측 오라클: 탭이 2개 이상인 프로젝트를 열고 `sample <pid> 2`에서
    /// `CVDisplayLink` 스레드 수를 센다. 앞에 있으면 1, 배경이면 0이어야 한다
    /// (고치기 전: 탭 수만큼. 2026-09-15 사용자 기계에서 14개 중 13개).
    func test_a_surface_starts_believing_what_libghostty_believes() throws {
        let source = try source("GhosttyTerminalSurfaceView.swift")
        XCTAssertTrue(
            source.contains("private var surfaceFocused = true"),
            "미러가 libghostty의 초기값(focused)과 다르면 안 본 탭에 set_focus(false)가 안 간다."
        )
        XCTAssertTrue(
            source.contains("NSWindow.didResignKeyNotification"),
            "창이 key를 잃어도 first responder는 그대로라, key 알림을 듣지 않으면 배경에서도 그린다."
        )
    }

    /// 다시 보이게 된 표면은 스스로 그리지 않는다. 렌더는 셸의 출력이나 크기
    /// 변화로만 걸리는데, idle 프롬프트에 두고 온 탭에는 둘 다 없다.
    /// 예전엔 같은 크기로 `set_size`를 불러 재렌더를 유도했지만, Ghostty의
    /// `updateSize`는 크기가 그대로면 첫 줄에서 돌아간다(`apprt/embedded.zig`,
    /// 이유로 SwiftUI를 명시한다) — 크기가 우연히 달라질 때만 듣던 no-op이었다.
    ///
    /// 실측 오라클: 출력이 끝난 탭에서 다른 탭으로 갔다 돌아왔을 때 화면이
    /// 비어 있고 Ctrl-L로 살아나면 회귀다.
    /// 포커스를 주장하는 곳은 표면 뷰 하나뿐이어야 한다.
    ///
    /// 예전엔 셋이었다: 표면의 `mouseDown`, `updateNSView`의 일회성
    /// `DispatchQueue.main.async`, 그리고 `AppModel.focusActiveTerminal()`의
    /// `asyncAfter(0.15)`. 뒤의 둘은 실패를 확인하지 않았고, 타이머 쪽은 FIFO도
    /// 아니라 150ms 안에 탭을 바꾸면 낡은 표면에 내려앉았다 — 게다가 빈 화면의
    /// New Terminal 버튼 두 곳에만 붙어 있어서, 정작 가장 흔한 경로인
    /// `Cmd+T` → 세션 선택 → New Terminal은 아무 보호가 없었다.
    ///
    /// 주장할 자격이 있는지는 뷰만이 안다(창이 붙었는가, 숨겨졌는가). 밖에서
    /// 부르는 `makeFirstResponder`가 다시 생기면 그 판단이 다시 흩어진다.
    func test_only_the_surface_view_claims_the_keyboard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodeSpark")

        var offenders: [String] = []
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []

        for file in files where file.pathExtension == "swift" {
            guard file.lastPathComponent != "GhosttyTerminalSurfaceView.swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                // 주석에 이름이 나오는 것은 설명이지 호출이 아니다.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                guard code.contains("makeFirstResponder(") else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1)  " + code)
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            포커스 주장은 표면 뷰가 스스로 한다(`claimFocus`). 밖에서 부르면 \
            창이 붙었는지·숨겨졌는지 모르는 채로 부르게 되고, 실패해도 아무도 \
            모른다:
            """ + "\n" + offenders.joined(separator: "\n")
        )
    }

    /// 포커스 주장은 **커밋이 끝난 뒤에** 일어나야 한다.
    ///
    /// 실측: 시트가 떠 있는 동안 탭을 바꾸면, `viewDidUnhide` 안에서 동기로
    /// 얻은 first responder를 같은 SwiftUI 커밋이 되돌려 놓는다(나가는 뷰의
    /// `updateNSView`가 그것을 숨기는 순간). 포커스는 창에 남고 **회복되지
    /// 않는다** — 고치려던 증상 그대로다. 순수 AppKit은 형제 뷰에게 이런 짓을
    /// 하지 않으므로 이건 SwiftUI의 장부다.
    ///
    /// 프로브 로그(동기 버전):
    ///     viewDidUnhide: A claims focus -> true  fr=A
    ///     updateNSView A active=true             fr=A
    ///     A.resignFirstResponder
    ///     updateNSView C active=false            fr=window   ← 영구
    ///
    /// 실행 중인 앱에서만, 그것도 특정 순서에서만 보이는 종류라 소스에서 막는다.
    func test_the_focus_claim_waits_for_the_commit_to_end() throws {
        let source = try source("GhosttyTerminalSurfaceView.swift")
        guard let body = source.range(of: "func claimFocus() {") else {
            return XCTFail("claimFocus()가 없다 — 포커스 주장의 주인이 바뀌었다면 이 게이트도 옮겨야 한다.")
        }
        let after = String(source[body.upperBound...].prefix(400))
        XCTAssertTrue(
            after.contains("DispatchQueue.main.async"),
            """
            claimFocus()가 동기로 주장하면, 시트가 떠 있는 동안의 탭 전환에서 \
            SwiftUI가 같은 커밋 안에서 포커스를 되돌리고 창에 고착된다.
            """
        )
        XCTAssertTrue(
            after.contains("self.isHidden"),
            "숨겨짐 여부는 블록이 *실행될 때* 다시 물어야 한다 — 그 사이 탭이 바뀌었을 수 있다."
        )
    }

    /// libghostty에게 포커스를 알려주는 곳은 공식 Ghostty와 같은 두 콜백이다.
    /// 아무도 안 알려주던 동안 libghostty는 모든 표면이 포커스를 가졌다고 믿었고,
    /// 그래서 **타이핑이 안 되는 탭이 커서를 멀쩡히 그렸다** — 사용자가 눈으로
    /// 구분할 수 없던 이유다.
    func test_libghostty_is_told_when_the_keyboard_comes_and_goes() throws {
        let source = try source("GhosttyTerminalSurfaceView.swift")
        XCTAssertTrue(source.contains("override func becomeFirstResponder()"))
        XCTAssertTrue(source.contains("override func resignFirstResponder()"))
        XCTAssertTrue(
            source.contains("ghostty_surface_set_focus("),
            "포커스 변화를 libghostty에 전하지 않으면 커서가 포커스를 거짓말한다."
        )
    }

    func test_a_surface_coming_back_into_view_is_told_to_paint() throws {
        let source = try source("TerminalSurfaceHostView.swift")
        XCTAssertTrue(
            source.contains("ghostty_surface_refresh(surface)"),
            "unhide는 `ghostty_surface_refresh`로 렌더를 걸어야 한다."
        )
        XCTAssertFalse(
            source.contains("ghostty_surface_set_size("),
            """
            같은 크기의 `set_size`는 Ghostty가 명시적으로 무시한다. 재렌더를 \
            그걸로 유도하면 낡은 프레임이 그대로 남는다.
            """
        )
    }
}

/// 표면이 pty에 어떤 크기를 전하는가.
///
/// 메인 영역이 터미널을 내렸다 다시 올리면(탭 없는 워크트리·프로젝트를 거쳐
/// 오면) SwiftUI는 떼어낸 표면들의 프레임을 **0×0**으로 만든다(실측 — 앱의 모든
/// 표면이, 창이 없는 채로). 그걸 그대로 넘기면 Ghostty는 그리드를 1×1로 잡고
/// pty에 SIGWINCH를 보낸 뒤, 몇 ms 뒤 원래 크기로 또 보낸다. 화면 전체를 다시
/// 그리는 TUI(Claude Code)는 한 줄짜리 화면에 맞춰 그렸다가 돌아오므로 출력과
/// 입력창 사이에 빈 칸이 남는다.
///
/// 오라클: 탭에서 `trap 'echo WINCH $(stty size) >> f' WINCH; while sleep 0.1;
/// do :; done`을 돌리고 `Cmd` 숫자로 탭 없는 자리를 거쳐 온다. 고치기 전에는
/// 크기가 안 변했는데도 WINCH가 찍혔다.
final class SurfaceSizeRuleTests: XCTestCase {

    func test_a_surface_with_room_reports_its_size() {
        XCTAssertTrue(GhosttyTerminalSurfaceView.reportsSize(CGSize(width: 1784, height: 1090)))
    }

    func test_a_detached_surface_does_not_shrink_the_terminal_to_nothing() {
        XCTAssertFalse(GhosttyTerminalSurfaceView.reportsSize(.zero))
        XCTAssertFalse(GhosttyTerminalSurfaceView.reportsSize(CGSize(width: 1784, height: 0)))
        XCTAssertFalse(GhosttyTerminalSurfaceView.reportsSize(CGSize(width: 0, height: 1090)))
    }
}

/// 표면이 키보드를 언제 가져가는가.
///
/// 증상이 "아무 키도 안 먹는다"라서, 이 규칙이 틀리면 앱을 띄워야만 보이고
/// 그마저도 가끔만 보인다. 규칙은 값으로 고정하고, 규칙이 딛고 선 AppKit의
/// 동작은 AppKit에게 직접 다시 물어본다 — 둘 다 없으면 다음 macOS가 조용히
/// 바꿔 놓아도 알 방법이 없다.
final class SurfaceFocusRuleTests: XCTestCase {

    func test_the_tab_on_screen_takes_the_keyboard() {
        XCTAssertTrue(TerminalFocus.shouldClaim(
            isActiveTab: true, isHidden: false, hasWindow: true, isAlreadyFirstResponder: false))
    }

    func test_a_tab_that_is_not_on_screen_does_not() {
        XCTAssertFalse(TerminalFocus.shouldClaim(
            isActiveTab: false, isHidden: false, hasWindow: true, isAlreadyFirstResponder: false))
    }

    /// AppKit은 숨겨진 뷰에도 first responder를 준다(아래 테스트가 실측한다).
    /// 그래서 이 조건을 규칙이 직접 들고 있어야 한다 — 없으면 낡은 주장이
    /// 키보드를 보이지 않는 탭에 앉히고, 화면의 탭은 죽은 것처럼 보인다.
    func test_a_hidden_tab_never_takes_the_keyboard() {
        XCTAssertFalse(TerminalFocus.shouldClaim(
            isActiveTab: true, isHidden: true, hasWindow: true, isAlreadyFirstResponder: false))
    }

    /// 창이 붙기 전 — 새로 삽입된 NSViewRepresentable의 `updateNSView`가 도는
    /// 바로 그 순간이다. 여기서 주장해봐야 아무 일도 일어나지 않으므로,
    /// 창이 생겼을 때 다시 주장해야 한다는 것이 이 false의 뜻이다.
    func test_without_a_window_there_is_nothing_to_claim_from() {
        XCTAssertFalse(TerminalFocus.shouldClaim(
            isActiveTab: true, isHidden: false, hasWindow: false, isAlreadyFirstResponder: false))
    }

    func test_the_tab_that_already_has_it_does_not_ask_again() {
        XCTAssertFalse(TerminalFocus.shouldClaim(
            isActiveTab: true, isHidden: false, hasWindow: true, isAlreadyFirstResponder: true))
    }
}

/// 이 수정이 딛고 선 AppKit의 동작 두 가지. 문서로는 애매하고, 바뀌면 포커스
/// 버그가 조용히 돌아오는 종류라 실물 `NSWindow`에 직접 물어본다.
final class AppKitResponderAssumptionTests: XCTestCase {

    private final class Probe: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func windowWithTwoViews() -> (NSWindow, Probe, Probe) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        let a = Probe(), b = Probe()
        window.contentView?.addSubview(a)
        window.contentView?.addSubview(b)
        return (window, a, b)
    }

    /// 나가는 탭이 키를 삼키지 않는 이유이자, 증상이 "다른 탭에 찍힌다"가 아니라
    /// "아무 데도 안 간다"인 이유. 숨기는 순간 AppKit이 회수하고 창이 받는다.
    func test_hiding_the_first_responder_hands_it_back_to_the_window() {
        let (window, a, _) = windowWithTwoViews()
        XCTAssertTrue(window.makeFirstResponder(a))
        XCTAssertTrue(window.firstResponder === a)

        a.isHidden = true

        XCTAssertFalse(
            window.firstResponder === a,
            "AppKit이 숨겨진 뷰의 first responder를 더 이상 회수하지 않는다면, 나가는 탭이 키 입력을 삼키기 시작한다.")
    }

    /// `TerminalFocus.shouldClaim`이 `!isHidden`을 들고 있는 이유. AppKit은
    /// 막아주지 않는다 — 규칙이 막지 않으면 키보드가 보이지 않는 탭으로 간다.
    func test_appkit_will_happily_focus_a_hidden_view() {
        let (window, a, _) = windowWithTwoViews()
        a.isHidden = true

        XCTAssertTrue(
            window.makeFirstResponder(a),
            "AppKit이 숨겨진 뷰를 거절하기 시작했다면 `!isHidden` 조건은 이제 불필요하다.")
        XCTAssertTrue(window.firstResponder === a)
    }

    /// 표면이 창의 key 알림을 따로 듣는 이유. 다른 앱으로 가도 창은 first
    /// responder를 **놓지 않으므로** `resignFirstResponder`가 안 울리고,
    /// libghostty는 배경에서도 포커스를 가졌다고 믿어 display link를 계속 돌린다.
    func test_a_window_losing_key_keeps_its_first_responder() {
        let (window, a, _) = windowWithTwoViews()
        XCTAssertTrue(window.makeFirstResponder(a))

        window.resignKey()

        XCTAssertTrue(
            window.firstResponder === a,
            "AppKit이 key를 잃을 때 first responder를 회수한다면 key 알림 구독은 필요 없다.")
    }
}
