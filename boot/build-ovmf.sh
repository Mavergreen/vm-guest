#!/usr/bin/env bash
# Build OVMF -- the guest's UEFI firmware -- from the same pinned EDK II
# tree OpenCore is built from.
#
# This script makes no network requests. Every input it uses was fetched
# and checksummed by boot/fetch-edk2.sh and unpacked by
# boot/build-opencore.sh; here they are only compiled. The test for that
# claim is `unshare -rn ./boot/build-ovmf.sh`.
#
# Why this exists at all. P3's gate is that nothing in the boot path is a
# binary we cannot rebuild. Everything else got there first; the firmware
# was the last holdout, and the obvious replacement -- Debian's stock OVMF
# 2024.02 -- does not work with OpenCore on this host. That was proved with
# a control: khronokernel's reference OpenCore 0.6.6 fails the same way our
# own 1.0.7 does. OpenCore runs (it sets the framebuffer resolution from our
# config) and then renders nothing, with `Failed to start image - Already
# started` in its log. See the P3 Task 8 entry in NOTES.md.
#
# OvmfPkg is part of EDK II, and the EDK II we already pin is
# acidanthera/audk -- acidanthera's fork, the one OpenCore itself is built
# against. So building the firmware from it is not a workaround for the
# incompatibility; it is the most likely thing to not have it, and it is
# what P3 wanted anyway. It works: see the P3 Task 9 entry in NOTES.md.
#
# We reuse boot/build-opencore.sh's assembled tree rather than unpacking a
# second copy of a 19 MB tarball and eleven submodules, and rather than
# maintaining a second list of submodule pins that could drift out of step
# with the first. The cost is an ordering dependency -- build OpenCore, then
# build OVMF -- which this script states rather than papers over. The
# OpenCorePkg patches that tree carries touch DuetPkg's SATA/ATA drivers and
# ShellPkg; none of them reach OvmfPkg.
#
# Three environment choices, the same three boot/build-opencore.sh makes and
# for the same reasons:
#
#   ARCHS=X64       we boot a 64-bit guest.
#   TOOLCHAINS=GCC  the one that works on this host; CLANGPDB needs clang.
#   TARGETS=RELEASE a DEBUG firmware logs on every boot and is slower.
set -euo pipefail

OVMF_ARCH=X64
OVMF_TOOLCHAIN=GCC
OVMF_TARGET=RELEASE
OVMF_DSC=OvmfPkg/OvmfPkgX64.dsc

# What a successful build leaves in the FV directory, and what we ship it
# as. The split pair and the combined image are all three produced by the
# same build -- OVMF.fd is the concatenation of CODE and VARS -- so there is
# no choice to make here and no flag to add. We take all of them:
#
#   OVMF_CODE.fd + OVMF_VARS.fd   pflash unit 0 and unit 1. The pair is what
#                                 makes EFI variables persist across boots,
#                                 which -bios cannot do.
#   OVMF.fd                       one complete image for `-bios`, which is
#                                 how the reference firmware was wired and
#                                 therefore the fallback worth having.
#
# Nothing here is optional: a build that produced only some of them built
# something other than what this script describes, and should say so.
FIRMWARE_FILES=(
    OVMF_CODE.fd
    OVMF_VARS.fd
    OVMF.fd
)

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

if [ "${1:-}" = "--list-artifacts" ]; then
    printf '%s\n' "${FIRMWARE_FILES[@]}"
    exit 0
fi

if [ "${1:-}" = "--show-build" ]; then
    printf '%s\t%s\t%s\t%s\n' \
        "$OVMF_DSC" "$OVMF_ARCH" "$OVMF_TOOLCHAIN" "$OVMF_TARGET"
    exit 0
fi

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
OUT=${MQG_FIRMWARE_DIR:-$MQG_BUILD_DIR/firmware}

# Ask boot/build-opencore.sh where the tree is and which commit it should
# hold, rather than recomputing either. One place knows the layout.
UDK=$("$MQG_REPO_ROOT/boot/build-opencore.sh" --udk-dir) \
    || die "cannot ask boot/build-opencore.sh where the EDK II tree is"
AUDK_COMMIT=$("$MQG_REPO_ROOT/boot/build-opencore.sh" --udk-commit) \
    || die "cannot ask boot/build-opencore.sh which audk commit it pins"

# The tree has to be there, at the pinned commit, with BaseTools compiled.
# All three are boot/build-opencore.sh's doing, so all three failures point
# at the same fix -- but they are checked separately, because "run the other
# script" is only useful advice when you can see which part is missing.
prepared="$UDK/.mqg-prepared"
[ -f "$prepared" ] \
    || die "no assembled EDK II tree at $UDK -- run boot/build-opencore.sh first"
have=$(cat "$prepared")
[ "$have" = "$AUDK_COMMIT" ] \
    || die "EDK II tree at $UDK holds audk $have, not the pinned $AUDK_COMMIT" \
           "-- re-run boot/build-opencore.sh"
[ -x "$UDK/BaseTools/Source/C/bin/GenFv" ] \
    || die "BaseTools are not built in $UDK -- run boot/build-opencore.sh first"

# nasm and iasl are OvmfPkg's, not OpenCore's: the reset vector is assembled
# with nasm and the ACPI tables are compiled with iasl. prereqs.sh already
# requires both, so the same check covers this build.
"$MQG_REPO_ROOT/boot/prereqs.sh" >/dev/null \
    || die "build prerequisites are missing -- run boot/prereqs.sh"

log "building $OVMF_DSC from audk $AUDK_COMMIT in $UDK"
log "arch $OVMF_ARCH, toolchain $OVMF_TOOLCHAIN, target $OVMF_TARGET"
start=$(date +%s)
(
    cd "$UDK"
    # edksetup.sh is not written for `set -u`, and sourcing it is the only
    # supported way to get `build` on PATH with WORKSPACE and CONF_PATH set.
    # The subshell keeps what it does to the environment from escaping.
    set +u
    # shellcheck disable=SC1091
    . ./edksetup.sh >/dev/null \
        || { printf 'edksetup.sh failed\n' >&2; exit 1; }
    build -a "$OVMF_ARCH" -b "$OVMF_TARGET" -t "$OVMF_TOOLCHAIN" \
          -p "$OVMF_DSC" > ovmf-build.log 2>&1
) || die "OVMF build failed -- see $UDK/ovmf-build.log, and report the error" \
         "rather than working around it"
elapsed=$(( $(date +%s) - start ))
log "build finished in $((elapsed / 60))m$((elapsed % 60))s"

FV="$UDK/Build/OvmfX64/${OVMF_TARGET}_${OVMF_TOOLCHAIN}/FV"
[ -d "$FV" ] || die "build reported success but $FV does not exist"

mkdir -p "$OUT"
missing=()
for name in "${FIRMWARE_FILES[@]}"; do
    if [ -f "$FV/$name" ]; then
        cp "$FV/$name" "$OUT/$name"
    else
        missing+=("$name")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    warn "not produced by the build: ${missing[*]}"
    warn "looked in $FV"
    die "missing ${#missing[@]} of ${#FIRMWARE_FILES[@]} firmware images"
fi

# The sizes are recorded, not just the checksums. A pflash pair is the one
# place where a size is load-bearing: QEMU sizes each flash device from its
# file, and CODE plus VARS have to add up to the 4 MB the build laid out.
# Seeing the three numbers is how you notice that they do.
( cd "$OUT" && sha256sum "${FIRMWARE_FILES[@]}" > SHA256SUMS )
log "built ${#FIRMWARE_FILES[@]} firmware images into $OUT"
for name in "${FIRMWARE_FILES[@]}"; do
    log "  $name  $(stat -c %s "$OUT/$name") bytes"
done
cat "$OUT/SHA256SUMS"
