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
# shellcheck source=../lib/sshkey.sh
. "$MQG_REPO_ROOT/lib/sshkey.sh"
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
        # Guarded the way emit/packer.sh guards its own: without it, a
        # trailing --port died with bash's "$2: unbound variable".
        --port) [ $# -ge 2 ] || die "--port needs a value"; port=$2; shift ;;
        --user) [ $# -ge 2 ] || die "--user needs a value"; user=$2; shift ;;
        --key)  [ $# -ge 2 ] || die "--key needs a value"; key=$2; shift ;;
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
               have picked to authorize (lib/sshkey.sh's sshkey_find --
               the same function, so this can never pick a different key
               than the one actually in the image). Dies naming the
               public key if its private half is not beside it.
  --dry-run    Print the ssh command line and exit. Connects to nothing.

Everything after -- is passed to ssh as-is (e.g. a remote command).
EOF
            exit 0 ;;
        *) die "unknown option: $1 (everything for ssh goes after --)" ;;
    esac
    shift
done

# lib/sshkey.sh's sshkey_find is the SAME search image/build-image.sh's
# own resolve_ssh_key uses to pick the public key it AUTHORIZES in the
# image -- one function, shared, so this can never quietly drift from
# what the image actually accepts. That function returns a PUBLIC key;
# this needs the PRIVATE half to hand ssh, so the candidate is used only
# if its private half (the same path with .pub stripped) is also there.
if [ -z "$key" ]; then
    pub=$(sshkey_find) || pub=
    if [ -n "$pub" ]; then
        priv=${pub%.pub}
        # sshkey_find returns exactly the key resolve_ssh_key would have
        # authorized, and only that one -- not a different candidate that
        # merely happens to have a private half. A public key with no
        # private half beside it is a real problem to report, not one to
        # paper over by silently trying something the image never got.
        [ -f "$priv" ] || die "the image's authorized key is $pub, but its" \
            "private half ($priv) is not there. Pass --key PATH for a" \
            "different key."
        key=$priv
    fi
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
