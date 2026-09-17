#!/usr/bin/env bash
# Build OpenCore from pinned source and collect what we ship.
#
# OpenCorePkg's build_oc.tool bootstraps EDK II itself (acidanthera's audk
# fork) by sourcing ocbuild's efibuild.sh straight off the network. It is
# primarily exercised on macOS; if it misbehaves on Linux, report the actual
# error rather than hand-rolling a substitute build. See NOTES.md for what
# this host actually needed.
#
# Three environment choices are ours, not build_oc.tool's defaults, and each
# one exists for a reason:
#
#   ARCHS=X64       build_oc.tool defaults to (X64 IA32). We boot a 64-bit
#                   guest, and IA32 doubles the build for nothing.
#   TOOLCHAINS=GCC  efibuild.sh's Linux default is (CLANGPDB GCC), i.e. two
#                   full builds, and CLANGPDB needs clang, which this host
#                   does not have. GCC is the one that works here.
#   TARGETS=RELEASE default is (DEBUG RELEASE NOOPT). A DEBUG build writes a
#                   log on every boot and is substantially slower.
set -euo pipefail

OC_VERSION=1.0.7
OC_ARCH=X64
OC_TOOLCHAIN=GCC
OC_TARGET=RELEASE

# What we ship: "<name build_oc.tool produces>:<name we ship it as>".
#
# Bootstrap.efi is renamed rather than found: OpenCore's bootstrap driver is
# what becomes the fallback boot path EFI/BOOT/BOOTx64.efi, and nothing in
# the build tree is ever called BOOTx64.efi. build_oc.tool's own package()
# does this same rename, but then deletes the staged tree once it has zipped
# it, so we do the rename ourselves rather than unpacking its archive.
#
# OpenHfsPlus is in Staging/, but 1.0.7's OpenCorePkg.dsc lists
# Staging/OpenHfsPlus/OpenHfsPlus.inf in [Components] alongside everything
# else, so the default target does build it. Nothing extra is needed.
ARTIFACT_MAP=(
    "OpenCore.efi:OpenCore.efi"
    "Bootstrap.efi:BOOTx64.efi"
    "OpenRuntime.efi:OpenRuntime.efi"
    "OpenPartitionDxe.efi:OpenPartitionDxe.efi"
    "OpenHfsPlus.efi:OpenHfsPlus.efi"
)

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

artifact_names() {
    local entry
    for entry in "${ARTIFACT_MAP[@]}"; do
        printf '%s\n' "${entry#*:}"
    done
}

if [ "${1:-}" = "--list-artifacts" ]; then
    artifact_names
    exit 0
fi

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
SRC="$MQG_BUILD_DIR/OpenCorePkg-$OC_VERSION"
OUT="$MQG_BUILD_DIR/artifacts"

[ -d "$SRC" ] || die "no OpenCorePkg source tree at $SRC -- run boot/fetch-opencorepkg.sh first"

# build_oc.tool needs these beyond what prereqs.sh checks: curl to fetch
# efibuild.sh, zip because efibuild.sh refuses to start without it.
require_cmd curl zip

"$MQG_REPO_ROOT/boot/prereqs.sh" >/dev/null || die "build prerequisites are missing -- run boot/prereqs.sh"

log "building OpenCore $OC_VERSION in $SRC"
log "arch $OC_ARCH, toolchain $OC_TOOLCHAIN, target $OC_TARGET (this takes a while and is noisy)"
start=$(date +%s)
(
    cd "$SRC"
    ARCHS=$OC_ARCH TOOLCHAINS=$OC_TOOLCHAIN TARGETS=$OC_TARGET ./build_oc.tool
) || die "build_oc.tool failed -- see $SRC/UDK/build.log, and report the error rather than working around it"
elapsed=$(( $(date +%s) - start ))
log "build_oc.tool finished in $((elapsed / 60))m$((elapsed % 60))s"

BUILT="$SRC/UDK/Build/OpenCorePkg/${OC_TARGET}_${OC_TOOLCHAIN}/$OC_ARCH"
[ -d "$BUILT" ] || die "build reported success but $BUILT does not exist"

mkdir -p "$OUT"
missing=()
for entry in "${ARTIFACT_MAP[@]}"; do
    built_name=${entry%%:*}
    ship_name=${entry#*:}
    if [ -f "$BUILT/$built_name" ]; then
        cp "$BUILT/$built_name" "$OUT/$ship_name"
    else
        missing+=("$built_name")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    warn "not produced by the build: ${missing[*]}"
    warn "looked in $BUILT"
    die "missing ${#missing[@]} of ${#ARTIFACT_MAP[@]} artifacts"
fi

# ocvalidate is a host tool, not firmware: Task 4 runs it against our
# config.plist so the config is checked by the schema of the exact OpenCore
# we built, not by whatever ocvalidate happens to be lying around.
ocvalidate="$SRC/Utilities/ocvalidate/ocvalidate"
if [ -x "$ocvalidate" ]; then
    log "ocvalidate: $ocvalidate"
else
    warn "ocvalidate not built at $ocvalidate -- Task 4 needs it"
fi

mapfile -t ship_names < <(artifact_names)
( cd "$OUT" && sha256sum "${ship_names[@]}" > SHA256SUMS )
log "built ${#ship_names[@]} artifacts into $OUT"
cat "$OUT/SHA256SUMS"
