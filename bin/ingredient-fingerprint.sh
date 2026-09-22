#!/usr/bin/env bash
# Every pin this repository controls, as one flat list -- and a single
# digest over it. Also, one level down, the same thing for a single
# pipeline stage.
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
# --stage: THE SAME IDEA, ONE LEVEL DOWN
#
# image/build-image.sh used to skip a stage whenever its output file was
# present, which is wrong in exactly the case the machinery above exists to
# prevent: Renovate moves the OpenCore or EDK II pin in vendor/sources.tsv,
# the opencore stage sees its .efi sitting there, skips, and the pipeline
# builds an image from stale firmware without a word.
# bin/image-staleness.sh catches that afterwards, per image; the pipeline
# itself never asked.
#
# So each stage now records what it consumed, beside its output, and reruns
# when that changes. `--stage <name>` is where "what it consumed" is
# defined -- the repository-side half of it. The half that only the
# pipeline knows (which accelerator, which SSH key, the checksum of the
# artifact an earlier stage produced) arrives as `<name>=<value>` arguments
# and is folded into the same list, so there is ONE listing-and-digest
# scheme in this project rather than two.
#
#   usage: bin/ingredient-fingerprint.sh [--list]
#          bin/ingredient-fingerprint.sh --stage <name> [--list] [k=v ...]
#          bin/ingredient-fingerprint.sh --stages
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=ingredient-fingerprint

# The registry this run reads. MQG_SOURCES is the seam
# boot/build-opencore.sh already uses, and it is what lets a test bump a
# pin without touching the checkout.
SOURCES=${MQG_SOURCES:-$MQG_REPO_ROOT/vendor/sources.tsv}

# Stages that have repository-side inputs to declare. `install` is here
# with nothing of its own: everything it consumes is a checksum or a
# parameter the pipeline passes in, and a stage that is absent from this
# list would be indistinguishable from a typo.
STAGE_NAMES="esd opencore ovmf efi payload media install"

usage() {
    printf 'usage: %s [--list]\n' "$(basename "$0")"
    printf '       %s --stage <name> [--list] [<key>=<value> ...]\n' \
        "$(basename "$0")"
    printf '       %s --stages\n' "$(basename "$0")"
    printf '\nstages: %s\n' "$STAGE_NAMES"
}

list=0
stage=
extras=()
while [ $# -gt 0 ]; do
    case $1 in
        --list) list=1 ;;
        --stage)
            [ $# -ge 2 ] || die "--stage needs a stage name"
            stage=$2; shift ;;
        --stages) printf '%s\n' "$STAGE_NAMES" | tr ' ' '\n'; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *=*) extras+=("$1") ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

if [ "${#extras[@]}" -gt 0 ] && [ -z "$stage" ]; then
    die "<key>=<value> arguments only make sense with --stage"
fi

# --- the pieces every listing is built from --------------------------------

# source_pin <name> -- the registry row's checksum, which IS the identity of
# the artifact. The URL is how to get it. A source that is not in the
# registry prints ABSENT rather than nothing, because an input that
# vanished is a change and an empty value would hash the same as a missing
# line.
source_pin() {
    local n=$1 sha
    sha=$(awk -F'\t' -v n="$n" '$0 !~ /^#/ && $1 == n { print $3; exit }' \
        "$SOURCES")
    printf 'source:%s\t%s\n' "$n" "${sha:-ABSENT}"
}

# component_pin <name> -- components/<name>/version, comments stripped.
component_pin() {
    local n=$1 v="$MQG_REPO_ROOT/components/$1/version"
    [ -f "$v" ] || { printf 'component:%s\tABSENT\n' "$n"; return 0; }
    printf 'component:%s\t%s\n' "$n" \
        "$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$v" | grep -v '^$' | head -1)"
}

# tree_digest <prefix> <dir> -- one row per file under <dir>, named by its
# path relative to <dir>. A directory of inputs is not one input: naming
# each file is what lets a rerun say "payload:firstboot.sh" instead of
# "something under image/payload".
#
# __pycache__ is skipped: it is a build artifact of our own mkflatpkg.py
# that appears and disappears depending on whether anything ran, and a
# stage that reran because Python cached a bytecode file would be a rerun
# nobody could explain.
tree_digest() {
    local prefix=$1 dir=$2 f
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s:%s\t%s\n' "$prefix" "${f#"$dir"/}" \
            "$(sha256sum "$f" | cut -d' ' -f1)"
    done <<EOF
$(find "$dir" -type f ! -path '*/__pycache__/*' -print | LC_ALL=C sort)
EOF
}

# The boot stack's pinned sources: OpenCorePkg, ocbuild's efibuild.sh, and
# the audk tree with every submodule. One list, used by both firmware
# stages, because OvmfPkg is compiled out of the tree boot/build-opencore.sh
# assembles -- OpenCorePkg's own Patches/ included. A bump to any of these
# changes both.
boot_stack_pins() {
    source_pin opencorepkg-src
    source_pin ocbuild-efibuild
    awk -F'\t' '$0 !~ /^#/ && $1 ~ /^audk-/ && NF >= 3 { print "source:" $1 "\t" $3 }' \
        "$SOURCES"
}

# The compiler that will actually translate the boot stack, and the flags
# we inject. Asked of boot/build-opencore.sh rather than reassembled here:
# that script is where OC_STD and OC_NO_WERROR live, and a second copy of
# either would be a second thing to keep in step. See lib/compiler.sh for
# why the compiler is recorded rather than pinned, and docs/decisions/0004.
#
# `|| echo` and not `die`: a host with no gcc still has a well-defined
# answer to "what would build this", and it is "nothing". That is a change
# from a host that has one, which is exactly what the stamp should say.
compiler_inputs() {
    printf 'compiler\t%s\n' \
        "$("$MQG_REPO_ROOT/boot/build-opencore.sh" --compiler 2>/dev/null \
           || echo unknown)"
    printf 'build-options\t%s\n' \
        "$("$MQG_REPO_ROOT/boot/build-opencore.sh" --build-options 2>/dev/null \
           || echo unknown)"
}

# --- the listings ----------------------------------------------------------

# The listing, sorted, so its digest does not depend on file order.
ingredient_list() {
    # vendor/sources.tsv: name -> the checksum, which IS the identity of
    # the artifact. The URL is how to get it; the checksum is what it is.
    # A URL that changes while the bytes do not is not a new ingredient.
    awk -F'\t' '$0 !~ /^#/ && NF >= 3 && $1 != "" { print $1 "\t" $3 }' \
        "$SOURCES"

    # components/<name>/version: whole-file pins on other Mavergreen
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

# stage_list <stage> -- the repository-side inputs of one pipeline stage.
#
# Each case below is a claim about what that stage consumes, and the claim
# is checkable: change one of these and the stage must rerun; change
# anything else and it must not.
stage_list() {
    case $1 in
        esd)
            # The one ingredient whose URL is listed beside its checksum.
            # Everywhere else the checksum is the identity and a moved URL
            # is the same artifact -- but Apple's transfer is plain HTTP
            # over an AssetToken handshake (INGREDIENTS.md), the URL is
            # where a bump would show up first, and a rerun costs only a
            # re-verification of bytes that are already on disk:
            # media/fetch-installesd.sh leaves a present, verified file
            # exactly alone.
            source_pin apple-installesd-10.9.5
            printf 'source-url:apple-installesd-10.9.5\t%s\n' \
                "$(awk -F'\t' '$0 !~ /^#/ && $1 == "apple-installesd-10.9.5" { print $2; exit }' \
                   "$SOURCES")"
            ;;
        opencore)
            boot_stack_pins
            tree_digest patch "$MQG_REPO_ROOT/boot/patches"
            compiler_inputs
            ;;
        ovmf)
            # The same tree, the same patches, the same compiler -- plus
            # which .dsc, arch and target this build asks for, which is
            # the only thing that differs from the stage above.
            boot_stack_pins
            tree_digest patch "$MQG_REPO_ROOT/boot/patches"
            compiler_inputs
            printf 'ovmf-build\t%s\n' \
                "$("$MQG_REPO_ROOT/boot/build-ovmf.sh" --show-build 2>/dev/null \
                   | tr '\t' ' ' || echo unknown)"
            ;;
        efi)
            # config.plist and the two Tier 1 kexts that go on the image
            # beside OpenCore. The OpenCore binaries themselves arrive as
            # an `opencore-artifacts=` argument: the OUTPUT hash, not the
            # inputs that produced it, so a compiler that emitted
            # different bytes from identical pins still reruns this.
            printf 'config.plist\t%s\n' \
                "$(sha256_file "$MQG_REPO_ROOT/boot/config/config.plist")"
            source_pin lilu-release
            source_pin virtualsmc-release
            ;;
        payload)
            tree_digest payload "$MQG_REPO_ROOT/image/payload"
            component_pin openssh
            ;;
        media)
            tree_digest autoinstall "$MQG_REPO_ROOT/image/autoinstall"
            source_pin apple-installesd-10.9.5
            component_pin openssh
            ;;
        install)
            # Nothing of its own. See STAGE_NAMES above.
            : ;;
        *)
            die "no such stage '$1'; stages are: $STAGE_NAMES" ;;
    esac
}

# The caller-supplied half: "<key>=<value>" becomes "<key>\t<value>", so it
# sorts and hashes exactly like everything else.
extra_list() {
    local e
    for e in ${extras[@]+"${extras[@]}"}; do
        printf '%s\t%s\n' "${e%%=*}" "${e#*=}"
    done
}

if [ -n "$stage" ]; then
    case " $STAGE_NAMES " in
        *" $stage "*) : ;;
        *) die "no such stage '$stage'; stages are: $STAGE_NAMES" ;;
    esac
    if [ "$list" -eq 1 ]; then
        { stage_list "$stage"; extra_list; } | LC_ALL=C sort
    else
        { stage_list "$stage"; extra_list; } | LC_ALL=C sort \
            | sha256sum | cut -d' ' -f1
    fi
elif [ "$list" -eq 1 ]; then
    ingredient_list | LC_ALL=C sort
else
    ingredient_list | LC_ALL=C sort | sha256sum | cut -d' ' -f1
fi
