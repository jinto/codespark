#!/bin/bash
# Stop hook: enforce test writing for source changes
# Checks git diff for modified source files without corresponding test changes.

changed=$(git diff --name-only 2>/dev/null)
[ -z "$changed" ] && exit 0

src_changed=$(echo "$changed" | grep -E 'CodeSpark/(Views|Terminal|Models|Services|App|Bridge)/' | grep -v 'Tests' || true)
test_changed=$(echo "$changed" | grep 'CodeSparkTests/' || true)

if [ -n "$src_changed" ] && [ -z "$test_changed" ]; then
    echo "[BLOCKED] Source files modified without tests:"
    echo "$src_changed" | sed 's/^/  /'
    echo ""
    echo "You MUST write and run tests for these changes before proceeding."
    echo "Do NOT ask user to verify manually. Do NOT commit without tests."
fi
