# CodeSpark

A native macOS terminal multiplexer powered by [Ghostty](https://ghostty.org).

Project-based workspaces. Persistent sessions. Keyboard-driven.

## Features

- **Ghostty-powered terminal** — GPU-accelerated rendering via GhosttyKit
- **Project workspaces** — organize sessions by project with sidebar navigation
- **Session persistence** — sessions survive app restarts and crashes
- **SSH remotes** — first-class SSH session support with image paste over scp
- **Claude Code hooks** — real-time integration with Claude Code via Unix socket
- **Keyboard-driven** — Cmd+T new tab, Cmd+W close, Cmd+Shift+[ ] switch, Cmd+N new project

## Architecture

```
apps/macos/     Swift + SwiftUI + AppKit
vendor/ghostty/  GhosttyKit terminal engine
libs/workspace-core/  Zig + SQLite persistence
```

## Build

Requires Xcode and [Zig](https://ziglang.org).

```bash
# 1. Build GhosttyKit
cd vendor/ghostty
zig build -Doptimize=ReleaseFast -Demit-xcframework=true

# 2. Build CodeSpark
xcodebuild -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark \
  -configuration Release -derivedDataPath /tmp/CodeSparkDerivedData \
  -destination 'platform=macOS' build
```

## Inspired by

- [cmux](https://github.com/manaflow-ai/cmux) — Ghostty-based native macOS terminal with agent-centric design
- [Superset](https://github.com/superset-sh/superset) — parallel coding agent orchestrator with worktree isolation

## License

[BSL 1.1](LICENSE) — free for non-commercial use. Commercial use requires a separate license.
Converts to MIT on 2030-04-09.

GhosttyKit is used under the [MIT License](https://github.com/ghostty-org/ghostty/blob/main/LICENSE).
