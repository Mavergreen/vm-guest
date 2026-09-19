#!/usr/bin/env bash
# Every pin this repository controls, as one flat list -- and a single
# digest over it.
#
# WHAT AN INGREDIENT IS HERE
#
# Anything that, if it moved, would make the next image different from the
# last one. That is the boot-stack sources in vendor/sources.tsv, the
# component pins under components/*/version, and boot/config/config.plist
# (OpenCore's configuration is as much an input as OpenCore is).
#
# WHY IT IS A LIST AND NOT ONLY A HASH
#
# A hash answers "did anything move"; a list answers "what moved". The
# image manifest carries both: each pin as its own `ingredient.<name>` line
# so image/compare-images.sh's manifest diff names the ingredient for free,
# and the digest so a human can compare two images at a glance. See
# bin/image-staleness.sh and INGREDIENTS.md.
#
#   usage: bin/ingredient-fingerprint.sh [--list]
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=ingredient-fingerprint

list=0
case ${1:-} in
    --list) list=1 ;;
    "") : ;;
    *) die "usage: $(basename "$0") [--list]" ;;
esac

# The listing, sorted, so its digest does not depend on file order.
ingredient_list() {
    # vendor/sources.tsv: name -> the checksum, which IS the identity of
    # the artifact. The URL is how to get it; the checksum is what it is.
    # A URL that changes while the bytes do not is not a new ingredient.
    awk -F'\t' '$0 !~ /^#/ && NF >= 3 && $1 != "" { print $1 "\t" $3 }' \
        "$MQG_REPO_ROOT/vendor/sources.tsv"

    # components/<name>/version: whole-file pins on other ModernMavericks
    # products, the shape the family's Renovate managers expect.
    local v name
    for v in "$MQG_REPO_ROOT"/components/*/version; do
        [ -f "$v" ] || continue
        name=$(basename "$(dirname "$v")")
        printf '%s\t%s\n' "$name" \
            "$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$v" \
               | grep -v '^$' | head -1)"
    done

    # Ours, but an input all the same: change a boot argument or a kext
    # entry here and every future image boots differently.
    printf 'config.plist\t%s\n' \
        "$(sha256_file "$MQG_REPO_ROOT/boot/config/config.plist")"
}

if [ "$list" -eq 1 ]; then
    ingredient_list | LC_ALL=C sort
else
    ingredient_list | LC_ALL=C sort | sha256sum | cut -d' ' -f1
fi
