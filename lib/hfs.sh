# shellcheck shell=bash
# Unprivileged HFS+ image handling.
#
# The design assumed this needed sudo for losetup and mount. It does not:
# mkfs.hfsplus operates on a plain file, and udisks2 provides loop devices
# and mounts to a desktop user without a password, auto-loading the hfsplus
# module. See the P4 entries in NOTES.md.
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

# Prints the mountpoint.
hfs_mount() {
    local dev=$1 out mnt tries
    require_cmd udisksctl findmnt
    out=$(udisksctl mount -b "$dev" --no-user-interaction 2>&1) \
        || die "mount failed for $dev: $out"
    # Ask the kernel where it landed rather than parsing "Mounted
    # /dev/loopN at <path>": a volume named `Weird. at Name.` defeats the
    # obvious sed, and udisks appends a digit when two volumes share a
    # name -- which the media build does, twice, with "OS X Base System".
    tries=$HFS_SETTLE_TRIES
    while [ "$tries" -gt 0 ]; do
        mnt=$(findmnt -n -f -o TARGET --source "$dev" 2>/dev/null) || mnt=
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
        [ -n "$(findmnt -n -f -o TARGET --source "$dev" 2>/dev/null)" ] \
            || return 0
        sleep 0.5
        tries=$((tries - 1))
    done
    warn "still mounted after unmount attempts: $dev ($out)"
    return 1
}

hfs_detach() {
    local dev=$1 backing tries
    backing=$(hfs_backing_file "$dev")
    [ -n "$backing" ] || return 0
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

# hfs_with_mounted <img> <function-name> [args...]
# Calls <function-name> <mountpoint> [args...], then always cleans up --
# including when the body fails, which is the whole point. A leaked loop
# device or a stale mount under /media is the kind of mess that
# accumulates silently and then breaks something unrelated hours later.
#
# Two calls may be nested or run side by side: each image gets its own loop
# device and its own mountpoint, even when the volume names collide.
hfs_with_mounted() {
    local img=$1 body=$2
    shift 2
    local dev mnt rc=0
    dev=$(hfs_attach "$img") || return 1
    mnt=$(hfs_mount "$dev") || { hfs_detach "$dev"; return 1; }
    "$body" "$mnt" "$@" || rc=$?
    sync
    # Cleanup failure is a failure of the call, but it must not mask the
    # body's own exit status -- that is the one the caller is debugging.
    hfs_unmount "$dev" || [ "$rc" -ne 0 ] || rc=1
    hfs_detach "$dev"  || [ "$rc" -ne 0 ] || rc=1
    return "$rc"
}
