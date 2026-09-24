#!/usr/bin/env bash
# Promote, list, verify, and locate golden disk images.
#
# A golden is read-only and checksummed. Nothing ever writes to one;
# experiments run on overlays created by vm/clone.sh. Promotion to a new
# golden is a deliberate act that, per the design, requires measurement and
# the user's approval -- this script only does the mechanical half.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
vmavs_hint golden
# shellcheck source=../lib/golden.sh
. "$MQG_REPO_ROOT/lib/golden.sh"

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
export MQG_IMAGE_DIR
GOLDEN_DIR=${GOLDEN_DIR:-$MQG_IMAGE_DIR/golden}
export GOLDEN_DIR

usage_text() {
    cat <<'EOF'
usage: vm/golden.sh promote <image> <name> <description>
       vm/golden.sh list
       vm/golden.sh verify <name>
       vm/golden.sh path <name>
EOF
}

usage() {
    die "$(usage_text)"
}

case ${1:-} in
    -h|--help) usage_text; exit 0 ;;
esac

[ $# -ge 1 ] || usage

cmd=$1
shift

case $cmd in
    promote)
        [ $# -eq 3 ] || usage
        golden_promote "$1" "$2" "$3"
        ;;
    list)
        [ $# -eq 0 ] || usage
        golden_list
        ;;
    verify)
        [ $# -eq 1 ] || usage
        golden_verify "$1"
        ;;
    path)
        [ $# -eq 1 ] || usage
        golden_path "$1"
        ;;
    *)
        usage
        ;;
esac
