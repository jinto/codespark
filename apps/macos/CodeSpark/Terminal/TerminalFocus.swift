import Foundation

/// When a terminal surface may take the keyboard.
///
/// 규칙을 뷰 밖에 두는 이유: 이 판단이 틀리면 증상이 "아무 키도 안 먹는다"인데,
/// 그건 앱을 띄워야만 보이고 그마저도 가끔만 보인다. 조건을 값으로 만들어 두면
/// 네 가지 경우를 앱 없이 고정할 수 있다.
enum TerminalFocus {

    /// 지금 이 표면이 first responder를 가져가야 하는가.
    ///
    /// 네 조건 중 둘은 실측으로 정해졌다(`SurfaceFocusRuleTests`가 AppKit에게
    /// 다시 물어본다):
    ///
    /// - `hasWindow`: 창이 없으면 `makeFirstResponder`를 부를 대상 자체가 없다.
    ///   새로 삽입된 NSViewRepresentable의 `updateNSView`는 **언제나** 창이
    ///   붙기 전에 돈다 — 그래서 그때의 한 번짜리 주장은 조용히 사라진다.
    /// - `!isHidden`: **숨겨진 뷰도 `makeFirstResponder`가 성공한다**(AppKit이
    ///   막지 않는다). 이 조건을 빼면 낡은 주장이 키보드를 보이지 않는 탭에
    ///   앉혀 놓고, 화면의 탭은 죽은 것처럼 보인다.
    static func shouldClaim(
        isActiveTab: Bool,
        isHidden: Bool,
        hasWindow: Bool,
        isAlreadyFirstResponder: Bool
    ) -> Bool {
        guard isActiveTab, !isHidden, hasWindow else { return false }
        return !isAlreadyFirstResponder
    }
}
