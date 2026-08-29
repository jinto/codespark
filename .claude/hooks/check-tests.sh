#!/bin/bash
# Stop hook: enforce test writing for source changes
# Checks git diff for modified source files without corresponding test changes.

# `git diff` alone sees only UNSTAGED changes, so everything already `git add`-ed
# was invisible — precisely at the moment someone is about to commit.
changed=$(git diff HEAD --name-only 2>/dev/null)
[ -z "$changed" ] && exit 0

src_changed=$(echo "$changed" | grep -E 'CodeSpark/(Views|Terminal|Models|Services|App|Bridge)/' | grep -v 'Tests' || true)
test_changed=$(echo "$changed" | grep 'CodeSparkTests/' || true)

if [ -n "$src_changed" ] && [ -z "$test_changed" ]; then
    echo "[BLOCKED] Source files modified without tests:"
    echo "$src_changed" | sed 's/^/  /'
    echo ""
    echo "You MUST write and run tests for these changes before proceeding."
    echo "Do NOT ask user to verify manually. Do NOT commit without tests."
    # A Stop hook blocks on exit 2 and only on exit 2. Printing "[BLOCKED]" and
    # then falling off the end of the script exits 0, which is what this hook
    # did for its whole life: it has never once blocked anything.
    exit 2
fi

exit 0
