#!/usr/bin/env bash
# Give one VM its own writable copy of the EFI variable store.
#
# OVMF's split pflash pair is one read-only CODE image and one writable VARS
# image. The VARS image boot/build-ovmf.sh produces is a *template*: it is
# the empty variable store the build laid out, it is what SHA256SUMS
# records, and the moment QEMU is pointed at it, it stops being either.
# Boot order, the picker's remembered choice and everything else the guest
# writes land in that file. Two VMs sharing one would trample each other,
# and any VM writing to the build output would silently invalidate the
# checksum of a build artifact.
#
# So: copy, never share, and never write where the build writes. This script
# is the only thing that makes such a copy, which is why it is a script and
# not a line in a profile.
#
# Refusing to clobber is the point of --force existing. An existing NVRAM
# file is accumulated state -- the boot entry the guest installed, the
# default the picker remembers -- and re-running a setup command should not
# be how you lose it. --force says "yes, reset this VM's EFI variables",
# which is a real thing to want and a deliberate one.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
FIRMWARE_DIR=${MQG_FIRMWARE_DIR:-$MQG_BUILD_DIR/firmware}
WORK_DIR=${WORK_DIR:-$MQG_IMAGE_DIR/work}

TEMPLATE="$FIRMWARE_DIR/OVMF_VARS.fd"

usage() {
    die "usage: boot/make-nvram.sh [--force] <vm-name>

Copies the pristine OVMF_VARS.fd template to
$WORK_DIR/<vm-name>-VARS.fd, which is where a profile's
pflash unit 1 should point. Refuses to overwrite without --force."
}

force=0
if [ "${1:-}" = "--force" ]; then
    force=1
    shift
fi

[ $# -eq 1 ] || usage
name=$1

# A name is a filename component, not a path. Without this, a caller could
# pass ../../something and write outside WORK_DIR -- including back into the
# build output, which is the one thing this script exists to prevent.
case $name in
    '' | *[/]* | . | ..) die "not a usable VM name: $name" ;;
esac

[ -f "$TEMPLATE" ] \
    || die "no VARS template at $TEMPLATE -- run boot/build-ovmf.sh first"

# Verify the template against the build's own SHA256SUMS before copying it.
# The whole value of a "pristine" template is that it is unmodified; a
# template someone has booted from by accident looks exactly like one that
# has not.
sums="$FIRMWARE_DIR/SHA256SUMS"
if [ -f "$sums" ]; then
    want=$(awk '$2 == "OVMF_VARS.fd" { print $1; exit }' "$sums")
    if [ -n "$want" ]; then
        verify_sha256 "$TEMPLATE" "$want"
    else
        warn "$sums does not list OVMF_VARS.fd; copying it unverified"
    fi
else
    warn "no $sums; copying the template unverified"
fi

dest="$WORK_DIR/$name-VARS.fd"

# Belt and braces: WORK_DIR could have been pointed at the build directory
# by environment. Compare resolved parent directories rather than the
# strings, so a symlink or a trailing slash does not get past this.
dest_dir=$(cd "$(dirname "$dest")" 2>/dev/null && pwd || printf '%s\n' "$WORK_DIR")
build_dir=$(cd "$MQG_BUILD_DIR" 2>/dev/null && pwd || printf '%s\n' "$MQG_BUILD_DIR")
case "$dest_dir/" in
    "$build_dir/"*) die "refusing to write NVRAM into the build output: $dest" ;;
esac

if [ -e "$dest" ] && [ "$force" -ne 1 ]; then
    die "$dest already exists -- that VM's EFI variables are in it." \
        "Pass --force to reset them."
fi

mkdir -p "$WORK_DIR"
# Write to a temporary name and move it into place, so an interrupted copy
# cannot leave a half-written variable store that QEMU would happily boot.
tmp="$dest.tmp.$$"
cp "$TEMPLATE" "$tmp" || die "cannot copy $TEMPLATE to $tmp"
chmod u+w "$tmp"
mv -f "$tmp" "$dest" || die "cannot move $tmp into place at $dest"

log "NVRAM for $name: $dest ($(stat -c %s "$dest") bytes, from $TEMPLATE)"
printf '%s\n' "$dest"
