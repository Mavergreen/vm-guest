#!/usr/bin/env bash
# Run the whole test suite. shellcheck is optional: it is not installed on
# every host, and needing a package install to run tests is a bad trade.
# bats is mandatory: it is how this script runs the suite at all.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

status=0

echo "== bats =="
if ! command -v bats >/dev/null 2>&1; then
    echo "bats not found. Install bats-core (e.g. 'sudo apt install bats'," \
        "or see https://github.com/bats-core/bats-core) and re-run." >&2
    status=1
elif ! bats tests/; then
    status=1
fi

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    # Collect scripts by walking the tree rather than a hardcoded glob list,
    # so new script directories are picked up automatically and the check
    # still runs on files that exist but aren't `git add`ed yet. Prune the
    # disk-image work areas: they hold generated content, not our shell
    # code. The Tier 2 quarantine no longer lives under the repo at all
    # (see docs/decisions/0003-vm-images-on-local-btrfs.md), so there is
    # nothing left to prune for it.
    mapfile -t sh_files < <(
        find . \( -path ./.git -o -path ./work \
                  -o -path ./golden \) -prune -o -name '*.sh' -print
    )
    # SC1091: shellcheck cannot follow dynamically-computed source paths.
    if [ "${#sh_files[@]}" -gt 0 ]; then
        if ! shellcheck -e SC1091 "${sh_files[@]}"; then
            status=1
        fi
    fi
else
    echo "shellcheck not installed; skipping."
    echo "Install it to lint shell scripts locally: sudo apt install shellcheck"
fi

echo
echo "== tier-check =="
# P3's exit gate, run as a test rather than by hand. No profile in
# vm/profiles/ may reference the Tier 2 quarantine: the boot path has to be
# rebuildable from pinned source. Retired profiles that do reference it live
# in vm/profiles/attic/, outside PROFILE_DIR -- see that directory's README,
# and docs/decisions/0004-p3-boot-stack-provenance.md.
#
# Unlike shellcheck this is not optional. It needs nothing installed, and a
# rule that is only checked when a tool happens to be present is a rule that
# will be broken on the host that does not have it.
if ! "$repo_root/bin/tier-check.sh" --strict; then
    status=1
fi

exit "$status"
