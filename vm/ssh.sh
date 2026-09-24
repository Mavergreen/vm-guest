#!/usr/bin/env bash
# Open a shell in a running guest.
#
# spec: docs/superpowers/plans/2026-09-22-shipping-vmavs.md Task 5
#
# Twelve lines of flags that everyone currently retypes. Two of them are
# load-bearing and neither is obvious:
#
#   StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null -- every clone
#   of a golden regenerates its host keys, so the second clone fails with a
#   man-in-the-middle warning that is alarming and wrong.
#
#   IdentitiesOnly=yes -- a loaded agent offers every key it holds, and the
#   guest closes the connection on MaxAuthTries before reaching the one key
#   the image actually authorized.
#
# Defaults match image/build-image.sh's own (port 2222, user mavsuser --
# read from that script 2026-09-22, near its `ssh_port=`/`ssh_user=`
# defaults).
set -euo pipefail

MQG_REPO_ROOT=${MQG_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck disable=SC2034
MQG_LOG_PREFIX=ssh

# Same default as every other vm/*.sh (vm/run.sh, vm/clone.sh,
# vm/screenshot.sh) and image/build-image.sh itself.
MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}

port=2222
user=mavsuser
key=${MQG_SSH_KEY:-}
dry=0

while [ $# -gt 0 ]; do
    case $1 in
        --port) port=$2; shift ;;
        --user) user=$2; shift ;;
        --key)  key=$2; shift ;;
        --dry-run) dry=1 ;;
        --) shift; break ;;
        -h|--help)
            cat <<EOF
usage: vmavs ssh [--port N] [--user U] [--key PATH] [--dry-run] [-- <ssh args>]

  --port N     Host port forwarded to the guest's 22 (default: $port)
  --user U     Guest account (default: $user)
  --key PATH   PRIVATE key whose public half the image authorized.
               Default: \$MQG_SSH_KEY, else the private half of whatever
               public key image/build-image.sh's own resolve_ssh_key would
               have picked to authorize -- the first of \$HOME/.ssh/id_*.pub
               or \$MQG_IMAGE_DIR/keys/*.pub that has a private half beside
               it. Same search, same order, so this defaults to the key
               that is actually in the image rather than guessing.
  --dry-run    Print the ssh command line and exit. Connects to nothing.

Everything after -- is passed to ssh as-is (e.g. a remote command).
EOF
            exit 0 ;;
        *) die "unknown option: $1 (everything for ssh goes after --)" ;;
    esac
    shift
done

# Mirrors image/build-image.sh's resolve_ssh_key search, which is what
# picks the public key to AUTHORIZE in the image: $HOME/.ssh/id_*.pub, then
# $MQG_IMAGE_DIR/keys/*.pub (where --generate-ssh-key writes mqg_rsa.pub).
# That function looks for a PUBLIC key to hand the guest; this one needs
# the PRIVATE half to hand ssh, so each candidate is tried only if its
# private half (the same path with .pub stripped) is also there.
if [ -z "$key" ]; then
    for pub in "$HOME"/.ssh/id_*.pub "$MQG_IMAGE_DIR"/keys/*.pub; do
        [ -f "$pub" ] || continue
        priv=${pub%.pub}
        [ -f "$priv" ] || continue
        key=$priv
        break
    done
fi
[ -n "$key" ] || die "no ssh key found; pass --key PATH (or set \$MQG_SSH_KEY)"
[ -e "$key" ] || die "no such key: $key"

set -- ssh -p "$port" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o LogLevel=ERROR \
    -i "$key" "$user@127.0.0.1" "$@"

if [ "$dry" = 1 ]; then printf '%s\n' "$*"; exit 0; fi
run_log "$*"
exec "$@"
