import AppKit

enum KeyRouteDecision: Equatable {
    case forwardToKeyDown   // Ctrl+*, Cmd+V → handle in keyDown
    case letSystemHandle    // Shift+letter, regular keys → return false
    case delegateToSuper    // Cmd+Q etc. → super.performKeyEquivalent
}

func routeKeyEquivalent(
    modifiers: NSEvent.ModifierFlags,
    hasMarkedText: Bool,
    charactersIgnoringModifiers: String?
) -> KeyRouteDecision {
    if hasMarkedText { return .letSystemHandle }
    if modifiers.contains(.control) { return .forwardToKeyDown }
    if modifiers.contains(.command), charactersIgnoringModifiers == "v" { return .forwardToKeyDown }
    if !modifiers.contains(.command) { return .letSystemHandle }
    return .delegateToSuper
}
