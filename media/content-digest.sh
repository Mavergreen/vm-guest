#!/usr/bin/env bash
# What is ON the installer media, as one checksum.
#
# WHY THE MEDIA'S OWN CHECKSUM IS NOT THAT
#
# Two media builds from the same InstallESD.dmg produce files with different
# SHA-256s, and always will:
#
#   * mkfs.hfsplus stamps the volume's creation date from the clock;
#   * mounting an HFS+ volume rewrites its header (the media build's own
#     .sha256 file says so, with an expiry note attached);
#   * catalog and allocation layout depend on the order things were written.
#
# None of that is content. So the media's file checksum answers "is this the
# exact artifact I built", which is worth recording, and cannot answer "do
# two builds contain the same thing", which is what reproducibility means
# here. This script answers the second question:
#
#   sha256 of a sorted list of "<sha256>  <size>  <path>", one per file.
#
# Deliberately not including mtimes, ownership or modes: rsync carries the
# first, the privops microVM sets the second and third uniformly, and none
# of them is what an installer reads.
#
# Takes about a minute on this host for 6.4 GB and 52,000 files.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/hfs.sh
. "$MQG_REPO_ROOT/lib/hfs.sh"

# Read at call time by log()/warn()/die() in lib/common.sh.
# shellcheck disable=SC2034
MQG_LOG_PREFIX=content-digest

usage() {
    cat <<EOF
usage: $(basename "$0") [--list] <image>

  --list   Print the per-file lines instead of just the digest, so two
           builds can be diffed rather than merely compared.

Prints "<sha256>  <n> files  <bytes> bytes".
EOF
}

list=0
while [ $# -gt 0 ]; do
    case $1 in
        --list) list=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) break ;;
    esac
    shift
done
[ $# -eq 1 ] || { usage >&2; exit 2; }
img=$1
[ -f "$img" ] || die "no such image: $img"
require_cmd sha256sum find sort

digest_body() {
    local mnt=$1 tmp
    tmp=$(mktemp) || die "cannot create a temporary file"
    # Sorted by path, under LC_ALL=C, so the order is a property of the
    # content and not of anyone's locale.
    ( cd "$mnt" && find . -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum ) > "$tmp" 2>/dev/null \
        || die "could not checksum the contents of $img"
    if [ "$list" -eq 1 ]; then
        cat "$tmp"
    fi
    printf '%s  %s files  %s bytes\n' \
        "$(sha256sum < "$tmp" | cut -d' ' -f1)" \
        "$(grep -c . "$tmp")" \
        "$(cd "$mnt" && find . -type f -printf '%s\n' | paste -sd+ | bc)"
    rm -f "$tmp"
}

hfs_with_mounted_part "$img" 1 digest_body
