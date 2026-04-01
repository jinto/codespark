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
    if modifiers.contains(.control) { return .forwardToKeyDown }
    if !modifiers.contains(.command) { return .letSystemHandle }
    return .delegateToSuper
}
