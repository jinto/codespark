import XCTest
@testable import CodeSpark

/// Return over the sidebar opens the session chooser — but only when no other
/// part of the app could want the key. A pure decision so every case that must
/// let Return through is checkable without a running window.
final class SidebarReturnKeyTests: XCTestCase {
    private let returnKey: UInt16 = 36
    private let keypadEnter: UInt16 = 76

    private func opens(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        hasActiveSession: Bool = false,
        hasSheet: Bool = false,
        hasSelectedProject: Bool = true
    ) -> Bool {
        sidebarReturnOpensSessionChooser(
            keyCode: keyCode,
            modifiers: modifiers,
            hasActiveSession: hasActiveSession,
            hasSheet: hasSheet,
            hasSelectedProject: hasSelectedProject
        )
    }

    func test_return_on_an_empty_workspace_opens_the_chooser() {
        XCTAssertTrue(opens(keyCode: returnKey))
        XCTAssertTrue(opens(keyCode: keypadEnter))
    }

    func test_a_terminal_keeps_its_return_key() {
        XCTAssertFalse(opens(keyCode: returnKey, hasActiveSession: true),
                       "stealing Return from a shell would break typing entirely")
    }

    func test_a_sheet_keeps_its_return_key() {
        XCTAssertFalse(opens(keyCode: returnKey, hasSheet: true),
                       "Return belongs to the sheet's default button")
    }

    func test_modified_returns_are_left_alone() {
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            XCTAssertFalse(opens(keyCode: returnKey, modifiers: modifier))
        }
    }

    func test_other_keys_do_nothing() {
        XCTAssertFalse(opens(keyCode: 0))
    }

    func test_nothing_to_open_without_a_project() {
        XCTAssertFalse(opens(keyCode: returnKey, hasSelectedProject: false))
    }
}

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

    // MARK: - Declared app shortcuts must survive the router

    /// The gap that let `Cmd+Ctrl+S` ship broken: its action worked and its menu
    /// item existed, so every test passed — but the router handed the chord to
    /// the terminal and the menu item never fired. Testing the action alone
    /// cannot see that. This asserts the chord itself reaches the menu.
    func test_every_app_shortcut_reaches_the_menu() {
        for shortcut in AppShortcut.allCases {
            XCTAssertEqual(
                routeKeyEquivalent(
                    modifiers: shortcut.flags,
                    hasMarkedText: false,
                    charactersIgnoringModifiers: String(shortcut.key.character)
                ),
                .delegateToSuper,
                "\(shortcut.rawValue) never reaches the menu — the terminal swallows it"
            )
        }
    }

    func test_app_shortcuts_do_not_collide() {
        var seen: [String: String] = [:]
        for shortcut in AppShortcut.allCases {
            let chord = "\(shortcut.flags.rawValue)+\(shortcut.key.character)"
            if let existing = seen[chord] {
                XCTFail("\(shortcut.rawValue) uses the same chord as \(existing)")
            }
            seen[chord] = shortcut.rawValue
        }
    }

    /// Cmd+1…9 share one table entry, so cover the whole digit range here.
    func test_project_index_shortcuts_reach_the_menu_for_every_digit() {
        for digit in 1...9 {
            XCTAssertEqual(
                routeKeyEquivalent(
                    modifiers: AppShortcut.selectWorkspaceByIndex.flags,
                    hasMarkedText: false,
                    charactersIgnoringModifiers: "\(digit)"
                ),
                .delegateToSuper
            )
        }
    }
}

/// A modifier key's flagsChanged must say whether it went down or came up.
///
/// We always sent PRESS. Under the legacy encoding that mistake is silent —
/// bare modifiers never become bytes — but the kitty keyboard protocol, which
/// atuin's TUI switches on, reports every press *and* release. Measured with
/// `printf '\e[>11u'; cat -v`: releasing Shift printed `^[[57441u` (a second
/// press) where official Ghostty prints `^[[57441;1:3u` (a release) — so any
/// TUI tracking modifiers saw a Shift that never came back up.
final class ModifierKeyActionTests: XCTestCase {
    func test_pressing_a_modifier_is_a_press() {
        XCTAssertEqual(modifierKeyAction(keyCode: 0x38, flags: [.shift]), .press)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3B, flags: [.control]), .press)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3A, flags: [.option]), .press)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x37, flags: [.command]), .press)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x39, flags: [.capsLock]), .press)
    }

    func test_releasing_a_modifier_is_a_release() {
        XCTAssertEqual(modifierKeyAction(keyCode: 0x38, flags: []), .release)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3B, flags: []), .release)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3A, flags: []), .release)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x37, flags: []), .release)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x39, flags: []), .release)
    }

    /// Two Shifts held, right one released: the flag bit is still set, so the
    /// side has to decide — the event's device bits say which side is down.
    func test_releasing_one_side_while_the_other_is_held_is_a_release() {
        let leftShiftStillDown = NSEvent.ModifierFlags(rawValue:
            NSEvent.ModifierFlags.shift.rawValue | 0x0002) // NX_DEVICELSHIFTKEYMASK
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3C, flags: leftShiftStillDown), .release,
                       "the right Shift came up even though shift is still held")

        let rightShiftDown = NSEvent.ModifierFlags(rawValue:
            NSEvent.ModifierFlags.shift.rawValue | 0x0004) // NX_DEVICERSHIFTKEYMASK
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3C, flags: rightShiftDown), .press)
    }

    func test_right_side_modifiers_check_their_own_device_bit() {
        // control: right device bit 0x2000
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3E, flags: NSEvent.ModifierFlags(rawValue:
            NSEvent.ModifierFlags.control.rawValue | 0x2000)), .press)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3E, flags: [.control]), .release)
        // option: right device bit 0x40
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3D, flags: NSEvent.ModifierFlags(rawValue:
            NSEvent.ModifierFlags.option.rawValue | 0x40)), .press)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3D, flags: [.option]), .release)
        // command: right device bit 0x10
        XCTAssertEqual(modifierKeyAction(keyCode: 0x36, flags: NSEvent.ModifierFlags(rawValue:
            NSEvent.ModifierFlags.command.rawValue | 0x10)), .press)
        XCTAssertEqual(modifierKeyAction(keyCode: 0x36, flags: [.command]), .release)
    }

    /// fn, ordinary keys, anything we don't track: not ours to report.
    func test_keys_that_are_not_modifiers_are_ignored() {
        XCTAssertEqual(modifierKeyAction(keyCode: 0x3F, flags: [.function]), .ignore)
        XCTAssertEqual(modifierKeyAction(keyCode: 9, flags: []), .ignore)
    }
}
