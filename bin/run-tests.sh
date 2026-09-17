#!/usr/bin/env bash
# Run the whole test suite. shellcheck is optional: it is not installed on
# every host, and needing a package install to run tests is a bad trade.
set -euo pipefail
# Globs below (lib/*.sh etc.) may not match anything yet; without nullglob
# an unmatched glob is passed to shellcheck as a literal, nonexistent
# filename and it exits nonzero.
shopt -s nullglob

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

status=0

echo "== bats =="
if ! bats tests/; then
    status=1
fi

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    # SC1091: shellcheck cannot follow dynamically-computed source paths.
    if ! shellcheck -e SC1091 \
        lib/*.sh bin/*.sh vm/*.sh boot/*.sh media/*.sh 2>/dev/null; then
        status=1
    fi
else
    echo "shellcheck not installed; skipping."
    echo "To enable: sudo apt install shellcheck  (requires an ask)"
fi

exit "$status"
