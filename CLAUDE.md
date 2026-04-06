# CodeSpark

macOS terminal multiplexer powered by [Ghostty](https://ghostty.org) engine.

## Build

```bash
# 1. Build GhosttyKit (ReleaseFast required — debug build has 100x slower allocator)
cd vendor/ghostty
zig build -Doptimize=ReleaseFast -Demit-xcframework=true

# 2. Build CodeSpark
xcodebuild -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark \
  -configuration Release -derivedDataPath /tmp/CodeSparkDerivedData \
  -destination 'platform=macOS' build
```

## Ghostty Integration

Reference implementation: `vendor/ghostty/macos/Sources/Ghostty/`

When modifying terminal code, always check the official Ghostty source first:
- **Key input**: `NSEvent+Extension.swift` (`ghosttyCharacters`, `ghosttyKeyEvent`)
- **Surface sizing**: `SurfaceView_AppKit.swift` (`sizeDidChange`, `convertToBacking`)
- **Wakeup/tick**: `Ghostty.App.swift` (`wakeup`, `appTick`)
- **Scroll view**: `SurfaceScrollView.swift` (layout, synchronization)

Key patterns:
- `ghostty_surface_set_size` expects **physical pixels** (use `convertToBacking`)
- Control characters (< 0x20) must be sent as original char + Ctrl modifier, not raw control code
- Ghostty manages its own Metal layer — do NOT set `wantsLayer = true`

## Architecture

```
apps/macos/CodeSpark/
  App/          — CodeSparkApp entry point, AppDelegate, window
  Models/       — AppModel (state), view data types
  Views/        — SwiftUI views (Sidebar, MainContent, Settings, Onboarding)
  Terminal/     — Ghostty integration (Runtime, SurfaceView, Host, Protocol)
  Bridge/       — workspace-core C FFI bridge
  Services/     — GitBranchService, TerminalFontSettings, HookSocketServer, ClaudeHooksManager
  Theme/        — AppTheme colors
apps/macos/CLI/ — codespark-hook CLI (Claude Code hook → Unix socket bridge)
```

## Known Issues

- `AppModel.swift` is 660+ lines with 5+ responsibilities — needs splitting
- Terminal hosts (NoOpTerminalHost) are disconnected from real Ghostty surfaces
- Sidebar state can go stale after session mutations (reads `workspaces.liveSessionDetails` instead of `liveSessions`)
