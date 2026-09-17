#!/usr/bin/env bash
# Fetch Apple's Mavericks InstallESD.dmg, SHA-256 verified.
#
# The OS comes from Apple and only from Apple. This talks to Apple's own
# servers -- osrecovery.apple.com for a download token, oscdn.apple.com for
# the 5 GB image -- using the handshake Mavericks Forever's get.sh works
# out. This is the download half of that script, through the checksum
# check and no further: the assembly half is hdiutil, macOS-only, and is
# what media/build-installer-img.sh replaces with Linux tools.
#
# Credit: <https://mavericksforever.com/get.sh>, by Wowfunhappy, with
# Krackers, Jazzzny and dosdude1. Read in full and transcribed on
# 2026-09-17; NOTES.md records the protocol as it stood then.
#
# The transfer is plain HTTP, by Apple's design -- the token is a cookie
# and the payload is unencrypted. The SHA-256 is therefore not a formality,
# it is the only thing standing between this pipeline and whatever a
# middlebox feels like serving. Verify BEFORE renaming into place: a
# partial or substituted download that becomes InstallESD.dmg anyway would
# poison every later task and surface as something inexplicable.
set -euo pipefail

# Pinned in two places on purpose: here, so --show-expected needs nothing
# but bash, and in vendor/sources.tsv, where every other third-party
# artifact is recorded. The fetch path checks they still agree.
INSTALLESD_SHA256=c861fd59e82bf777496809a0d2a9b58f66691ee56738031f55874a3fe1d7c3ff

# MQG_INSTALLESD_SHA256 and MQG_INSTALLESD_URL are testing seams: they let
# the suite exercise the verify-then-rename logic without a 5 GB download.
# Neither is meant for real use, and MQG_INSTALLESD_URL bypasses the Apple
# handshake entirely.
EXPECTED=${MQG_INSTALLESD_SHA256:-$INSTALLESD_SHA256}

if [ "${1:-}" = "--show-expected" ]; then
    printf '%s\n' "$EXPECTED"
    exit 0
fi

if [ $# -gt 0 ]; then
    printf 'usage: %s [--show-expected]\n' "$0" >&2
    exit 2
fi

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/vendor.sh
. "$MQG_REPO_ROOT/lib/vendor.sh"

# Checked before anything else touches the registry or the network, so a
# host without curl is told that rather than something further downstream.
require_cmd curl openssl xxd awk od tr head tail sha256sum

SOURCES=${MQG_SOURCES:-$MQG_REPO_ROOT/vendor/sources.tsv}
if [ -z "${MQG_INSTALLESD_SHA256:-}" ]; then
    recorded=$(source_field "$SOURCES" apple-installesd-10.9.5 sha256)
    [ "$recorded" = "$INSTALLESD_SHA256" ] \
        || die "this script pins $INSTALLESD_SHA256 but $SOURCES records" \
               "$recorded -- one of them is wrong; do not guess"
fi

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
dest_dir=$MQG_IMAGE_DIR/media
dest=$dest_dir/InstallESD.dmg
part=$dest.part

# Idempotent: an already-present, verified file is left exactly alone.
if [ -f "$dest" ]; then
    verify_sha256 "$dest" "$EXPECTED"
    log "InstallESD.dmg already present and verified"
    printf '%s\n' "$dest"
    exit 0
fi

mkdir -p "$dest_dir" || die "cannot create $dest_dir"

hex_to_bin() { printf '%s' "$1" | xxd -r -p; }
bin_to_hex() { od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]'; }

# Apple wants four things before it will hand over a download token:
#   1. a client id, random;
#   2. a server id, from osrecovery.apple.com, of the form <n>~<hex>;
#   3. the board serial number and board id of a Mavericks-era Mac;
#   4. a key: SHA-256 over the client id, the server id's hex half, that
#      Mac's boot ROM address, a SHA-256 of serial+board-id, and ten 0xCC
#      bytes of padding.
# The identifiers below come from get.sh, donated by dosdude1 from a broken
# Mac. They are not this machine's and are not secrets.
BOARD_SERIAL_NUMBER=C0243070168G3M91F
BOARD_ID=Mac-3CBD00234E554E41
ROM=003EE1E6AC14
ASSET_URL_EXPECTED='http://oscdn.apple.com/content/downloads/33/62/031-10295/gho4r94w66f5v4ujm0sz7k1m0hua68i6oo/OSInstaller/InstallESD.dmg'

fetch_asset_url_and_token() {
    local client_id server_id key payload
    client_id=$(head -c 8 /dev/urandom | bin_to_hex)

    # -c - dumps the cookie jar to stdout; the session cookie is the last
    # line's last field.
    server_id=$(curl -fsS --retry 3 -c - http://osrecovery.apple.com/ \
                | tail -n 1 | awk '{print $NF}') \
        || die "cannot reach osrecovery.apple.com for a session id"
    case $server_id in
        *'~'*) : ;;
        *) die "osrecovery.apple.com returned no usable session id" \
               "(got: ${server_id:-<nothing>})" ;;
    esac

    key=$( {
        hex_to_bin "$client_id"
        hex_to_bin "$(printf '%s' "$server_id" | awk -F'~' '{print $2}')"
        hex_to_bin "$ROM"
        printf '%s' "${BOARD_SERIAL_NUMBER}${BOARD_ID}" \
            | openssl dgst -sha256 -binary
        printf '\314\314\314\314\314\314\314\314\314\314'
    } | openssl dgst -sha256 -binary | bin_to_hex )

    payload=$(curl -fsS --retry 3 \
        'http://osrecovery.apple.com/InstallationPayload/OSInstaller' \
        -X POST \
        -H 'Content-Type: text/plain' \
        --cookie "session=$server_id" \
        -d "cid=$client_id
sn=$BOARD_SERIAL_NUMBER
bid=$BOARD_ID
k=$key") \
        || die "InstallationPayload request was refused"

    printf '%s\n' "$payload" | awk -F': ' '/^AU/{print $2} /^AT/{print $2}'
}

if [ -n "${MQG_INSTALLESD_URL:-}" ]; then
    warn "MQG_INSTALLESD_URL is set: fetching $MQG_INSTALLESD_URL, not Apple"
    rm -f "$part"
    curl -fsS --retry 3 -o "$part" "$MQG_INSTALLESD_URL" \
        || die "download failed from $MQG_INSTALLESD_URL"
else
    log "asking osrecovery.apple.com for a download token"
    asset_url=""
    asset_token=""
    while IFS= read -r line; do
        if [ -z "$asset_url" ]; then asset_url=$line; else asset_token=$line; fi
    done < <(fetch_asset_url_and_token)

    if [ -z "$asset_url" ] || [ -z "$asset_token" ]; then
        die "Apple's installation payload had no asset URL or token"
    fi
    # get.sh checks this too, and it is worth keeping: the same handshake
    # serves whatever OS Apple decides that board is entitled to, and
    # silently installing a different one would be a long afternoon.
    [ "$asset_url" = "$ASSET_URL_EXPECTED" ] \
        || die "Apple offered $asset_url, not the Mavericks InstallESD URL"

    log "downloading InstallESD.dmg (about 5.2 GB, over plain HTTP)"
    # Restart rather than resume. curl -C - into a partial file whose
    # contents we have never verified would resume into whatever is there,
    # and the checksum failure would arrive 5 GB later with no way to tell
    # a bad network from a bad resume.
    rm -f "$part"
    curl -f --progress-bar --retry 3 -o "$part" \
        -H "Cookie: AssetToken=$asset_token" "$asset_url" \
        || die "download failed; nothing was renamed into place"
fi

log "verifying"
# Dies on mismatch, leaving the .part where it is: the next run removes it,
# and in the meantime it can be looked at. What it does NOT do is become
# InstallESD.dmg.
verify_sha256 "$part" "$EXPECTED"

mv "$part" "$dest" || die "cannot move the verified download into place"
log "verified and installed at $dest"
printf '%s\n' "$dest"
