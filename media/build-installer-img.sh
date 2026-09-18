#!/usr/bin/env bash
# Build bootable Mavericks installer media on Linux, from Apple's own
# InstallESD.dmg, with no Mac and no root.
#
# The recipe is eprigorodov/mkosxinstallusb's, with two changes: it targets
# an image file rather than /dev/sdX, and every privileged step has an
# unprivileged equivalent (see lib/hfs.sh and the P4 entries in NOTES.md).
# What comes out is what the Mac-produced reference ISO contains --
# media/verify-installer-img.sh is how we find out whether that is true,
# and a finished rsync on its own proves nothing.
#
#   1. dmg2img InstallESD.dmg, mount it.
#   2. dmg2img the BaseSystem.dmg inside it, mount that too.
#   3. Create a GPT image with one AF00 partition holding an "OS X Base
#      System" volume, sized from the reference.
#   4. rsync BaseSystem onto it.
#   5. Replace System/Installation/Packages -- a symlink into the ESD
#      volume, dangling on media that has no ESD volume -- with the ESD's
#      real Packages directory, plus BaseSystem.chunklist and
#      BaseSystem.dmg, which the installer verifies the packages against.
#   6. With --autoinstall, add the three files Apple's own /etc/rc.install
#      looks for, which turn a boot of this media into an install that
#      needs nobody watching. See image/autoinstall/.
#
# Ownership: udisks mounts hfsplus with uid=<you>,gid=<you>,umask=22, so
# nothing written here can be owned by root or carry a setuid bit, whatever
# flags rsync is given. Whether the installer cares is the open question a
# boot answers; it runs as root and may rebuild what it needs. Not worked
# around here on purpose -- see NOTES.md.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/hfs.sh
. "$MQG_REPO_ROOT/lib/hfs.sh"
# shellcheck source=../lib/privops.sh
. "$MQG_REPO_ROOT/lib/privops.sh"
# shellcheck source=../lib/privops-qemu-linux.sh
. "$MQG_REPO_ROOT/lib/privops-qemu-linux.sh"

# The size the Mac-produced reference's HFS+ partition actually is, which
# is the number get.sh's `hdiutil resize` asks for. Measured, not guessed:
# `7z l InstallMavericks.iso` reports Physical Size = 6550020096 for the
# "disk image.hfs" it contains. HFS+ has to fill its partition exactly (the
# kernel reads the alternate volume header from the end of the device), and
# mkfs works in whole MiB, so we round up -- 925,696 bytes of slack over
# the reference, which is the smallest amount we can have.
REFERENCE_PARTITION_BYTES=6550020096

# ...plus a margin, because the reference size does not fit a Linux-built
# copy of the same files. Measured, on the build that ran out of space 17
# MB into BaseSystem.dmg: the same content costs about 153 MB of HFS+
# metadata and per-file slack here against about 105 MB on the Mac, and
# hdiutil had packed the reference down to 30 MB of free space. The extra
# is in the catalog: same files, different B-tree. 128 MiB is the next
# round number that leaves real room rather than another cliff edge.
#
# The reference is still what the size is *derived* from. Nothing about
# the media requires the two to be the same size -- a QEMU disk is not a
# USB stick someone has to buy -- but a number picked out of the air would
# have been a guess at whether the packages fit, which is the one thing
# this must not be.
MARGIN_MIB=128
PART_MIB=$(( (REFERENCE_PARTITION_BYTES + 1048575) / 1048576 + MARGIN_MIB ))

VOLUME_NAME="OS X Base System"

# The unattended-install hooks, as "<source under image/autoinstall/>
# <destination on the media> <mode>". All three are Apple's own mechanism,
# not ours: /etc/rc.install sources rc.cdrom.local (line 39), reads
# Extras/minstallconfig.xml (line 104) and prefers OSInstall.collection
# over OSInstall.mpkg (lines 107-108). See image/autoinstall/ and the P4
# Task 5 entry in NOTES.md.
#
# rc.cdrom.local must be executable -- rc.install tests it with `[ -x ]`
# and silently skips it otherwise, which would leave the media booting to
# an automated installer with no target volume prepared.
AUTOINSTALL_FILES="\
autoinstall.sh|private/etc/rc.cdrom.local|755
minstallconfig.xml|System/Installation/Packages/Extras/minstallconfig.xml|644
OSInstall.collection|System/Installation/Packages/OSInstall.collection|644"

usage() {
    cat <<EOF
usage: $(basename "$0") [--describe] [--force] [--keep-work] [--autoinstall]

  --describe     Print the layout this would create and exit. Touches nothing.
  --force        Replace an existing installer image.
  --keep-work    Keep the multi-gigabyte raw conversions afterwards.
  --autoinstall  Inject the unattended-install hooks (image/autoinstall/),
                 so booting this media installs without anyone watching.
EOF
}

describe=0
force=0
keep_work=0
autoinstall=0
while [ $# -gt 0 ]; do
    case $1 in
        --describe) describe=1 ;;
        --force) force=1 ;;
        --keep-work) keep_work=1 ;;
        --autoinstall) autoinstall=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
media_dir=$MQG_IMAGE_DIR/media
esd_dmg=$media_dir/InstallESD.dmg
out=$media_dir/installer-linux.img
work=${MQG_MEDIA_WORK_DIR:-$media_dir/work}
esd_img=$work/esd.img
bs_img=$work/basesystem.img

if [ "$describe" -eq 1 ]; then
    cat <<EOF
installer media layout
  output              $out
  source              $esd_dmg
  work area           $work

  partition table     GPT, one partition
  partition 1 type    AF00 (Apple HFS+)
  partition 1 start   sector 2048 (1 MiB)
  partition 1 size    $PART_MIB MiB = $((PART_MIB * 1048576)) bytes
                      (the reference's is $REFERENCE_PARTITION_BYTES bytes,
                      rounded up to whole MiB -- HFS+ must fill its
                      partition exactly -- plus a $MARGIN_MIB MiB margin
                      for the larger catalog a Linux-built copy needs)
  disk size           $((PART_MIB + 2)) MiB = $(((PART_MIB + 2) * 1048576)) bytes
  volume name         $VOLUME_NAME

  contents
    everything in the ESD's BaseSystem.dmg, then
    System/Installation/Packages/     <- the ESD's real Packages directory,
                                        replacing a symlink that dangles
                                        once the ESD volume is gone
    System/Installation/BaseSystem.dmg
    System/Installation/BaseSystem.chunklist
EOF
    if [ "$autoinstall" -eq 1 ]; then
        cat <<EOF

  unattended-install hooks (--autoinstall)
EOF
        printf '%s\n' "$AUTOINSTALL_FILES" | while IFS='|' read -r src dst mode; do
            printf '    %-46s mode %s\n' "$dst" "$mode"
            printf '      from image/autoinstall/%s\n' "$src"
        done
        cat <<EOF

    All three are read by Apple's own /etc/rc.install, which is already on
    this media. They land root-owned like everything else, via the privops
    microVM -- launchd and the installer both refuse what they do not
    trust.
EOF
    fi
    exit 0
fi

require_cmd dmg2img sgdisk rsync truncate dd mkfs.hfsplus udisksctl \
    losetup findmnt lsblk du df sha256sum

[ -f "$esd_dmg" ] || die "no InstallESD.dmg at $esd_dmg --" \
    "run media/fetch-installesd.sh first"

if [ -e "$out" ]; then
    [ "$force" -eq 1 ] || die "$out exists; pass --force to replace it"
    log "--force: removing the existing $out"
    rm -f "$out" "$out.sha256"
fi

mkdir -p "$work" || die "cannot create $work"

# Intermediates are regenerated every run rather than reused. They are
# cheap (seconds) next to a stale or half-written one silently becoming the
# media we then spend an hour booting.
rm -f "$esd_img" "$bs_img" "$out.hfs-tmp"

ESD_MNT=
BS_MNT=

# Counted before and after the copy, and logged. An rsync that silently
# copies nothing looks exactly like an rsync that worked, until something
# downstream fails for a reason that makes no sense.
count_tree() {
    local where=$1 what=$2 n bytes
    n=$(find "$where" -mindepth 1 | wc -l)
    bytes=$(du -sb "$where" | cut -f1)
    log "$what: $n entries, $bytes bytes"
}

# BaseSystem has one file we are not allowed to read: /.file, mode 0000,
# the marker OS X looks for to decide a volume has a filesystem on it. Root
# could read it; we cannot, and rsync fails the whole transfer over it.
# It is empty, so there is nothing in it to read -- what matters is that a
# file of that name and mode exists. Copy the metadata by hand and keep the
# transfer itself clean, so a genuine rsync failure still means something.
#
# Any *non-empty* unreadable file would be a different story: that would be
# content we cannot copy without root, and a finding rather than a detail.
# Hence the size check.
unreadable_files() {
    find "$1" -type f ! -readable -printf '%P\0'
}

recreate_unreadable() {
    local src=$1 dst=$2 rel
    while IFS= read -r -d '' rel; do
        log "recreating unreadable (mode $(stat -c %a "$src/$rel")) empty file: $rel"
        : > "$dst/$rel" || die "cannot create $dst/$rel"
        touch -r "$src/$rel" "$dst/$rel"
        chmod "$(stat -c %a "$src/$rel")" "$dst/$rel"
    done < <(unreadable_files "$src")
}

populate_target() {
    local tgt=$1 pkg_link=$1/System/Installation/Packages
    local rel
    local -a excludes=()
    while IFS= read -r -d '' rel; do
        [ "$(stat -c %s "$BS_MNT/$rel")" -eq 0 ] \
            || die "$BS_MNT/$rel is unreadable and not empty:" \
                   "copying it would need root"
        excludes+=( "--exclude=/$rel" )
    done < <(unreadable_files "$BS_MNT")

    log "copying BaseSystem onto the target volume"
    # -a without -o/-g: udisks mounts this filesystem uid=<us>,gid=<us>, so
    # preserving ownership is not on offer and asking for it only produces
    # errors. -H matters -- BaseSystem hardlinks several binaries, and
    # without it each one is copied again, which this volume has no room
    # for. No -X: the Linux hfsplus driver exposes no extended attributes
    # at all (getfattr on the source returns nothing), so there is nothing
    # for rsync to carry.
    rsync -rlptDH --info=stats2 "${excludes[@]}" "$BS_MNT/" "$tgt/" >&2 \
        || die "rsync of BaseSystem failed"
    recreate_unreadable "$BS_MNT" "$tgt"
    count_tree "$tgt" "after BaseSystem"

    # On the ESD this is a symlink to /System/Installation/PackagesLink,
    # which resolves through the ESD volume. On installer media there is no
    # ESD volume, so the real directory goes here instead.
    [ -L "$pkg_link" ] || die "expected a Packages symlink at $pkg_link"
    log "replacing the Packages symlink with the ESD's real Packages"
    rm -f "$pkg_link"
    rsync -rlptDH --info=stats2 "$ESD_MNT/Packages/" "$pkg_link/" >&2 \
        || die "rsync of Packages failed"

    log "copying BaseSystem.dmg and BaseSystem.chunklist"
    rsync -rlptDH "$ESD_MNT/BaseSystem.dmg" "$ESD_MNT/BaseSystem.chunklist" \
        "$tgt/System/Installation/" \
        || die "could not copy BaseSystem.dmg/chunklist"

    [ "$autoinstall" -eq 0 ] || inject_autoinstall "$tgt"

    count_tree "$tgt" "final volume"
    log "free space on the target volume:"
    df -h "$tgt" >&2
}

# The unattended-install hooks go on while the volume is already mounted
# here, rather than in a pass of their own. That is not only cheaper: the
# chown that follows (fix_media_ownership) is what makes them root-owned,
# and anything injected after it would be the one uid-1000 file on
# otherwise root-owned media -- exactly the state that made launchd say
# "Dubious ownership on file (skipping)" and load nothing at all.
inject_autoinstall() {
    local tgt=$1 src dst mode
    log "injecting the unattended-install hooks"
    while IFS='|' read -r src dst mode; do
        [ -n "$src" ] || continue
        [ -f "$MQG_REPO_ROOT/image/autoinstall/$src" ] \
            || die "missing image/autoinstall/$src"
        mkdir -p "$(dirname "$tgt/$dst")" || die "cannot create $(dirname "$dst")"
        cp "$MQG_REPO_ROOT/image/autoinstall/$src" "$tgt/$dst" \
            || die "cannot write $dst"
        chmod "$mode" "$tgt/$dst" || die "cannot chmod $mode $dst"
        log "  $dst ($(stat -c %a "$tgt/$dst"), $(stat -c %s "$tgt/$dst") bytes)"
    done <<< "$AUTOINSTALL_FILES"
}

# Everything above ran unprivileged, so the media is owned by the building
# user and launchd would reject it. Fix that in a QEMU microVM, where we are
# genuinely root -- see lib/privops.sh for why that is the mechanism and
# what a different build host would substitute.
fix_media_ownership() {
    local img=$1
    log "restoring root ownership (privops backend: ${MQG_PRIVOPS_BACKEND:-qemu-linux})"
    privops_run "$img" "$MQG_REPO_ROOT/media/privops/fix-ownership.sh"
}


with_basesystem() {
    BS_MNT=$1
    log "BaseSystem volume mounted at $BS_MNT"
    count_tree "$BS_MNT" "BaseSystem source"

    log "creating $out: GPT, one AF00 partition, $PART_MIB MiB, \"$VOLUME_NAME\""
    hfs_create_gpt "$out" "$PART_MIB" "$VOLUME_NAME"
    hfs_with_mounted_part "$out" 1 populate_target
}

with_esd() {
    ESD_MNT=$1
    log "ESD volume mounted at $ESD_MNT"
    [ -f "$ESD_MNT/BaseSystem.dmg" ] \
        || die "no BaseSystem.dmg on the ESD volume at $ESD_MNT"
    log "converting BaseSystem.dmg to raw"
    dmg2img -s -i "$ESD_MNT/BaseSystem.dmg" -o "$bs_img" >/dev/null \
        || die "dmg2img failed on BaseSystem.dmg"
    log "BaseSystem raw image: $(stat -c %s "$bs_img") bytes"
    hfs_with_mounted_part "$bs_img" auto with_basesystem
}

started=$SECONDS
log "converting InstallESD.dmg to raw (about 5 GB)"
dmg2img -s -i "$esd_dmg" -o "$esd_img" >/dev/null \
    || die "dmg2img failed on $esd_dmg"
log "ESD raw image: $(stat -c %s "$esd_img") bytes"

hfs_with_mounted_part "$esd_img" auto with_esd

sync
fix_media_ownership "$out"

log "checksumming $out"
# Ownership must be fixed BEFORE the checksum is taken: the microVM mounts
# the image, and mounting an HFS+ volume rewrites its header. Checksumming
# first would record a value that the very next step invalidates.
sum=$(sha256_file "$out")
# Recorded with its expiry date attached. udisks mounts HFS+ read-write,
# and the kernel updates the volume header's modify time and last-mounted
# version on the way in, so the first mount after this changes the file and
# the checksum stops matching. That is a property of the media, not a
# corruption, and someone running `sha256sum -c` at the wrong moment should
# find that written down rather than have to work it out. (sha256sum
# ignores lines beginning with #.)
{
    printf '# sha256 of %s as built at %s\n' \
        "$(basename "$out")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Mounting the image invalidates this: HFS+ records the mount\n'
    printf '# in its volume header, and udisks will only mount read-write.\n'
    printf '%s  %s\n' "$sum" "$(basename "$out")"
} > "$out.sha256"

if [ "$keep_work" -eq 0 ]; then
    log "removing the raw conversions (--keep-work keeps them)"
    rm -f "$esd_img" "$bs_img"
    rmdir "$work" 2>/dev/null || true
fi

log "built $out in $((SECONDS - started))s"
log "size $(stat -c %s "$out") bytes, sha256 $sum"
run_log "build-installer-img: $out $(stat -c %s "$out") bytes sha256=$sum" \
    "in $((SECONDS - started))s"
printf '%s\n' "$out"
