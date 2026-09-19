#!/usr/bin/env bash
# Is this image still made of what the repository is made of?
#
# THE PROBLEM THIS ANSWERS, WHICH IS OURS AND NOT THE FAMILY'S
#
# Every sibling ships a BUILT ARTIFACT, so an ingredient bump triggers a
# repackage: shipyard's `repackage-on-ingredient-bump` caller dispatches a
# release, the new artifact supersedes the old one, and the published thing
# is never out of date for long.
#
# We ship a RECIPE. Our release contains no image. A bump therefore
# obsoletes nothing published -- and that sounds harmless until you notice
# what it does instead: it SILENTLY INVALIDATES EVERY GOLDEN IMAGE ALREADY
# ON DISK. Renovate moves the OpenCore pin, and a 9 GB golden built last
# week is now something no commit in this repository can reproduce. Nothing
# fails. Nothing is red. The image keeps booting. It just no longer means
# what its manifest says it means.
#
# That is the exact failure the family's ingredient machinery exists to
# make visible, so it gets a mechanism here rather than a paragraph:
#
#   * image/build-image.sh records every pin in the manifest, one
#     `ingredient.<name>` line each (see bin/ingredient-fingerprint.sh);
#   * image/compare-images.sh's manifest diff therefore names the
#     ingredient that differs between two images, for free;
#   * and this script compares ONE image against the repository as it is
#     now, which is the question you actually have before you run a guest.
#
#   usage: bin/image-staleness.sh <manifest> [...]
#
# Exit 0 when every recorded pin still matches, 1 when any has moved.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=image-staleness

[ $# -ge 1 ] || die "usage: $(basename "$0") <manifest> [...]"

now=$(mktemp) || die "cannot create a temp file"
trap 'rm -f "$now"' EXIT
"$MQG_REPO_ROOT/bin/ingredient-fingerprint.sh" --list > "$now"

overall=0
for manifest in "$@"; do
    [ -f "$manifest" ] || die "no such manifest: $manifest"
    name=$(awk -F'\t' '$1 == "name" { print $2; exit }' "$manifest")
    recorded=$(mktemp) || die "cannot create a temp file"

    # `ingredient.<name>\t<value>` -> `<name>\t<value>`, so the two
    # listings are directly comparable.
    sed -n 's/^ingredient\.//p' "$manifest" | LC_ALL=C sort > "$recorded"

    if [ ! -s "$recorded" ]; then
        # Manifests written before this existed. Say so plainly: "I cannot
        # tell" is a different answer from "it is fine", and conflating
        # them is how a stale golden gets trusted.
        warn "${name:-$manifest}: built before ingredients were recorded --" \
            "staleness cannot be determined. Rebuild it to find out."
        rm -f "$recorded"
        overall=1
        continue
    fi

    moved=$(LC_ALL=C comm -3 "$recorded" "$now" || true)
    if [ -z "$moved" ]; then
        log "${name:-$manifest}: every recorded ingredient still matches" \
            "this checkout"
    else
        printf 'STALE  %s\n' "${name:-$manifest}" >&2
        # comm's two columns: column 1 is what the image has, column 2 is
        # what the repository has now.
        LC_ALL=C comm -23 "$recorded" "$now" \
            | sed 's/^/    image:      /' >&2
        LC_ALL=C comm -13 "$recorded" "$now" \
            | sed 's/^/    repository: /' >&2
        overall=1
    fi
    rm -f "$recorded"
done

if [ "$overall" -ne 0 ]; then
    warn "an image above was built from ingredients this checkout no longer" \
        "pins. It still boots; it is simply no longer reproducible from" \
        "HEAD. Rebuild it, or check out the commit its manifest names."
fi
exit "$overall"
