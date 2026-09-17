#!/usr/bin/env bash
# Fetch OpenCorePkg at a pinned tag, into the local build area.
#
# A release tarball rather than a git clone: a tag can be moved, a tarball
# has a checksum we pin. Same trust-on-first-use machinery as every other
# third-party artifact here.
#
# The build area lives under MQG_IMAGE_DIR (local btrfs), NOT in the repo.
# An EDK II build creates tens of thousands of small files and this repo is
# on NFS at roughly 18 ms per file creation.
set -euo pipefail

OC_VERSION=1.0.7

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/vendor.sh
. "$MQG_REPO_ROOT/lib/vendor.sh"

if [ "${1:-}" = "--show-version" ]; then
    printf 'OpenCorePkg %s\n' "$OC_VERSION"
    exit 0
fi

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
SOURCES=${MQG_SOURCES:-$MQG_REPO_ROOT/vendor/sources.tsv}

require_cmd curl tar

sha=$(source_field "$SOURCES" opencorepkg-src sha256)
if [ "${MQG_REQUIRE_PINNED:-0}" = "1" ] && [ "$sha" = "TOFU" ]; then
    die "opencorepkg-src is not pinned; fetch once, review the checksum, and commit it"
fi

mkdir -p "$MQG_BUILD_DIR"
tarball=$(fetch_source "$SOURCES" opencorepkg-src "$MQG_BUILD_DIR")

dest="$MQG_BUILD_DIR/OpenCorePkg-$OC_VERSION"
if [ -d "$dest" ]; then
    log "already unpacked at $dest"
else
    log "unpacking to $dest"
    tar -C "$MQG_BUILD_DIR" -xzf "$tarball"
fi

[ -f "$dest/build_oc.tool" ] || die "$dest does not look like OpenCorePkg: no build_oc.tool"
printf '%s\n' "$dest"
