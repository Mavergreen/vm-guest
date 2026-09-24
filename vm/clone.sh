#!/usr/bin/env bash
# Create a disposable qcow2 overlay ("clone") backed by a golden image.
#
# The golden is never written to: QEMU opens it read-only as a backing
# file, and this script never touches it beyond reading, except under
# --verify. Experiments run against the overlay; when an experiment is
# done, the overlay is simply deleted and the golden is untouched.
#
# --verify is opt-in, not the default: hashing a 60 GB golden before every
# experiment would make the safe path the slow path, and people route
# around slow safe paths.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
vmavs_hint clone
# shellcheck source=../lib/golden.sh
. "$MQG_REPO_ROOT/lib/golden.sh"

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
export MQG_IMAGE_DIR
GOLDEN_DIR=${GOLDEN_DIR:-$MQG_IMAGE_DIR/golden}
export GOLDEN_DIR
WORK_DIR=${WORK_DIR:-$MQG_IMAGE_DIR/work}
export WORK_DIR

usage_text() {
    printf '%s\n' "usage: vm/clone.sh [--verify] <golden-name> [clone-name]"
}

usage() {
    die "$(usage_text)"
}

case ${1:-} in
    -h|--help) usage_text; exit 0 ;;
esac

verify=0
if [ "${1:-}" = "--verify" ]; then
    verify=1
    shift
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
fi

golden_name=$1
clone_name=${2:-${golden_name}-$(date -u +%Y%m%dT%H%M%SZ)}

src=$(golden_path "$golden_name")

if [ "$verify" -eq 1 ]; then
    golden_verify "$golden_name"
fi

dest="$WORK_DIR/$clone_name.qcow2"
[ ! -e "$dest" ] || die "clone $clone_name already exists at $dest"

mkdir -p "$WORK_DIR"
# See lib/golden.sh for why this must be set on the directory before any
# overlay is written, and why a filesystem that doesn't support it only
# gets a warning.
chattr +C "$WORK_DIR" 2>/dev/null \
    || warn "could not set +C (no-COW) on $WORK_DIR; overlays may fragment on this filesystem"

qemu-img create -f qcow2 -F qcow2 -b "$src" "$dest" >/dev/null \
    || die "cannot create clone $clone_name backed by $src"

log "clone $clone_name created, backed by $src"
printf '%s\n' "$dest"
