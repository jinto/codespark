#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$ROOT_DIR/vendor/ghostty"
# Where the Xcode phase and release.yml both look for it.
XCFRAMEWORK_OUT="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "error: Ghostty source not found at $GHOSTTY_DIR" >&2
    echo "Fetch the pinned commit:" >&2
    echo "  git init $GHOSTTY_DIR && git -C $GHOSTTY_DIR remote add origin https://github.com/ghostty-org/ghostty.git" >&2
    echo "  git -C $GHOSTTY_DIR fetch --depth 1 origin \"\$(cat $ROOT_DIR/.ghostty-version)\" && git -C $GHOSTTY_DIR checkout FETCH_HEAD" >&2
    exit 1
fi

if ! command -v zig &>/dev/null; then
    echo "error: zig not found. Install with: brew install zig" >&2
    exit 1
fi

echo "Building Ghostty xcframework..."
cd "$GHOSTTY_DIR"
# ReleaseFast is not optional: a debug GhosttyKit ships a ~100x slower
# allocator, which reads as the app being broken rather than slow.
zig build -Doptimize=ReleaseFast -Demit-xcframework=true

if [ -d "$XCFRAMEWORK_OUT" ]; then
    echo "Build succeeded: $XCFRAMEWORK_OUT"
else
    echo "error: xcframework not found at expected path" >&2
    echo "Checking zig-out for artifacts..." >&2
    find zig-out -name "*.xcframework" -o -name "*.a" -o -name "*.dylib" 2>/dev/null | head -10
    exit 1
fi
