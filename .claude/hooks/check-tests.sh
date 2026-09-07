#!/bin/bash
# Stop hook: enforce test writing for source changes
# Checks git diff for modified source files without corresponding test changes.

# A Stop hook that keeps firing after the agent has already answered it will
# loop the turn. The harness says so in the payload — honour it, and let the
# second pass through end the turn.
if grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$(cat)"; then
    exit 0
fi

# `git diff` alone sees only UNSTAGED changes, so everything already `git add`-ed
# was invisible — precisely at the moment someone is about to commit.
#
# And `git diff HEAD` sees only files git already knows about. A brand-new test
# file is untracked until it is added, so the one case this hook exists for —
# "I wrote the test for this change" — was the case it could not see. It blocked
# a turn that had its tests sitting right there on disk, nine times in a row.
changed=$(
    {
        git diff HEAD --name-only 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u
)
[ -z "$changed" ] && exit 0

src_changed=$(echo "$changed" | grep -E 'CodeSpark/(Views|Terminal|Models|Services|App|Bridge)/' | grep -v 'Tests' || true)
test_changed=$(echo "$changed" | grep 'CodeSparkTests/' || true)

if [ -n "$src_changed" ] && [ -z "$test_changed" ]; then
    # To stderr, not stdout: a blocked Stop hook shows the agent its *stderr*.
    # Printed to stdout, this whole explanation was swallowed and the agent was
    # told only that it had been blocked, with no reason — which is how a
    # blocking hook turns into a silent loop.
    {
        echo "[BLOCKED] Source files modified without tests:"
        echo "$src_changed" | sed 's/^/  /'
        echo ""
        echo "You MUST write and run tests for these changes before proceeding."
        echo "Do NOT ask user to verify manually. Do NOT commit without tests."
    } >&2
    # A Stop hook blocks on exit 2 and only on exit 2. Printing "[BLOCKED]" and
    # then falling off the end of the script exits 0, which is what this hook
    # did for its whole life: it has never once blocked anything.
    exit 2
fi

exit 0
