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
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
export MQG_BUILD_DIR
MQG_VENDOR_DIR=${MQG_VENDOR_DIR:-$MQG_IMAGE_DIR/vendor-reference}
export MQG_VENDOR_DIR
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
expanded=""
for name in "${names[@]}"; do
    # Grepped against the EXPANDED profile (after %REPO%/%IMAGES%/%VENDOR%
    # substitution), matching the resolved $MQG_VENDOR_DIR path rather than
    # a textual convention like "vendor/reference/". This is stronger than
    # matching a substring: it catches any route into the quarantine
    # directory that actually configures, not just one particular spelling
    # of it. It is still a textual heuristic: it will not catch a symlink
    # that points into $MQG_VENDOR_DIR under a different name, or a copy of
    # a quarantined blob placed elsewhere, or path text assembled so that
    # the literal path never appears in one piece. It is a reasonable gate
    # for accidental references, not a proof against deliberate evasion.
    # No pipe into `grep -q` here, deliberately. `grep -q` exits the moment
    # it matches, which SIGPIPEs the still-writing profile_expand; under
    # `set -o pipefail` the pipeline then reports 141 and the `if` takes the
    # FALSE branch *because* the match succeeded. That made this gate fail
    # open exactly when it found a violation, and only for profiles long
    # enough that the writer had not already finished -- so short test
    # profiles passed while a real 45-line one did not. Match in-process
    # instead: no pipe, no signal, no exit-status subtlety.
    expanded=$(profile_expand "$name")
    if [ "${expanded#*"$MQG_VENDOR_DIR/"}" != "$expanded" ]; then
        printf 'TIER2  %s\n' "$name"
        dirty=1
    fi
done

if [ "$dirty" -eq 0 ]; then
    log "no profile references $MQG_VENDOR_DIR -- Tier 2 clean"
    exit 0
fi

if [ "$strict" -eq 1 ]; then
    die "profiles above reference the Tier 2 quarantine; P3's exit gate is not met"
fi

log "the profiles above are Tier 2. Expected during P1 and P2; P3 must clear them."
exit 0
