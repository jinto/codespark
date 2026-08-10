import AppKit
import SwiftUI

/// Every app-level key equivalent, in one table.
///
/// The terminal sees key events before the menu does, so a chord that
/// `KeyEventRouter` forwards to `keyDown` never fires its menu item — it just
/// prints a raw escape into the shell. That failure is invisible to a test of
/// the action itself, which is how `Cmd+Ctrl+S` sat broken. Declaring the
/// chords here lets `AppShortcut` be asserted against the router at build time.
///
/// Sheet-local `.defaultAction` / `.cancelAction` are not app shortcuts and
/// stay out — they are scoped to a presented sheet, not the menu bar.
enum AppShortcut: String, CaseIterable {
    case newProject
    case newSSHProject
    case newSession
    case closeSessionOrProject
    case toggleSidebar
    case nextTab
    case previousTab
    case nextWorktree
    case previousWorktree
    /// Cmd+1…9 pick a project. The digit varies, the chord does not, so one
    /// entry stands for all nine.
    case selectProjectByIndex

    var key: KeyEquivalent {
        switch self {
        case .newProject, .newSSHProject: "n"
        case .newSession: "t"
        case .closeSessionOrProject: "w"
        case .toggleSidebar: "s"
        case .nextTab, .nextWorktree: "]"
        case .previousTab, .previousWorktree: "["
        case .selectProjectByIndex: "1"
        }
    }

    /// AppKit flags are the source of truth because the router speaks AppKit.
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .newProject, .newSession, .closeSessionOrProject, .selectProjectByIndex:
            [.command]
        case .newSSHProject, .nextTab, .previousTab:
            [.command, .shift]
        case .toggleSidebar:
            [.command, .control]
        case .nextWorktree, .previousWorktree:
            [.command, .option]
        }
    }

    var modifiers: EventModifiers {
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

extension View {
    /// Applies a declared shortcut. Prefer this over a literal `keyboardShortcut`
    /// for menu commands so the chord stays covered by `AppShortcut` tests.
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}
