# shellcheck shell=bash
# Unprivileged HFS+ image handling.
#
# NOTHING HERE MOUNTS ANYTHING, AND NOTHING HERE NEEDS A PRIVILEGE.
# Every function writes a plain file with mkfs.hfsplus, sgdisk, dd or
# python3. Reading or writing the CONTENTS of an HFS+ volume is a
# different job and happens somewhere else: hand a payload to privops_run
# and the microVM does it as uid 0. See lib/privops.sh.
#
# This file used to have a second half -- udisks2 loop devices and mounts,
# hfs_attach/hfs_mount/hfs_unmount/hfs_detach/hfs_with_mounted. It is
# gone, on 2026-09-21, because nothing was left calling it. udisks2 grants
# `loop-setup` to a user AT A SEAT, so every one of those functions
# refused an SSH session to a headless host (G26), and each mount put a
# file-browser window and a notification on the screen of anyone who did
# have a seat, because /run/media/$USER is where desktop handlers look.
#
#   * media/build-installer-img.sh stopped mounting when the whole HFS+
#     assembly moved into the privops microVM.
#   * media/content-digest.sh stopped mounting when its volume walk moved
#     there too -- which mattered more than "a by-hand diagnostic"
#     suggested, because image/build-image.sh calls it for every image
#     manifest's `mediacontent` line with stderr discarded, so on a
#     headless host that field silently came out empty.
#   * tests/hfs.bats covered only the deleted half, behind an opt-in
#     switch that stopped it running at all.
#
# So: a host needs no seat, no udisks2, no losetup, no findmnt and no
# lsblk for anything this project does. If something new wants to read or
# write an HFS+ volume, take a payload to privops_run rather than bring
# any of this back.
#
# Requires lib/common.sh.

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
#   * mkfs.hfsplus cannot write at an offset into a file, and there is no
#     unprivileged way to put a filesystem inside a partition in place.
#     So: format a separate file, then copy it into the partition. The
#     file is sparse and mkfs only writes metadata, so this moves about
#     21 MB, not <mib>.
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
