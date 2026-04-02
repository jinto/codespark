#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/apps/macos/StatefulTerminal/Bridge"

mkdir -p "$OUT_DIR"

uniffi-bindgen generate \
  "$ROOT_DIR/crates/workspace-ffi/src/api.udl" \
  --language swift \
  --out-dir "$OUT_DIR"
