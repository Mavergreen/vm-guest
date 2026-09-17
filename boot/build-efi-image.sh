#!/usr/bin/env bash
# Assemble our built OpenCore artifacts and our config into a bootable
# EFI image. Everything in it is Tier 0 except the kexts, which are
# pinned Tier 1 -- see boot/config/README.md.
#
# sgdisk plus mtools: no loop mounts, no root. The image lands under
# MQG_IMAGE_DIR, never in the repo.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/efi.sh
. "$MQG_REPO_ROOT/lib/efi.sh"

# The image size. The reference image is a 191 MiB one, and this is the
# same class of thing, so the number is not arbitrary -- but nothing here
# depends on it being right by luck: efi_fits below refuses to build if the
# payload plus headroom does not fit, before mcopy gets a chance to fail
# with a message about a file rather than about the image.
IMAGE_MIB=192

# Built by boot/build-opencore.sh, in the order they are laid out below.
ARTIFACTS=(BOOTx64.efi OpenCore.efi OpenRuntime.efi OpenPartitionDxe.efi OpenHfsPlus.efi)

# Unpacked by boot/fetch-kexts.sh. Load order matters to OpenCore, and
# boot/config/config.plist lists them in this same order: VirtualSMC
# declares a dependency on Lilu.
KEXTS=(Lilu VirtualSMC)

if [ "${1:-}" = "--list-contents" ]; then
    printf '%s\n' "${ARTIFACTS[@]}" "${KEXTS[@]/%/.kext}" config.plist
    exit 0
fi

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
ART="$MQG_BUILD_DIR/artifacts"
CONFIG="$MQG_REPO_ROOT/boot/config/config.plist"
OUT=${1:-$MQG_IMAGE_DIR/work/opencore-p3.img}

require_cmd sgdisk mformat mmd mcopy mdir truncate

[ -d "$ART" ] || die "no artifacts at $ART -- run boot/build-opencore.sh first"
[ -f "$CONFIG" ] || die "no boot/config/config.plist"

# Verify what we are about to ship still matches what was built.
( cd "$ART" && sha256sum -c SHA256SUMS >/dev/null ) \
    || die "artifacts in $ART do not match SHA256SUMS -- rebuild"

# Everything must exist before anything is created, so a missing input is
# a message and not a half-built image.
for a in "${ARTIFACTS[@]}"; do
    [ -f "$ART/$a" ] || die "missing $ART/$a -- run boot/build-opencore.sh"
done
for kext in "${KEXTS[@]}"; do
    kdir="$MQG_BUILD_DIR/kexts/$kext.kext"
    [ -d "$kdir" ] || die "missing $kdir -- run boot/fetch-kexts.sh"
    # The two paths boot/config/config.plist names as PlistPath and
    # ExecutablePath. Named individually so a failure says which one.
    [ -f "$kdir/Contents/Info.plist" ] \
        || die "missing $kdir/Contents/Info.plist -- run boot/fetch-kexts.sh"
    [ -f "$kdir/Contents/MacOS/$kext" ] \
        || die "missing $kdir/Contents/MacOS/$kext -- run boot/fetch-kexts.sh"
done

# Size the image against what is actually going into it rather than hoping.
payload=0
for a in "${ARTIFACTS[@]}"; do
    payload=$(( payload + $(stat -c '%s' "$ART/$a") ))
done
payload=$(( payload + $(stat -c '%s' "$CONFIG") ))
for kext in "${KEXTS[@]}"; do
    payload=$(( payload + $(du -sb "$MQG_BUILD_DIR/kexts/$kext.kext" | cut -f1) ))
done
efi_fits "$IMAGE_MIB" "$payload" \
    || die "payload of $payload bytes does not fit in ${IMAGE_MIB} MiB with headroom -- raise IMAGE_MIB"
log "payload is $payload bytes; image is ${IMAGE_MIB} MiB"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT.sha256"
efi_image_create "$OUT" "$IMAGE_MIB"

for d in ::/EFI ::/EFI/BOOT ::/EFI/OC ::/EFI/OC/Drivers ::/EFI/OC/Kexts \
         ::/EFI/OC/ACPI ::/EFI/OC/Tools ::/EFI/OC/Resources; do
    efi_mkdir "$OUT" "$d"
done

efi_copy_in "$OUT" "$ART/BOOTx64.efi"           "::/EFI/BOOT/BOOTx64.efi"
efi_copy_in "$OUT" "$ART/OpenCore.efi"          "::/EFI/OC/OpenCore.efi"
efi_copy_in "$OUT" "$ART/OpenRuntime.efi"       "::/EFI/OC/Drivers/OpenRuntime.efi"
efi_copy_in "$OUT" "$ART/OpenPartitionDxe.efi"  "::/EFI/OC/Drivers/OpenPartitionDxe.efi"
efi_copy_in "$OUT" "$ART/OpenHfsPlus.efi"       "::/EFI/OC/Drivers/OpenHfsPlus.efi"
efi_copy_in "$OUT" "$CONFIG"                    "::/EFI/OC/config.plist"

# Kexts: pinned Tier 1, unpacked by boot/fetch-kexts.sh into the build area.
# Copied as whole bundles -- OpenCore reads paths inside them, so the shape
# has to survive the trip.
for kext in "${KEXTS[@]}"; do
    efi_copy_tree "$OUT" "$MQG_BUILD_DIR/kexts/$kext.kext" \
        "::/EFI/OC/Kexts/$kext.kext"
done

sha256_file "$OUT" > "$OUT.sha256"
log "built $OUT"
efi_list "$OUT" "::/EFI/OC"
