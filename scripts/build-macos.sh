#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR/apps/macos"
xcodegen generate --spec project.yml

cd "$ROOT_DIR"
xcodebuild build \
  -project apps/macos/StatefulTerminal.xcodeproj \
  -scheme StatefulTerminal \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/StatefulTerminalDerivedData \
  COMPILER_INDEX_STORE_ENABLE=NO
