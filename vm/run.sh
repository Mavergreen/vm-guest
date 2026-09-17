#!/usr/bin/env bash
# Expand a profile and run QEMU with it.
#
# Every invocation is appended to run.log. The lab notebook should not
# depend on anyone remembering to write things down.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/profile.sh
. "$MQG_REPO_ROOT/lib/profile.sh"

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
export MQG_IMAGE_DIR
MQG_VENDOR_DIR=${MQG_VENDOR_DIR:-$MQG_IMAGE_DIR/vendor-reference}
export MQG_VENDOR_DIR
PROFILE_DIR=${PROFILE_DIR:-$MQG_REPO_ROOT/vm/profiles}

if [ $# -lt 1 ]; then
    die "usage: vm/run.sh <profile> [extra qemu args...]

Available profiles:
$(PROFILE_DIR="$PROFILE_DIR" profile_list 2>/dev/null | sed 's/^/  /')"
fi

profile=$1
shift

# profile_expand's own `die` only terminates the process-substitution
# subshell below (its message still reaches our stderr, since the subshell
# inherits it unredirected) -- it does NOT stop this script under `set -e`.
# mapfile simply sees whatever partial (possibly empty) output the subshell
# produced before dying. That is why an unknown or all-comment profile is
# caught explicitly by the empty-array check just below, rather than by
# relying on profile_expand's exit status.
mapfile -t args < <(profile_expand "$profile")
if [ "${#args[@]}" -eq 0 ]; then
    die "profile $profile expanded to nothing"
fi

cmdline=$(printf '%q ' qemu-system-x86_64 "${args[@]}" "$@")
cmdline=${cmdline% }

if [ "${MQG_DRY_RUN:-0}" = "1" ]; then
    printf '%s\n' "$cmdline"
    exit 0
fi

run_log "profile=$profile $cmdline"
log "running profile $profile (${#args[@]} profile args, $# extra)"
exec qemu-system-x86_64 "${args[@]}" "$@"
