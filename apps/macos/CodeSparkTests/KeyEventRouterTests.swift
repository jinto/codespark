import XCTest
@testable import CodeSpark

final class KeyEventRouterTests: XCTestCase {

    // Issue 1: Shift+letter must flow to keyDown normally
    func test_shift_only_returns_letSystemHandle() {
        let decision = routeKeyEquivalent(modifiers: [.shift], hasMarkedText: false, charactersIgnoringModifiers: "a")
        XCTAssertEqual(decision, .letSystemHandle)
    }

    func test_no_modifiers_returns_letSystemHandle() {
        let decision = routeKeyEquivalent(modifiers: [], hasMarkedText: false, charactersIgnoringModifiers: "a")
        XCTAssertEqual(decision, .letSystemHandle)
    }

    // Issue 3: Cmd+V must be intercepted (keyCode 9 = V key)
    func test_cmd_v_returns_forwardToKeyDown() {
        let decision = routeKeyEquivalent(modifiers: [.command], hasMarkedText: false, charactersIgnoringModifiers: "v", keyCode: 9)
        XCTAssertEqual(decision, .forwardToKeyDown)
    }

    // Ctrl+key must be forwarded
    func test_control_key_returns_forwardToKeyDown() {
        let decision = routeKeyEquivalent(modifiers: [.control], hasMarkedText: false, charactersIgnoringModifiers: "c")
        XCTAssertEqual(decision, .forwardToKeyDown)
    }

    // Cmd+Q etc → system handles
    func test_cmd_other_returns_delegateToSuper() {
        let decision = routeKeyEquivalent(modifiers: [.command], hasMarkedText: false, charactersIgnoringModifiers: "q")
        XCTAssertEqual(decision, .delegateToSuper)
    }

    // Marked text → bypass
    func test_marked_text_returns_letSystemHandle() {
        let decision = routeKeyEquivalent(modifiers: [.control], hasMarkedText: true, charactersIgnoringModifiers: "a")
        XCTAssertEqual(decision, .letSystemHandle)
    }

    // Korean IME: Cmd+V sends "ㅍ" not "v" — must use keyCode 9 instead
    func test_cmd_v_korean_ime_returns_forwardToKeyDown() {
        let decision = routeKeyEquivalent(modifiers: [.command], hasMarkedText: false, charactersIgnoringModifiers: "ㅍ", keyCode: 9)
        XCTAssertEqual(decision, .forwardToKeyDown)
    }

    // Korean IME: Cmd+V with marked text (조합 중) should still paste
    func test_cmd_v_korean_ime_with_marked_text_returns_forwardToKeyDown() {
        let decision = routeKeyEquivalent(modifiers: [.command], hasMarkedText: true, charactersIgnoringModifiers: "ㅍ", keyCode: 9)
        XCTAssertEqual(decision, .forwardToKeyDown)
    }

    // Shift+Cmd → system handles
    func test_shift_cmd_returns_delegateToSuper() {
        let decision = routeKeyEquivalent(modifiers: [.shift, .command], hasMarkedText: false, charactersIgnoringModifiers: "a")
        XCTAssertEqual(decision, .delegateToSuper)
    }

    // Ctrl belongs to the terminal only when Cmd is not held. Cmd+Ctrl+S is the
    // sidebar toggle: routing it to keyDown swallowed the shortcut and printed
    // the raw escape (`15;5u`) into the terminal instead.
    func test_cmd_control_returns_delegateToSuper() {
        let decision = routeKeyEquivalent(modifiers: [.command, .control], hasMarkedText: false, charactersIgnoringModifiers: "s")
        XCTAssertEqual(decision, .delegateToSuper)
    }

    func test_cmd_control_shift_returns_delegateToSuper() {
        let decision = routeKeyEquivalent(modifiers: [.command, .control, .shift], hasMarkedText: false, charactersIgnoringModifiers: "s")
        XCTAssertEqual(decision, .delegateToSuper)
    }

    // …but a bare Ctrl chord still has to reach the shell.
    func test_control_c_still_returns_forwardToKeyDown() {
        let decision = routeKeyEquivalent(modifiers: [.control], hasMarkedText: false, charactersIgnoringModifiers: "c")
        XCTAssertEqual(decision, .forwardToKeyDown)
    }

    func test_control_shift_still_returns_forwardToKeyDown() {
        let decision = routeKeyEquivalent(modifiers: [.control, .shift], hasMarkedText: false, charactersIgnoringModifiers: "a")
        XCTAssertEqual(decision, .forwardToKeyDown)
    }
}
