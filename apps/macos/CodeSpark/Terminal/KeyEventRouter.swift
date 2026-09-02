import AppKit

enum KeyRouteDecision: Equatable {
    case forwardToKeyDown   // Ctrl+*, Cmd+V → handle in keyDown
    case letSystemHandle    // Shift+letter, regular keys → return false
    case delegateToSuper    // Cmd+Q etc. → super.performKeyEquivalent
}

/// V key keyCode — IME-independent (physical key position)
private let kVKeyCode: UInt16 = 9

/// Return and keypad Enter, by physical key position.
private let kReturnKeyCodes: Set<UInt16> = [36, 76]

/// Whether Return should open the session chooser for the selected row.
///
/// A workspace with no tabs shows an empty window, and the only way in was
/// Cmd+T. Return is the obvious second key — but it is also the most spoken-for
/// key on the keyboard, so it acts only when nothing else can be listening: no
/// terminal to type into, no sheet with a default button, and a project to open
/// something for.
func sidebarReturnOpensSessionChooser(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    hasActiveSession: Bool,
    hasSheet: Bool,
    hasSelectedProject: Bool
) -> Bool {
    guard kReturnKeyCodes.contains(keyCode) else { return false }
    guard modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
    return !hasActiveSession && !hasSheet && hasSelectedProject
}

/// What a `flagsChanged` event means for the modifier key that fired it.
enum ModifierKeyAction: Equatable {
    case press
    case release
    /// Not a modifier we report (fn, or a stray non-modifier keycode).
    case ignore
}

/// Right-side modifier device bits, from IOKit's IOLLEvent.h — AppKit's
/// `.shift`/`.control`/… flags don't say *which* Shift is down, and with both
/// held, releasing one leaves the flag set. `NSEvent.modifierFlags` carries
/// these device bits in its raw value.
private let kRightShiftDeviceBit: UInt = 0x0004    // NX_DEVICERSHIFTKEYMASK
private let kRightControlDeviceBit: UInt = 0x2000  // NX_DEVICERCTLKEYMASK
private let kRightOptionDeviceBit: UInt = 0x0040   // NX_DEVICERALTKEYMASK
private let kRightCommandDeviceBit: UInt = 0x0010  // NX_DEVICERCMDKEYMASK

/// Whether the modifier key behind a `flagsChanged` went down or came up.
///
/// We used to send PRESS unconditionally. The legacy encoding swallows bare
/// modifiers, so nothing showed — until a TUI switched on the kitty keyboard
/// protocol (atuin's does), where every press *and* release becomes bytes.
/// Releasing Shift then arrived as a second press (`^[[57441u`, measured with
/// `printf '\e[>11u'; cat -v`), and the TUI saw a Shift that never came up.
/// Official Ghostty's judgment table, as a pure function
/// (`SurfaceView_AppKit.swift`, `flagsChanged`).
func modifierKeyAction(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ModifierKeyAction {
    let held: Bool
    switch keyCode {
    case 0x39: held = flags.contains(.capsLock)
    case 0x38: held = flags.contains(.shift)
    case 0x3C: held = flags.contains(.shift) && flags.rawValue & kRightShiftDeviceBit != 0
    case 0x3B: held = flags.contains(.control)
    case 0x3E: held = flags.contains(.control) && flags.rawValue & kRightControlDeviceBit != 0
    case 0x3A: held = flags.contains(.option)
    case 0x3D: held = flags.contains(.option) && flags.rawValue & kRightOptionDeviceBit != 0
    case 0x37: held = flags.contains(.command)
    case 0x36: held = flags.contains(.command) && flags.rawValue & kRightCommandDeviceBit != 0
    default: return .ignore
    }
    return held ? .press : .release
}

func routeKeyEquivalent(
    modifiers: NSEvent.ModifierFlags,
    hasMarkedText: Bool,
    charactersIgnoringModifiers: String?,
    keyCode: UInt16 = 0
) -> KeyRouteDecision {
    // Cmd+V paste must work regardless of IME state or marked text
    if modifiers.contains(.command), keyCode == kVKeyCode { return .forwardToKeyDown }
    if hasMarkedText { return .letSystemHandle }
    // Ctrl belongs to the shell, but only on its own — holding Cmd too makes it
    // an app shortcut, and forwarding those swallowed the menu's key equivalent
    // and printed the raw escape into the terminal instead.
    if modifiers.contains(.control), !modifiers.contains(.command) { return .forwardToKeyDown }
    if !modifiers.contains(.command) { return .letSystemHandle }
    return .delegateToSuper
}
