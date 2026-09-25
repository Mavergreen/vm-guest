#!/usr/bin/env bash
# Fetch the SMC-emulation kexts OpenCore injects, pinned to exact releases.
#
# These are the only non-Tier-0 things in the assembled EFI image:
# acidanthera ships them as release binaries and we do not build them. The
# most we can do is pin the release tag, checksum the archive, and record
# why those versions -- which is what this script and
# boot/config/README.md between them do.
#
# Everything lands under MQG_BUILD_DIR (local btrfs), never in the repo.
# The layout produced is exactly what boot/build-efi-image.sh expects:
#
#   $MQG_BUILD_DIR/kexts/<Name>.kext/Contents/Info.plist
#   $MQG_BUILD_DIR/kexts/<Name>.kext/Contents/MacOS/<Name>
#
# A release archive that does not contain both is a failure here, named
# piece by piece, rather than a confusing mcopy error during image
# assembly.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/vendor.sh
. "$MQG_REPO_ROOT/lib/vendor.sh"

# "<source name in assets/pins/sources.tsv>:<kext bundle name>".
#
# The bundle name is also the name of the Mach-O inside Contents/MacOS,
# which is the convention every acidanthera kext follows. The archives do
# not agree on where the bundle sits inside them -- Lilu ships Lilu.kext at
# the top level, VirtualSMC ships its kexts under Kexts/ next to Tools/ and
# Drivers/ -- so the bundle is searched for rather than assumed.
KEXTS=(
    "lilu-release:Lilu"
    "virtualsmc-release:VirtualSMC"
)

if [ "${1:-}" = "--list" ]; then
    for entry in "${KEXTS[@]}"; do
        printf '%s\n' "${entry#*:}"
    done
    exit 0
fi

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
SOURCES=${MQG_SOURCES:-$MQG_REPO_ROOT/assets/pins/sources.tsv}
KEXT_DIR="$MQG_BUILD_DIR/kexts"

require_cmd curl unzip

# Check the whole list before downloading anything: an unpinned entry is an
# operator decision, and finding that out after the download helps nobody.
for entry in "${KEXTS[@]}"; do
    name=${entry%%:*}
    sha=$(source_field "$SOURCES" "$name" sha256)
    if [ "${MQG_REQUIRE_PINNED:-0}" = "1" ] && [ "$sha" = "TOFU" ]; then
        die "$name is not pinned; fetch once, review the checksum, and commit it"
    fi
done

mkdir -p "$KEXT_DIR"

for entry in "${KEXTS[@]}"; do
    name=${entry%%:*}
    kext=${entry#*:}
    bundle="$KEXT_DIR/$kext.kext"

    if [ -d "$bundle" ]; then
        log "$kext.kext already unpacked at $bundle"
    else
        archive=$(fetch_source "$SOURCES" "$name" "$MQG_BUILD_DIR")
        unpack="$KEXT_DIR/.unpack/$name"
        rm -rf "$unpack"
        mkdir -p "$unpack"
        unzip -q -o "$archive" -d "$unpack" \
            || die "cannot unpack $archive"

        # -prune so a .dSYM's internal copy of the bundle name, or a nested
        # plugin kext, cannot win over the real one.
        found=$(find "$unpack" -name "$kext.kext" -type d -prune -print \
                | sort | head -n 1)
        [ -n "$found" ] \
            || die "$archive contains no $kext.kext"
        mv "$found" "$bundle" || die "cannot move $found to $bundle"
        rm -rf "$unpack"
    fi

    # The two pieces OpenCore needs, checked by name so a failure says
    # which one is missing rather than "no such file".
    [ -f "$bundle/Contents/Info.plist" ] \
        || die "$bundle is not a kext bundle: no Contents/Info.plist"
    [ -f "$bundle/Contents/MacOS/$kext" ] \
        || die "$bundle is not a kext bundle: no Contents/MacOS/$kext"
    log "$kext.kext ready at $bundle"
done

log "kexts unpacked into $KEXT_DIR"
