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
