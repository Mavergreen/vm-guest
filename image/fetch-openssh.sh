#!/usr/bin/env bash
# Fetch the family's own OpenSSH for the guest.
#
# WHY THE GUEST NEEDS THIS
#
# Stock 10.9 ships OpenSSH 6.2p2. P4 found two consequences the hard way,
# and both are recorded as tests:
#
#   * Ed25519 arrived in OpenSSH 6.5, three months after Mavericks shipped.
#     An Ed25519 line in authorized_keys is a line 10.9's sshd cannot
#     parse, and the only symptom is "Permission denied (publickey)".
#   * 10.9's sshd offers ssh-rsa and ssh-dss host keys, both of which a
#     2026 client refuses outright.
#
# `Mavergreen/openssh` already solves this: it builds current OpenSSH
# for 10.9 and publishes two product archives per release.
#
#   OpenSSH-<version>.pkg                 installs under /usr/local,
#                                         overwrites nothing
#   OpenSSH-System-Replace-<version>.pkg  symlinks the system paths at it,
#                                         so /usr/bin/ssh and the launchd
#                                         sshd job use the modern build
#
# A headless guest, whose entire interface is SSH, wants both.
#
# THE PIN IS A FILE, NOT AN ARGUMENT
#
# components/openssh/version holds the release tag, so Renovate can bump
# it (see renovate.json) and so INGREDIENTS.md has something to point at.
#
# WHY THE ASSET NAMES ARE READ RATHER THAN CONSTRUCTED
#
# The family has already been bitten by this: golang's cross .pkg was
# renamed go126- -> golang- mid-line, and every consumer that built its
# download URL from a hardcoded prefix started 404ing across the bump.
# So we do not construct names. We fetch the pinned release's SHA256SUMS
# -- which is the release's own statement of what it published -- take the
# .pkg names out of it, and verify each download against the checksum on
# the same line. A renamed prefix changes both halves together and nothing
# here notices.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=fetch-openssh

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}

# The repository the packages come from. A variable so the tests can point
# the download at a local fixture instead of the network.
OPENSSH_REPO=${MQG_OPENSSH_REPO:-Mavergreen/openssh}
OPENSSH_BASE_URL=${MQG_OPENSSH_BASE_URL:-https://github.com/$OPENSSH_REPO/releases/download}

PIN_FILE=$MQG_REPO_ROOT/components/openssh/version

describe=0
outdir=

usage() {
    cat <<EOF
usage: $(basename "$0") [--describe] [--out DIR]

Fetch the OpenSSH packages pinned in components/openssh/version and verify
them against the release's own SHA256SUMS. Prints one path per line: the
base package first, then the system-replacement package.

  --out DIR    Where to cache the packages
               (default: \$MQG_IMAGE_DIR/openssh/<tag>)
  --describe   Print what would be fetched and exit. Touches nothing.

Environment:
  MQG_OPENSSH_REPO      owner/name to fetch from (default: $OPENSSH_REPO)
  MQG_OPENSSH_BASE_URL  release download base URL, for tests
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --out) outdir=$2; shift ;;
        --describe) describe=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

# openssh_pin -- the tag in components/openssh/version, with comments and
# blank lines ignored so the file can grow a header without breaking this.
openssh_pin() {
    [ -f "$PIN_FILE" ] || die "no pin file at $PIN_FILE"
    local tag
    tag=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PIN_FILE" \
        | grep -v '^$' | head -1)
    [ -n "$tag" ] || die "$PIN_FILE names no release tag"
    printf '%s\n' "$tag"
}

tag=$(openssh_pin)
outdir=${outdir:-$MQG_IMAGE_DIR/openssh/$tag}
release_url=$OPENSSH_BASE_URL/$tag

if [ "$describe" -eq 1 ]; then
    cat <<EOF
guest OpenSSH
  repository        $OPENSSH_REPO
  pinned tag        $tag
                    (components/openssh/version -- Renovate bumps it)
  release           $release_url
  cache             $outdir

  fetched           SHA256SUMS, then every *.pkg it names
  verified          against the checksum on the same SHA256SUMS line
  classified        a name containing "System-Replace" is the replacement
                    package; the other .pkg is the base package. Nothing
                    here constructs an asset name from a prefix, so a
                    renamed prefix cannot 404 across a pin bump.
EOF
    exit 0
fi

require_cmd curl sha256sum

mkdir -p "$outdir" || die "cannot create $outdir"

sums=$outdir/SHA256SUMS
if [ ! -s "$sums" ]; then
    log "fetching SHA256SUMS for $tag"
    curl -fSL --retry 3 -o "$sums.part" "$release_url/SHA256SUMS" \
        || die "cannot fetch $release_url/SHA256SUMS --" \
               "is $tag a real release of $OPENSSH_REPO?"
    mv "$sums.part" "$sums" || die "cannot move SHA256SUMS into place"
fi

# Classify by SUFFIX and CONTENT, never by a leading prefix. "Everything
# that ends in .pkg, and the one whose name says System-Replace is the
# replacement" survives a rename of the leading "OpenSSH-"; "the file
# called OpenSSH-$tag.pkg" does not.
base_name=
replace_name=
while read -r _ file; do
    [ -n "${file:-}" ] || continue
    case $file in
        *.pkg) : ;;
        *) continue ;;
    esac
    case $file in
        *System-Replace*|*system-replace*)
            [ -z "$replace_name" ] \
                || die "two replacement packages in SHA256SUMS:" \
                       "$replace_name and $file"
            replace_name=$file ;;
        *)
            [ -z "$base_name" ] \
                || die "two base packages in SHA256SUMS:" \
                       "$base_name and $file"
            base_name=$file ;;
    esac
done < "$sums"

[ -n "$base_name" ] \
    || die "no base .pkg named in $sums -- release $tag looks wrong"
[ -n "$replace_name" ] \
    || die "no System-Replace .pkg named in $sums -- release $tag looks wrong"

# fetch_asset <name> -- download it if absent, then verify it against the
# checksum SHA256SUMS gives for that exact name.
fetch_asset() {
    local name=$1 dest want
    dest=$outdir/$name
    want=$(awk -v n="$name" '$2 == n { print $1; exit }' "$sums")
    [ -n "$want" ] || die "$sums has no checksum for $name"
    if [ ! -f "$dest" ]; then
        log "fetching $name"
        curl -fSL --retry 3 -o "$dest.part" "$release_url/$name" \
            || die "download failed for $name"
        mv "$dest.part" "$dest" || die "cannot move $name into place"
    fi
    verify_sha256 "$dest" "$want"
    [ "$(head -c 4 "$dest")" = "xar!" ] \
        || die "$dest is not a flat package (no xar magic)"
    printf '%s\n' "$dest"
}

base_pkg=$(fetch_asset "$base_name")
replace_pkg=$(fetch_asset "$replace_name")

log "OpenSSH $tag verified: $base_name, $replace_name"
printf '%s\n' "$base_pkg" "$replace_pkg"
