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
#   sha256 of a sorted list of "<sha256>  <path>", one per file.
#
# Deliberately not including mtimes, ownership or modes: rsync carries the
# first, the privops microVM sets the second and third uniformly, and none
# of them is what an installer reads.
#
# THIS MOUNTS NOTHING ON THE HOST.
#
# It used to: udisks2 attached a loop device and mounted the volume under
# /run/media/$USER. That needs a desktop seat -- polkit refuses loop-setup
# to an SSH session with NotAuthorizedCanObtain -- so this script could not
# run on a headless host at all. That mattered more than "a by-hand
# diagnostic" suggests, because image/build-image.sh calls it for the
# `mediacontent` line of every image manifest, with stderr discarded: on a
# host with no seat the field came out EMPTY and nothing said why.
#
# Now the volume is mounted read-only inside the privops microVM, the same
# one media/build-installer-img.sh assembles media in, and the per-file
# listing comes back out on a raw disk. See media/privops/content-digest.sh.
#
# TWO CONSEQUENCES OF THE MOVE, BOTH DELIBERATE:
#
#   1. DIGESTS TAKEN BEFORE 2026-09-21 DO NOT COMPARE WITH THESE. The old
#      path read the volume as an ordinary user, so BaseSystem's /.file
#      (mode 0000) could not be read and was listed as "UNREADABLE-0" with
#      no checksum. The microVM is uid 0 and reads it, so it now gets a
#      real sha256 and the summary's unreadable count is structurally zero.
#      One line of 39,415 changes, and with it the digest.
#   2. The volume is mounted -o ro off a readonly=on virtio disk, so taking
#      a digest can no longer alter the image. The old udisks mount was
#      read-write, which rewrote the volume header of the very file whose
#      contents it was reporting on.
#
# Takes about 90 seconds on this host for 6.4 GB and 39,000 files, against
# about 20 for the old mount-and-hash path: busybox's sha256sum is roughly
# a third the speed of coreutils'. Measured, both ways, on the same media.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/hfs.sh
. "$MQG_REPO_ROOT/lib/hfs.sh"
# shellcheck source=../lib/privops.sh
. "$MQG_REPO_ROOT/lib/privops.sh"
# shellcheck source=../lib/privops-qemu-linux.sh
. "$MQG_REPO_ROOT/lib/privops-qemu-linux.sh"

# Read at call time by log()/warn()/die() in lib/common.sh.
# shellcheck disable=SC2034
MQG_LOG_PREFIX=content-digest

usage() {
    cat <<EOF
usage: $(basename "$0") [--list] <image>

  --list   Print the per-file lines instead of just the digest, so two
           builds can be diffed rather than merely compared.

Prints "<sha256>  <n> files  <bytes> bytes  <n> unreadable".

<image> may be a bare HFS+ volume or a partitioned disk: the microVM tries
the largest HFS+ thing it finds on it, which is what dmg2img output and
GPT installer media both need. Nothing is mounted on this host, and the
image is attached read-only, so this cannot alter it.
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
require_cmd sha256sum truncate mkfs.hfsplus

# Named, all of them, before anything else happens. A digest that dies
# with "the privops backend is not available" and no list is the failure
# mode lib/privops.sh exists to prevent; saying it here costs nothing and
# means a host learns what it lacks in a second rather than after a boot.
missing=$(privops_backend_missing "$MQG_PRIVOPS_BACKEND")
if [ -n "$missing" ]; then
    printf '%s\n' "$missing" | while IFS= read -r m; do
        warn "  missing: $m"
    done
    die "the privops backend '$MQG_PRIVOPS_BACKEND' is not available on" \
        "this host, and it is how this reads an HFS+ volume at all --" \
        "nothing here mounts anything or installs anything. See" \
        "boot/prereqs.sh and docs/host-profile.md"
fi

work=$(mktemp -d) || die "cannot create a work directory"
trap 'rm -rf "$work"' EXIT INT TERM

# The microVM's first disk is always mounted read-write and is where a
# payload would write; this payload writes nothing to it, but the backend
# needs one, so it gets a throwaway. 32 MiB of sparse file, of which
# mkfs.hfsplus writes about 2 MB of metadata.
scratch=$work/scratch.img
hfs_create "$scratch" 32 "MQG DIGEST"

# The listing comes back on this. Sparse, so the size is a ceiling and not
# a cost: 39,415 files of real installer media make about 4 MB, and the
# guest refuses rather than truncates if a volume ever overflows it.
listing=$work/listing.txt
truncate -s 256M "$listing" || die "cannot create $listing"

console=$work/console.txt
MQG_PRIVOPS_CONSOLE=$console \
    privops_run "$scratch" "$MQG_REPO_ROOT/media/privops/content-digest.sh" \
        "ro:$img" "raw:$listing" >&2

marker() { sed -n "s/^$1 //p" "$console" | tr -d '\r' | head -1; }

files=$(marker MQG-DIGEST-FILES)
hashed=$(marker MQG-DIGEST-HASHED)
bytes=$(marker MQG-DIGEST-BYTES)
size=$(marker MQG-DIGEST-SIZE)
want=$(marker MQG-DIGEST-SHA256)

for n in "$files" "$hashed" "$bytes" "$size"; do
    case $n in
        ''|*[!0-9]*) die "the microVM did not report a usable count" \
                         "(files='$files' hashed='$hashed' bytes='$bytes'" \
                         "size='$size') -- see $console" ;;
    esac
done
[ "$files" = "$hashed" ] \
    || die "the microVM found $files files and could only checksum" \
           "$hashed of them: the volume is unreadable in places, and a" \
           "digest of what happened to be readable would be a digest of" \
           "nothing in particular"

truncate -s "$size" "$listing" || die "cannot truncate $listing"
# The host's own read, against what the guest read back off the device.
# Without this a short or torn write through the raw disk would surface as
# a digest that is simply wrong, with nothing to say so.
got=$(sha256_file "$listing")
[ "$got" = "$want" ] \
    || die "the listing did not survive the trip out of the microVM:" \
           "the guest read $want and this host reads $got"

[ "$list" -eq 0 ] || cat "$listing"
# Unreadable is structurally zero now -- the microVM is uid 0 -- and the
# field stays so the summary line keeps its shape for anything parsing it.
# See the header for why that means old digests do not compare.
printf '%s  %s files  %s bytes  %s unreadable\n' "$got" "$hashed" "$bytes" 0
