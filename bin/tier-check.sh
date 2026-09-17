#!/usr/bin/env bash
# Report which profiles reference the Tier 2 quarantine.
#
# During P1 and P2 this is expected to be non-empty: reference firmware is
# how we de-risk the first boot. P3's exit gate is that it becomes empty,
# at which point CI runs this with --strict.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/profile.sh
. "$MQG_REPO_ROOT/lib/profile.sh"

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
export MQG_IMAGE_DIR
PROFILE_DIR=${MQG_TIER_PROFILE_DIR:-$MQG_REPO_ROOT/vm/profiles}

strict=0
if [ "${1:-}" = "--strict" ]; then
    strict=1
fi

# Line-based, not `for name in $(profile_list)`: a profile name containing
# whitespace would otherwise be word-split into pieces that don't exist,
# silently skipping the real profile instead of checking it. This is the
# mechanism P3's exit gate relies on, so it should not have an easy blind
# spot.
names=()
while IFS= read -r name; do
    [ -n "$name" ] || continue
    names+=("$name")
done < <(profile_list)

if [ "${#names[@]}" -eq 0 ]; then
    warn "no profiles found in $PROFILE_DIR -- nothing was checked"
fi

dirty=0
for name in "${names[@]}"; do
    # Grepped against the EXPANDED profile (after %REPO%/%IMAGES%
    # substitution), matching the bare "vendor/reference/" substring rather
    # than requiring a leading '/' -- a profile that reaches the quarantine
    # through a relative path (no %REPO% token) would otherwise slip past a
    # leading-slash-anchored pattern. This is still a textual heuristic: it
    # will not catch a symlink that points into vendor/reference/ under a
    # different name, or a copy of a quarantined blob placed elsewhere, or
    # path text assembled so that the literal substring never appears
    # (e.g. "vendor/refere" + "nce" split across two profile lines is not
    # possible in this format, but a differently-spelled indirection would
    # still evade it). It is a reasonable gate for accidental references,
    # not a proof against deliberate evasion.
    if profile_expand "$name" 2>/dev/null | grep -q 'vendor/reference/'; then
        printf 'TIER2  %s\n' "$name"
        dirty=1
    fi
done

if [ "$dirty" -eq 0 ]; then
    log "no profile references vendor/reference/ -- Tier 2 clean"
    exit 0
fi

if [ "$strict" -eq 1 ]; then
    die "profiles above reference the Tier 2 quarantine; P3's exit gate is not met"
fi

log "the profiles above are Tier 2. Expected during P1 and P2; P3 must clear them."
exit 0
