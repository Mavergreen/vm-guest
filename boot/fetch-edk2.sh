#!/usr/bin/env bash
# Fetch the OpenCore build's EDK II inputs, each pinned to one commit.
#
# This is the only part of the OpenCore build that touches the network.
# boot/build-opencore.sh assembles and builds entirely from what this
# script leaves behind, which is what makes `unshare -rn ./boot/build-
# opencore.sh` a real test rather than a gesture.
#
# What gets fetched, and why:
#
#   ocbuild-efibuild  OpenCorePkg's build_oc.tool used to curl this off
#                     ocbuild's master branch and eval it. Same file, from
#                     an immutable /<commit>/ URL, with a checksum.
#   audk-src          The EDK II fork efibuild.sh would otherwise clone at
#                     master. A tarball, so it has a checksum, matching how
#                     OpenCorePkg itself is pinned.
#   audk-*            audk's submodules, which a GitHub archive tarball does
#                     not carry. `git submodule update --init` is what
#                     upstream does; this is the same thing with checksums.
#
# The list is not kept here. boot/build-opencore.sh names the pins, because
# it is the thing that has to agree with them, and this script asks it
# (--show-pins) what to download. Adding an input there is enough.
#
# Everything lands under MQG_BUILD_DIR (local btrfs), never in the repo.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/vendor.sh
. "$MQG_REPO_ROOT/lib/vendor.sh"

mapfile -t EDK2_SOURCES < <(
    "$MQG_REPO_ROOT/boot/build-opencore.sh" --show-pins | cut -f1
)
[ "${#EDK2_SOURCES[@]}" -gt 0 ] \
    || die "boot/build-opencore.sh --show-pins named no sources"

if [ "${1:-}" = "--list-sources" ]; then
    printf '%s\n' "${EDK2_SOURCES[@]}"
    exit 0
fi

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
SOURCES=${MQG_SOURCES:-$MQG_REPO_ROOT/vendor/sources.tsv}

require_cmd curl

# Check the whole list first: an unpinned entry is an operator decision, and
# finding that out after a 50 MB download helps nobody.
for name in "${EDK2_SOURCES[@]}"; do
    sha=$(source_field "$SOURCES" "$name" sha256)
    if [ "${MQG_REQUIRE_PINNED:-0}" = "1" ] && [ "$sha" = "TOFU" ]; then
        die "$name is not pinned; fetch once, review the checksum, and commit it"
    fi
done

mkdir -p "$MQG_BUILD_DIR"
for name in "${EDK2_SOURCES[@]}"; do
    fetch_source "$SOURCES" "$name" "$MQG_BUILD_DIR" >/dev/null
done
log "fetched ${#EDK2_SOURCES[@]} pinned inputs into $MQG_BUILD_DIR"
