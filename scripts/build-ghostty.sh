#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$ROOT_DIR/vendor/ghostty"
XCFRAMEWORK_OUT="$GHOSTTY_DIR/zig-out/macos/GhosttyKit.xcframework"

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "error: Ghostty source not found at $GHOSTTY_DIR" >&2
    echo "Run: git clone --depth 1 https://github.com/ghostty-org/ghostty.git $GHOSTTY_DIR" >&2
    exit 1
fi

if ! command -v zig &>/dev/null; then
    echo "error: zig not found. Install with: brew install zig" >&2
    exit 1
fi

echo "Building Ghostty xcframework..."
cd "$GHOSTTY_DIR"
zig build -Demit-xcframework

if [ -d "$XCFRAMEWORK_OUT" ]; then
    echo "Build succeeded: $XCFRAMEWORK_OUT"
else
    echo "error: xcframework not found at expected path" >&2
    echo "Checking zig-out for artifacts..." >&2
    find zig-out -name "*.xcframework" -o -name "*.a" -o -name "*.dylib" 2>/dev/null | head -10
    exit 1
fi
