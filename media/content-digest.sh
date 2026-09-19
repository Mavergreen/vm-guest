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
    local mnt=$1 tmp n=0 unreadable=0 bytes=0
    tmp=$(mktemp) || die "cannot create a temporary file"
    # Sorted by path, under LC_ALL=C, so the order is a property of the
    # content and not of anyone's locale.
    #
    # Unreadable files are listed rather than skipped or fatal. BaseSystem
    # ships /.file at mode 0000 -- the marker OS X looks for to decide a
    # volume has a filesystem on it -- and /.Trashes is not ours either.
    # A digest that silently omitted them would be a digest of a different
    # thing depending on who ran it; one that died on them would never run
    # at all. So they appear by name and size, with no checksum, which is
    # exactly as much as can honestly be said about them.
    # In bulk, not one sha256sum per file: 39,000 processes took five
    # minutes and one xargs takes twenty seconds. Sorted afterwards, by
    # path, so the order is still a property of the content.
    #
    # Three directories are skipped, all of them written BY a volume rather
    # than being content OF it: a Spotlight store, an FSEvents log and a
    # trash. macOS creates .Spotlight-V100 on the installer media the first
    # time a guest boots it, with a fresh UUID in the directory name, which
    # made two media built from one ESD produce different digests while
    # every one of their 39,414 real files matched. The media is now
    # attached snapshot=on so the guest cannot write to it at all; this
    # stays because media built before that change still carry the
    # directory, and because a digest of "what is on the media" should not
    # include what booting it left behind.
    (
        cd "$mnt" || die "cannot enter $mnt"
        find . \( -name .Spotlight-V100 -o -name .fseventsd \
                  -o -name .Trashes \) -prune -o \
             -type f -readable -print0 2>/dev/null \
            | xargs -0 -r sha256sum 2>/dev/null
        find . \( -name .Spotlight-V100 -o -name .fseventsd \
                  -o -name .Trashes \) -prune -o \
             -type f ! -readable -printf 'UNREADABLE-%s  %p\n' 2>/dev/null
    ) | LC_ALL=C sort -k2 > "$tmp"
    n=$(grep -c . "$tmp")
    unreadable=$(grep -c '^UNREADABLE-' "$tmp" || true)
    bytes=$( cd "$mnt" && find . \( -name .Spotlight-V100 -o -name .fseventsd \
                                    -o -name .Trashes \) -prune -o \
                            -type f -printf '%s\n' 2>/dev/null \
        | awk '{ total += $1 } END { print total + 0 }' )
    if [ "$list" -eq 1 ]; then
        cat "$tmp"
    fi
    printf '%s  %s files  %s bytes  %s unreadable\n' \
        "$(sha256sum < "$tmp" | cut -d' ' -f1)" "$n" "$bytes" "$unreadable"
    rm -f "$tmp"
}

hfs_with_mounted_part "$img" 1 digest_body
