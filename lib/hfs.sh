# shellcheck shell=bash
# Unprivileged HFS+ image handling.
#
# The design assumed this needed sudo for losetup and mount. It does not:
# mkfs.hfsplus operates on a plain file, and udisks2 provides loop devices
# and mounts to a desktop user without a password, auto-loading the hfsplus
# module. See the P4 entries in NOTES.md.
#
# THE MEDIA BUILD NO LONGER USES THE LOOP-AND-MOUNT HALF OF THIS FILE, and
# that is not an oversight to be tidied up by wiring it back in. udisks2
# grants `loop-setup` to a user AT A SEAT, so an SSH session to a headless
# host is refused -- see G26 in docs/host-profile.md.
# media/build-installer-img.sh does the whole HFS+ assembly inside the
# privops microVM instead, and calls only hfs_create_gpt here, which writes
# a plain file with mkfs.hfsplus, sgdisk and dd and needs no privilege and
# no mount at all.
#
# What still attaches and mounts: media/content-digest.sh, a by-hand
# comparison tool no pipeline stage calls, and tests/hfs.bats. Both
# therefore still need a seat. Anything NEW that wants to read or write an
# HFS+ volume should take a payload to privops_run rather than come here.
#
# Everything here reports the *observed* state rather than trusting
# udisksctl's exit status, because udisksctl lies in both directions:
# `loop-delete` on a still-mounted device returns 0 and does not detach,
# and after a successful unmount it can return NotAuthorized for a device
# that has already gone away. Measured, not assumed -- see NOTES.md.
#
# Requires lib/common.sh.

# How long to wait for an asynchronous udisks operation to show up in the
# kernel's view of the world, in tenths of a second.
HFS_SETTLE_TRIES=${HFS_SETTLE_TRIES:-30}

hfs_create() {
    local img=$1 mib=$2 volname=$3
    [ ! -e "$img" ] || die "image already exists: $img"
    require_cmd mkfs.hfsplus truncate
    truncate -s "${mib}M" "$img" || die "cannot create $img"
    # A sparse file, and mkfs.hfsplus only writes metadata: a 6.55 GB
    # volume takes well under a second and 21 MB of disk.
    mkfs.hfsplus -v "$volname" "$img" >/dev/null \
        || die "mkfs.hfsplus failed on $img"
}

# hfs_create_gpt <img> <mib> <volname>
#
# A GPT disk image with exactly one AF00 (Apple HFS+) partition, aligned at
# 1 MiB, holding an HFS+ volume of <mib> MiB that fills that partition
# exactly. Two details are not optional:
#
#   * The volume must be the same size as the partition. The kernel looks
#     for the alternate volume header in the last 1024 bytes of the *block
#     device*, so a volume one megabyte short of its partition mounts as
#     "invalid secondary volume header / unable to find HFS+ superblock".
#     Measured, on exactly that mistake.
#   * mkfs.hfsplus cannot write at an offset into a file, and a loop
#     partition device is root:disk 0660 -- udisks hands us the loop
#     device but not write access to the raw partition, so formatting it
#     in place is not available unprivileged. So: format a separate file,
#     then copy it into the partition. The file is sparse and mkfs only
#     writes metadata, so this moves about 21 MB, not <mib>.
hfs_create_gpt() {
    local img=$1 mib=$2 volname=$3 fs last
    [ ! -e "$img" ] || die "image already exists: $img"
    require_cmd sgdisk truncate dd
    fs=$img.hfs-tmp
    rm -f "$fs"
    hfs_create "$fs" "$mib" "$volname"
    # One MiB of GPT in front, one behind (the backup header needs 33
    # sectors; a megabyte is tidier and costs nothing in a sparse file).
    truncate -s "$((mib + 2))M" "$img" || { rm -f "$fs"; die "cannot create $img"; }
    last=$((2048 + mib * 2048 - 1))
    sgdisk -o -n "1:2048:$last" -t 1:AF00 -c "1:$volname" "$img" >/dev/null 2>&1 \
        || { rm -f "$fs" "$img"; die "sgdisk could not lay out $img"; }
    dd if="$fs" of="$img" bs=1M seek=1 conv=notrunc,sparse status=none \
        || { rm -f "$fs" "$img"; die "cannot copy the volume into $img"; }
    rm -f "$fs"
}

# hfs_backing_file <loopdev> -- the file a loop device is backed by, or
# nothing at all when it is not attached. This is the ground truth for
# "is it still attached", and it needs no privileges.
hfs_backing_file() {
    local dev=$1
    [ -b "$dev" ] || return 0
    losetup -n -O BACK-FILE "$dev" 2>/dev/null | sed 's/^ *//;s/ *$//'
}

# Prints the loop device.
hfs_attach() {
    local img=$1 out dev abs
    [ -f "$img" ] || die "no such image: $img"
    require_cmd udisksctl losetup
    abs=$(readlink -f -- "$img") || die "cannot resolve path: $img"
    out=$(udisksctl loop-setup -f "$img" --no-user-interaction 2>&1) \
        || die "loop-setup failed for $img: $out"
    # "Mapped file <path> as /dev/loopN." -- take the tail after " as ",
    # not any /dev/loopN-looking text anywhere in the message: the image
    # path is echoed back in that same line, and udisksctl merges warnings
    # into the stream we are reading.
    dev=${out##*" as "}
    dev=${dev%.}
    case $dev in
        /dev/loop[0-9]*) : ;;
        *) die "cannot parse a loop device out of: $out" ;;
    esac
    # And confirm it is ours: the device exists and is backed by the file
    # we just asked for.
    [ "$(hfs_backing_file "$dev")" = "$abs" ] \
        || die "$dev is not backed by $abs (loop-setup said: $out)"
    printf '%s\n' "$dev"
}

# hfs_mountpoint <dev> -- where the device is mounted right now, or
# nothing at all. findmnt exits non-zero when nothing matches, which is an
# answer rather than an error.
hfs_mountpoint() {
    findmnt -n -f -o TARGET --source "$1" 2>/dev/null || true
}

# Prints the mountpoint. Idempotent on purpose: a device that is already
# mounted is a success, not an error.
#
# This is a live desktop session, and gvfs/udisks automounting notices
# every loop device the moment it appears and races us to mount it. The
# loser of that race gets "already mounted" -- and which of us loses is not
# something we get to arrange. It also puts a modal dialog on the user's
# screen, which an automated pipeline has no business doing. Being correct
# whoever wins is a better fix than trying to win. (The systemic fix is a
# udev rule setting UDISKS_IGNORE=1 on our loop devices, but that is host
# configuration, which this project does not do to people's machines.)
hfs_mount() {
    local dev=$1 out mnt tries
    require_cmd udisksctl findmnt
    mnt=$(hfs_mountpoint "$dev")
    if [ -n "$mnt" ]; then
        printf '%s\n' "$mnt"
        return 0
    fi
    if ! out=$(udisksctl mount -b "$dev" --no-user-interaction 2>&1); then
        # The one failure that is not a failure: something else mounted it
        # between the check above and this call. That is the outcome we
        # were asking for, however it got there.
        mnt=$(hfs_mountpoint "$dev")
        [ -n "$mnt" ] || die "mount failed for $dev: $out"
        printf '%s\n' "$mnt"
        return 0
    fi
    # Ask the kernel where it landed rather than parsing "Mounted
    # /dev/loopN at <path>": a volume named `Weird. at Name.` defeats the
    # obvious sed, and udisks appends a digit when two volumes share a
    # name -- which the media build does, twice, with "OS X Base System".
    tries=$HFS_SETTLE_TRIES
    while [ "$tries" -gt 0 ]; do
        mnt=$(hfs_mountpoint "$dev")
        [ -z "$mnt" ] || break
        sleep 0.1
        tries=$((tries - 1))
    done
    if [ -z "$mnt" ]; then
        # findmnt sees only this process's mount namespace. udisks mounts
        # in the init namespace, so in a container or a private-mount
        # sandbox the mount can be real and invisible here. Fall back to
        # what udisksctl said, trimming at most one trailing period and
        # only when that is what makes the path resolve.
        mnt=${out#*" at "}
        [ -d "$mnt" ] || [ ! -d "${mnt%.}" ] || mnt=${mnt%.}
        [ -d "$mnt" ] || die "mounted $dev but cannot find where: $out"
    fi
    printf '%s\n' "$mnt"
}

# Unmounts, and says so honestly: a warning here means the filesystem is
# still mounted, not merely that udisksctl was unhappy.
hfs_unmount() {
    local dev=$1 out tries=3
    while [ "$tries" -gt 0 ]; do
        out=$(udisksctl unmount -b "$dev" --no-user-interaction 2>&1) \
            && return 0
        # Already unmounted is success, however it is spelled.
        [ -n "$(hfs_mountpoint "$dev")" ] || return 0
        sleep 0.5
        tries=$((tries - 1))
    done
    warn "still mounted after unmount attempts: $dev ($out)"
    return 1
}

hfs_detach() {
    local dev=$1 backing tries src
    backing=$(hfs_backing_file "$dev")
    [ -n "$backing" ] || return 0
    # Anything still mounted on this device makes loop-delete a silent
    # no-op, and it is not always ours: on a desktop session the
    # automounter grabs partitions of a new loop device on its own, so an
    # image whose partition we never mounted can still be busy. Unmount
    # whatever is there -- the whole-disk device and any partition of it --
    # before asking for the device back.
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        hfs_unmount "$src" || true
    done < <(findmnt -rno SOURCE 2>/dev/null | sort -u \
        | grep -E "^${dev}(p[0-9]+)?\$" || true)
    # loop-delete's exit status is not evidence either way: it returns 0
    # for a mounted device it declines to detach, and NotAuthorized for a
    # device that unmounting has already taken away. Ignore it and look.
    udisksctl loop-delete -b "$dev" --no-user-interaction >/dev/null 2>&1 || true
    tries=$HFS_SETTLE_TRIES
    while [ "$tries" -gt 0 ]; do
        [ -n "$(hfs_backing_file "$dev")" ] || return 0
        sleep 0.1
        tries=$((tries - 1))
    done
    warn "loop device $dev is still attached to $backing"
    return 1
}

# hfs_partition_dev <loopdev> <spec>
#
# Resolves one partition of an attached image: a partition number, or
# `auto` for the largest HFS+ partition on it. `auto` is what the media
# build wants -- dmg2img output carries an Apple partition map with small
# driver partitions on either side of the volume, and which number the
# volume lands on is not ours to predict. Waits for udev to create the
# node, which does not happen at loop-setup time.
#
# Dies rather than returning, so call it in a command substitution: that
# confines the exit to the subshell and hands the caller a non-zero status
# it can clean up after.
hfs_partition_dev() {
    local dev=$1 spec=$2 target tries=$HFS_SETTLE_TRIES
    require_cmd lsblk
    case $spec in
        auto|[1-9]*) : ;;
        *) die "not a partition number or 'auto': $spec" ;;
    esac
    while [ "$tries" -gt 0 ]; do
        if [ "$spec" = auto ]; then
            # Raw, no headers, sizes in bytes: each row is "<name> <size>
            # [<fstype>]", and a partition with no recognised filesystem
            # simply has no third field -- so a bare field count is enough
            # to tell them apart, with no ambiguity about empty columns.
            target=$(lsblk -b -nro NAME,SIZE,FSTYPE "$dev" 2>/dev/null \
                | awk '$3 == "hfsplus" && $2 > max { max = $2; name = $1 }
                       END { if (name != "") print "/dev/" name }')
        else
            target=${dev}p${spec}
        fi
        if [ -n "$target" ] && [ -b "$target" ]; then
            printf '%s\n' "$target"
            return 0
        fi
        sleep 0.1
        tries=$((tries - 1))
    done
    die "no partition $spec on $dev"
}

# hfs_with_mounted_part <img> <part> <function-name> [args...]
#
# Attaches <img>, mounts partition <part> of it (a number, `auto`, or `-`
# for an image that is a bare filesystem with no partition table), calls
# <function-name> <mountpoint> [args...], and always cleans up -- including
# when the body fails, which is the whole point. A leaked loop device or a
# stale mount under /media is the kind of mess that accumulates silently
# and breaks something unrelated hours later.
#
# Two calls may be nested or run side by side: each image gets its own loop
# device and its own mountpoint, even when the volume names collide -- and
# the media build has three of these nested, two of them mounting a volume
# called "OS X Base System".
hfs_with_mounted_part() {
    local img=$1 spec=$2 body=$3
    shift 3
    local dev target mnt rc=0
    dev=$(hfs_attach "$img") || return 1
    if [ "$spec" = "-" ]; then
        target=$dev
    else
        target=$(hfs_partition_dev "$dev" "$spec") \
            || { hfs_detach "$dev"; return 1; }
    fi
    mnt=$(hfs_mount "$target") || { hfs_detach "$dev"; return 1; }
    # The body runs in a subshell so that a `die` inside it -- or anything
    # else that calls `exit` -- unwinds to here instead of taking the whole
    # process down with the image still mounted. That is not hypothetical:
    # the first real media build died on an unreadable file and left three
    # loop devices and three mounts behind. The cost is that the body
    # cannot hand anything back through a variable, only through the
    # filesystem and its exit status.
    ( "$body" "$mnt" "$@" ) || rc=$?
    sync
    # Cleanup failure is a failure of the call, but it must not mask the
    # body's own exit status -- that is the one the caller is debugging.
    hfs_unmount "$target" || [ "$rc" -ne 0 ] || rc=1
    hfs_detach "$dev"     || [ "$rc" -ne 0 ] || rc=1
    return "$rc"
}

# hfs_with_mounted <img> <function-name> [args...]
# The same, for an image that is one bare HFS+ filesystem.
hfs_with_mounted() {
    local img=$1 body=$2
    shift 2
    hfs_with_mounted_part "$img" - "$body" "$@"
}

# hfs_mark_clean <img> [byte-offset-of-the-volume]
#
# Mark an HFS+ volume as cleanly unmounted, in place, from the host, with no
# privilege at all -- the image is our own file.
#
# WHY THIS IS NEEDED
#
# Linux's hfsplus driver mounts read-only, silently, when the volume header
# does not carry kHFSVolumeUnmountedBit. Any media a QEMU guest has booted
# is in exactly that state, because powering a VM off is not a clean
# unmount. The failure then arrives as "Read-only file system" from a chown
# in the privops microVM, which reads like a permissions problem, and
# `mount -o force` does not fix it: hfsplus_fill_super tests "was not
# cleanly unmounted" before it consults the force flag, and that branch is
# not overridable.
#
# WHAT IT DOES
#
# Sets kHFSVolumeUnmountedBit (0x100) and clears kHFSVolumeInconsistentBit
# (0x800) in the volume header at offset 1024 of the volume, and in the
# alternate header 1024 bytes before its end. fsck.hfsplus would do this
# properly after checking the filesystem; hfsprogs is not installed here and
# the project installs nothing, so this does the one thing that is needed.
#
# THIS IS NOT A FILESYSTEM CHECK. It asserts that the volume is consistent
# rather than verifying it. Use it on a volume nothing was writing to -- a
# read-only installer medium a guest booted -- and rebuild rather than
# repair anything else.
hfs_mark_clean() {
    local img=$1 start=${2:-0}
    [ -f "$img" ] || die "no such image: $img"
    require_cmd python3
    python3 - "$img" "$start" <<'PY'
import os
import struct
import sys

path, start = sys.argv[1], int(sys.argv[2])
UNMOUNTED = 0x00000100
INCONSISTENT = 0x00000800

with open(path, "r+b") as fh:
    size = os.fstat(fh.fileno()).st_size
    # The volume header lives 1024 bytes into the VOLUME, and the alternate
    # header in the volume's last 1024 bytes. The volume's length comes from
    # the header itself (blockSize * totalBlocks) rather than from the file,
    # because a partitioned image is longer than the volume inside it and
    # taking the end of the file finds a GPT backup header instead.
    fh.seek(start + 1024 + 40)
    block_size, total_blocks = struct.unpack(">II", fh.read(8))
    length = block_size * total_blocks
    if length <= 0 or start + length > size:
        sys.exit("volume at %d claims %d bytes, which does not fit in %s"
                 % (start, length, path))
    for where in (start + 1024, start + length - 1024):
        fh.seek(where)
        head = fh.read(8)
        if len(head) < 8:
            continue
        signature, _version, attributes = struct.unpack(">2sHI", head)
        if signature not in (b"H+", b"HX"):
            sys.exit("no HFS+ volume header at offset %d (found %r)"
                     % (where, signature))
        fixed = (attributes | UNMOUNTED) & ~INCONSISTENT
        if fixed != attributes:
            fh.seek(where + 4)
            fh.write(struct.pack(">I", fixed))
            print("hfs_mark_clean: %d: attributes 0x%08x -> 0x%08x"
                  % (where, attributes, fixed))
        else:
            print("hfs_mark_clean: %d: already clean (0x%08x)"
                  % (where, attributes))
PY
}
