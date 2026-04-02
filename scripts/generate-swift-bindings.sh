#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/apps/macos/StatefulTerminal/Bridge"
EXPECTED_UNIFFI_VERSION="0.31.0"

mkdir -p "$OUT_DIR"

if ! version_output="$(uniffi-bindgen --version 2>&1)"; then
  echo "error: failed to run 'uniffi-bindgen --version': $version_output" >&2
  exit 1
fi

if [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
  cli_version="${BASH_REMATCH[1]}"
else
  echo "error: could not parse uniffi-bindgen version from: $version_output" >&2
  exit 1
fi

if [[ "$cli_version" != "$EXPECTED_UNIFFI_VERSION" ]]; then
  echo "error: uniffi-bindgen version mismatch: expected $EXPECTED_UNIFFI_VERSION, found $cli_version" >&2
  exit 1
fi

uniffi-bindgen generate \
  "$ROOT_DIR/crates/workspace-ffi/src/api.udl" \
  --language swift \
  --out-dir "$OUT_DIR"
