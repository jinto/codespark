import AppKit

enum KeyRouteDecision: Equatable {
    case forwardToKeyDown   // Ctrl+*, Cmd+V → handle in keyDown
    case letSystemHandle    // Shift+letter, regular keys → return false
    case delegateToSuper    // Cmd+Q etc. → super.performKeyEquivalent
}

/// V key keyCode — IME-independent (physical key position)
private let kVKeyCode: UInt16 = 9

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
