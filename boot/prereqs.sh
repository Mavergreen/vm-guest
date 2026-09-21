#!/usr/bin/env bash
# Report whether this host can build the boot stack and the installer
# media. Installs nothing.
#
# Installing host packages is a stop-and-ask in this project's design, so
# this script only reports. It prints the command a human could run, for
# whichever package manager it finds, and a human decides.
#
# Two things this script got wrong before 2026-09-20, both found by running
# it on a second host:
#
#   1. It named Debian packages only, and said so in a comment as though
#      that were a documentation problem. It is not: on an Arch host the
#      printed `apt install` line is not merely unhelpful, it is wrong
#      advice.
#   2. It checked the OpenCore build tools and nothing else, so on
#      `squirrel-zapper` it reported three missing tools when six were
#      missing. The media path needs `dmg2img`, `kpartx` and
#      `mkfs.hfsplus`, and a script called "prereqs" that omits half the
#      prerequisites is worse than one that does not exist, because it
#      answers the question wrongly instead of not answering it.
#
# Package names are recorded as FACTS, with their provenance: a name is
# listed only where someone has confirmed it on a real host, and `?`
# everywhere else. A guessed package name that turns out to be wrong costs
# more than an honest blank, because the reader cannot tell which they are
# looking at. See `docs/triangulation/` for where each confirmation
# happened.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# tool|debian|arch|homebrew|pkgsrc
#
# `?` means nobody has confirmed a name for that manager yet. `-` means the
# tool is in the base system there and needs no package.
#
# Confirmed:
#   debian   -- primary host, Linux Mint 22.3, P0 onward
#   arch     -- squirrel-zapper, EndeavourOS, 2026-09-20 (user confirmed
#               every name below existed; dmg2img and hfsprogs came from
#               the AUR rather than the official repositories; `busybox`
#               installed there by pacman the same day. `cpio` was already
#               present on that host, so nobody had to name its package --
#               hence the `?`)
#   debian   -- xxd and bats confirmed missing on ap-juicer 2026-09-21,
#               which is how the two-list drift below was noticed
#
# THIS LIST MUST COVER EVERY `require_cmd` IN THE REPOSITORY, and must
# agree with bin/triangulate.sh's. There were THREE lists, not two, and
# the third is the one that matters: the build scripts declare what they
# need with `require_cmd`, and on 2026-09-21 ap-juicer stopped at
# `missing required command: zip` -- a tool neither this script nor
# triangulate.sh had ever checked. Fixing the drift between two lists
# while a third went unread is why that host burned a run to find out.
# tests/boot_scripts.bats now derives the set from the source and fails
# if anything here is missing, so the declarations are the authority and
# this table is the lookup.
#
# THIS LIST AND bin/triangulate.sh's MUST AGREE. They did not until
# 2026-09-21: triangulate checked xxd, bats, rsync, openssl, curl and
# unzip, which this script had never heard of, so a host asking "what am I
# missing?" got a shorter answer than the truth. A prerequisites script
# that under-reports is worse than none, because it answers wrongly rather
# than not answering. tests/boot_scripts.bats asserts the two agree.
#
# busybox and cpio are here because the media build needs them, not the
# boot stack: lib/privops-qemu-linux.sh builds a busybox initramfs with
# cpio to do the one privileged step (restoring root ownership) inside a
# QEMU microVM. They were missing from this table until a host got all the
# way through a 6.4 GB media build and stopped on the last step for want of
# them, which is exactly the question this script exists to answer in
# advance. THE DEBIAN NAME IS `busybox-static`, NOT `busybox`: the
# initramfs holds one binary and no loader, so a dynamically linked busybox
# builds a perfectly good archive that then cannot exec. Debian ships both;
# the check that tells them apart is in lib/privops-qemu-linux.sh, which is
# where the requirement is, but this script is where someone reads it
# first.
REQUIRED='
gcc|build-essential|gcc|-|-
make|build-essential|make|-|-
git|git|git|git|scmgit
python3|python3|python|python3|python311
nasm|nasm|nasm|nasm|nasm
iasl|acpica-tools|acpica|acpica|acpica-utils
mcopy|mtools|mtools|mtools|mtools
mformat|mtools|mtools|mtools|mtools
sgdisk|gdisk|gptfdisk|?|gptfdisk
dmg2img|dmg2img|dmg2img (AUR)|?|?
kpartx|kpartx|multipath-tools|?|?
mkfs.hfsplus|hfsprogs|hfsprogs (AUR)|?|?
busybox|busybox-static|busybox|?|?
cpio|cpio|?|-|?
xxd|xxd|?|-|?
zip|zip|zip|-|zip
7z|?|?|?|?
udisksctl|udisks2|udisks2|?|?
qemu-img|qemu-utils|qemu-img|?|qemu
ssh|openssh-client|openssh|-|openssh
ssh-keygen|openssh-client|openssh|-|openssh
tar|-|-|-|-
mdir|mtools|mtools|mtools|mtools
mmd|mtools|mtools|mtools|mtools
losetup|-|-|?|?
lsblk|-|-|?|?
findmnt|-|-|?|?
awk|-|-|-|-
dd|-|-|-|-
find|-|-|-|-
head|-|-|-|-
od|-|-|-|-
sort|-|-|-|-
tail|-|-|-|-
tr|-|-|-|-
truncate|-|-|-|-
sha256sum|-|-|?|?
bats|bats|?|?|?
rsync|rsync|rsync|-|rsync
openssl|openssl|openssl|-|openssl
curl|curl|curl|-|curl
unzip|unzip|unzip|-|unzip
'

# Which package manager to name. Detected from the host, and overridable
# with MQG_PKG_MANAGER.
#
# The override is not a convenience. Detection reads $PATH, so without it
# this script's output depends on undeclared environment: a test that
# controls PATH -- which any honest test of a "is this tool present" script
# must do -- silently changes which package names come out. That made the
# behaviour untestable and the failure look like a bug in the assertion
# rather than in the design.
mgr=${MQG_PKG_MANAGER:-}
if [ -z "$mgr" ]; then
    case "$(uname -s)" in
        Darwin) mgr=brew ;;
        NetBSD) mgr=pkgin ;;
        *)
            if command -v pacman >/dev/null 2>&1; then
                mgr=pacman
            elif command -v apt >/dev/null 2>&1; then
                mgr=apt
            else
                mgr=unknown
            fi
            ;;
    esac
fi

case "$mgr" in
    apt)    native_col=2; mgr_name=apt;     mgr_cmd="sudo apt install" ;;
    pacman) native_col=3; mgr_name=pacman;  mgr_cmd="sudo pacman -S" ;;
    brew)   native_col=4; mgr_name=brew;    mgr_cmd="brew install" ;;
    pkgin)  native_col=5; mgr_name=pkgin;   mgr_cmd="pkgin install" ;;
    *)      native_col=0; mgr_name=unknown; mgr_cmd="" ;;
esac

missing_pkgs=""
missing_any=0
unknown_any=0

while IFS='|' read -r tool deb arch brew pkgsrc; do
    [ -n "$tool" ] || continue
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'PASS  %-13s %s\n' "$tool" "$(command -v "$tool")"
        continue
    fi
    missing_any=1
    case "$native_col" in
        2) pkg=$deb ;;
        3) pkg=$arch ;;
        4) pkg=$brew ;;
        5) pkg=$pkgsrc ;;
        *) pkg='?' ;;
    esac
    case "$pkg" in
        '?'|'')
            printf 'MISS  %-13s (no package name confirmed for %s)\n' \
                "$tool" "$mgr_name"
            unknown_any=1
            ;;
        '-')
            printf 'MISS  %-13s (expected in the base system here)\n' "$tool"
            unknown_any=1
            ;;
        *)
            printf 'MISS  %-13s (%s: %s)\n' "$tool" "$mgr_name" "$pkg"
            # bash 3.2: no associative arrays, and a space-delimited string
            # is enough for a dozen entries. See bin/bash32-check.sh.
            case " $missing_pkgs " in
                *" $pkg "*) ;;
                *) missing_pkgs="$missing_pkgs $pkg" ;;
            esac
            ;;
    esac
done <<EOF
$REQUIRED
EOF

echo
if [ "$missing_any" -eq 0 ]; then
    log "build prerequisites: all present"
    exit 0
fi

warn "missing build prerequisites"
warn "this script does not install anything -- that is a decision for a human"

if [ -n "$missing_pkgs" ] && [ -n "$mgr_cmd" ]; then
    # shellcheck disable=SC2086
    printf '\n    %s%s\n\n' "$mgr_cmd" "$missing_pkgs"
fi

if [ "$unknown_any" -eq 1 ]; then
    warn "some names are unconfirmed on this platform -- find them, then add"
    warn "them to REQUIRED in this file and note the host in docs/triangulation/"
fi

exit 1
