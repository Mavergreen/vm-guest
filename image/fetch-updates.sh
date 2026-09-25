#!/usr/bin/env bash
# Fetch Apple's post-10.9.5 updates that an image is asked to carry.
#
# WHY STANDALONE PACKAGES AND NOT `softwareupdate`
#
# `softwareupdate` reaches Apple's servers during the build. That makes the
# build non-reproducible (whatever Apple serves that day) and
# network-dependent at the wrong moment, and a 2013 OS negotiating with
# 2026 servers may simply hang. Every update this project installs is a
# standalone .pkg pinned in assets/pins/sources.tsv by checksum, exactly like
# every other ingredient. NEVER run `softwareupdate` at build time.
#
# WHAT EACH SELECTION IS
#
#   none      nothing. This is P5's performance baseline, and every
#             measurement compares against it, so it must stay exactly what
#             it was: this script fetches nothing and prints nothing.
#   security  Security Update 2016-004, the last one Apple shipped for
#             10.9. The default for images people actually run.
#   all       ...plus Safari 9.1.3 and iTunes 12.6.2. Opt-in, because those
#             are applications rather than the operating system.
#
# docs/open-questions.md Q1 is where that shape was chosen, and
# docs/decisions/0011-updates-in-the-default-image.md is the decision.
#
# ORDER IS PART OF THE ANSWER
#
# The list below is an INSTALL ORDER, not a set:
#
#   * Security Update 2016-004 replaces /usr/bin/ssh and /usr/sbin/sshd
#     (read out of its own Payload, not assumed), so it must go on BEFORE
#     the family's OpenSSH or it would undo it. image/payload/firstboot.sh
#     installs updates first for this reason.
#   * iTunes 12.6.2 is ONE softwareupdate product made of five flat
#     packages, and the order below is the order its own Packages array
#     gives. Apple's installer applies them in that order; so do we.
#
# WHY THE PACKAGES ARE RENAMED ON THE WAY OUT
#
# They ride to the guest on the installer media, in
# /System/Installation/Packages -- a directory that already holds Apple's
# OWN installer packages. `CoreFP.pkg` and `MobileDevice.pkg` are generic
# enough names that a collision there would be silent and would corrupt an
# install. So each one is presented under an `mqg-update-NN-` name, which
# also puts the install order in the filename where a human can read it.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/vendor.sh
. "$MQG_REPO_ROOT/lib/vendor.sh"

# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=fetch-updates

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
SOURCES=${MQG_SOURCES:-$MQG_REPO_ROOT/assets/pins/sources.tsv}

# The selections, as registry names in install order. One place, read by
# this script, by image/build-image.sh's stamp and by the tests -- a second
# copy of this list is a second thing to keep in step.
MQG_UPDATES_CHOICES="none security all"
MQG_UPDATES_SECURITY="apple-secupd-2016-004"
MQG_UPDATES_ALL="$MQG_UPDATES_SECURITY
apple-safari-9.1.3
apple-itunes-12.6.2-corefp
apple-itunes-12.6.2-mobiledevice
apple-itunes-12.6.2-itunesaccess
apple-itunes-12.6.2-itunesx
apple-itunes-12.6.2-coreadi"

# updates_sources <selection> -- the registry names, one per line, in
# install order. Empty for `none`, which is the whole point of `none`.
updates_sources() {
    case $1 in
        none)     : ;;
        security) printf '%s\n' "$MQG_UPDATES_SECURITY" ;;
        all)      printf '%s\n' "$MQG_UPDATES_ALL" ;;
        *) die "unknown updates selection '$1':" \
               "choose one of $MQG_UPDATES_CHOICES" ;;
    esac
}

usage() {
    cat <<EOF
usage: $(basename "$0") [--updates WHICH] [--names] [--describe] [--out DIR]

Fetch the post-10.9.5 updates for one --updates selection and verify each
against its pinned checksum. Prints one absolute path per line, in the
order the guest must install them. Prints nothing at all for "none".

  --updates WHICH  One of: $MQG_UPDATES_CHOICES (default: none)
  --names          Print the assets/pins/sources.tsv names instead of fetching.
                   Touches nothing and needs no network.
  --out DIR        Where to cache the packages
                   (default: \$MQG_IMAGE_DIR/updates)
  --describe       Print what would be fetched and exit. Touches nothing.

These are Apple's packages, fetched from Apple, pinned by checksum, and
never republished -- see README.md's ground rules and bin/no-apple-bytes.sh.
EOF
}

updates=none
names=0
describe=0
outdir=

while [ $# -gt 0 ]; do
    case $1 in
        --updates) updates=$2; shift ;;
        --names) names=1 ;;
        --out) outdir=$2; shift ;;
        --describe) describe=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

case " $MQG_UPDATES_CHOICES " in
    *" $updates "*) : ;;
    *) die "unknown --updates '$updates': choose one of $MQG_UPDATES_CHOICES" ;;
esac

outdir=${outdir:-$MQG_IMAGE_DIR/updates}
staged=$outdir/staged

if [ "$names" -eq 1 ]; then
    updates_sources "$updates"
    exit 0
fi

if [ "$describe" -eq 1 ]; then
    cat <<EOF
post-10.9.5 updates
  selection         $updates (choices: $MQG_UPDATES_CHOICES)
  registry          $SOURCES
  cache             $outdir
  presented as      $staged/mqg-update-NN-<name>.pkg
                    (NN is the install order; the rename also keeps these
                    from colliding with Apple's own packages in
                    /System/Installation/Packages on the media)
EOF
    if [ "$updates" = none ]; then
        cat <<EOF

  nothing is fetched and nothing is printed. "none" is P5's baseline and
  must stay bit-for-bit what it was before this switch grew a second value.
EOF
    else
        printf '\n  packages, in install order\n'
        n=0
        while IFS= read -r src; do
            [ -n "$src" ] || continue
            n=$((n + 1))
            printf '    %02d  %-34s %s\n' "$n" "$src" \
                "$(source_field "$SOURCES" "$src" url)"
        done <<EOF
$(updates_sources "$updates")
EOF
    fi
    exit 0
fi

if [ "$updates" = none ]; then
    log "--updates none: this image carries no post-10.9.5 updates"
    exit 0
fi

require_cmd curl sha256sum

mkdir -p "$staged" || die "cannot create $staged"
# Stale links from a previous, larger selection would otherwise sit here
# looking like part of this one. The cached packages underneath are kept:
# they are checksummed, and re-downloading 685 MB to change a switch back
# would be the wrong kind of careful.
rm -f "$staged"/mqg-update-*

n=0
while IFS= read -r src; do
    [ -n "$src" ] || continue
    n=$((n + 1))
    pkg=$(fetch_source "$SOURCES" "$src" "$outdir") \
        || die "cannot fetch update $src"
    [ "$(head -c 4 "$pkg")" = "xar!" ] \
        || die "$pkg is not a flat package (no xar magic)"
    link=$staged/$(printf 'mqg-update-%02d-%s' "$n" "$(basename "$pkg")")
    # A symlink, not a copy: `all` is 685 MB and the media build reads
    # through it with cp, which follows symlinks.
    ln -sfn "$pkg" "$link" || die "cannot link $link"
    printf '%s\n' "$link"
done <<EOF
$(updates_sources "$updates")
EOF

log "updates ($updates): $n package(s) verified against their pinned checksums"
