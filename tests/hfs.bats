#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/hfs.sh"
    IMG="$BATS_TEST_TMPDIR/t.img"
}

teardown() {
    # Never leave a loop device behind, even if a test failed mid-way.
    if [ -n "${LOOPDEV:-}" ]; then
        hfs_unmount "$LOOPDEV" 2>/dev/null || true
        hfs_detach "$LOOPDEV" 2>/dev/null || true
    fi
    if [ -n "${LOOPDEV2:-}" ]; then
        hfs_unmount "$LOOPDEV2" 2>/dev/null || true
        hfs_detach "$LOOPDEV2" 2>/dev/null || true
    fi
}

@test "hfs_create makes a mountable HFS+ image with the requested volume name" {
    hfs_create "$IMG" 32 MQGTEST
    [ -f "$IMG" ]
    run file "$IMG"
    # file(1) has called this three things over the years. Ubuntu 24.04's
    # file 5.45 says "Apple HFS Plus version 4 data"; older ones said
    # "Macintosh HFS Extended". Accept any of them rather than pinning the
    # test to one distro's magic file.
    [[ "$output" == *"Apple HFS Plus"* ]] \
        || [[ "$output" == *"Macintosh HFS Extended"* ]] \
        || [[ "$output" == *"HFS+"* ]]
    # The volume name is not in file(1)'s output, so check it where it is
    # observable: udisks names the mountpoint after it.
    LOOPDEV=$(hfs_attach "$IMG")
    MNT=$(hfs_mount "$LOOPDEV")
    [ "$(basename "$MNT")" = "MQGTEST" ]
    hfs_unmount "$LOOPDEV"; hfs_detach "$LOOPDEV"; LOOPDEV=""
}

@test "hfs_create refuses to clobber an existing image" {
    hfs_create "$IMG" 32 MQGTEST
    run hfs_create "$IMG" 32 MQGTEST
    [ "$status" -ne 0 ]
    [[ "$output" == *"exists"* ]]
}

@test "attach, mount, write, read back, unmount, detach" {
    hfs_create "$IMG" 32 MQGTEST
    LOOPDEV=$(hfs_attach "$IMG")
    [[ "$LOOPDEV" == /dev/loop* ]]
    MNT=$(hfs_mount "$LOOPDEV")
    [ -d "$MNT" ]
    printf 'hello hfs\n' > "$MNT/greeting.txt"
    run cat "$MNT/greeting.txt"
    [ "$output" = "hello hfs" ]
    hfs_unmount "$LOOPDEV"
    run mount
    [[ "$output" != *"$MNT"* ]]
    hfs_detach "$LOOPDEV"
    # The loop device really is gone, not merely reported gone: a
    # loop-delete that returns 0 without detaching is a leak.
    run bash -c "losetup -a 2>/dev/null | grep -c -- '$IMG' || true"
    [ "$output" = "0" ]
    LOOPDEV=""
}

@test "hfs_mount reports the real mountpoint, not a parse of the message" {
    # A volume name containing " at " and a trailing period defeats the
    # obvious sed on udisksctl's "Mounted /dev/loopN at <path>" line.
    hfs_create "$IMG" 32 "Weird. at Name."
    LOOPDEV=$(hfs_attach "$IMG")
    MNT=$(hfs_mount "$LOOPDEV")
    [ -d "$MNT" ]
    [ "$(basename "$MNT")" = "Weird. at Name." ]
    hfs_unmount "$LOOPDEV"; hfs_detach "$LOOPDEV"; LOOPDEV=""
}

@test "hfs_with_mounted cleans up even when the body fails" {
    hfs_create "$IMG" 32 MQGTEST
    body_that_fails() { return 3; }
    run hfs_with_mounted "$IMG" body_that_fails
    [ "$status" -ne 0 ]
    # Nothing of ours should still be attached to this image.
    run bash -c "losetup -a 2>/dev/null | grep -c -- '$IMG' || true"
    [ "$output" = "0" ]
}

@test "hfs_with_mounted passes the mountpoint to the body" {
    hfs_create "$IMG" 32 MQGTEST
    body_writes() { printf 'ok\n' > "$1/written.txt"; }
    hfs_with_mounted "$IMG" body_writes
    LOOPDEV=$(hfs_attach "$IMG")
    MNT=$(hfs_mount "$LOOPDEV")
    run cat "$MNT/written.txt"
    [ "$output" = "ok" ]
    hfs_unmount "$LOOPDEV"; hfs_detach "$LOOPDEV"; LOOPDEV=""
}

@test "hfs_with_mounted passes extra arguments through to the body" {
    hfs_create "$IMG" 32 MQGTEST
    body_args() { printf '%s\n' "$2" > "$1/arg.txt"; }
    hfs_with_mounted "$IMG" body_args "a value with spaces"
    body_reads() { cat "$1/arg.txt"; }
    run hfs_with_mounted "$IMG" body_reads
    [ "$status" -eq 0 ]
    [ "$output" = "a value with spaces" ]
}

@test "two images can be mounted at once, with the same volume name" {
    # Task 3 mounts the ESD and the target at the same time, and two of the
    # volumes it handles are both called "OS X Base System".
    IMG2="$BATS_TEST_TMPDIR/t2.img"
    hfs_create "$IMG" 32 "OS X Base System"
    hfs_create "$IMG2" 32 "OS X Base System"
    outer() {
        local mnt1=$1
        printf 'one\n' > "$mnt1/who.txt"
        inner() {
            local mnt2=$1
            printf 'two\n' > "$mnt2/who.txt"
            [ "$mnt1" != "$mnt2" ]
            [ "$(cat "$mnt1/who.txt")" = "one" ]
        }
        hfs_with_mounted "$IMG2" inner
    }
    run hfs_with_mounted "$IMG" outer
    [ "$status" -eq 0 ]
    run bash -c "losetup -a 2>/dev/null | grep -c -- '$BATS_TEST_TMPDIR' || true"
    [ "$output" = "0" ]
}

@test "hfs_attach fails clearly for a file that is not an HFS+ image" {
    printf 'not an image\n' > "$BATS_TEST_TMPDIR/bogus.img"
    run hfs_attach "$BATS_TEST_TMPDIR/bogus.img"
    # Attaching may succeed; mounting must not. Either way, no silent success.
    if [ "$status" -eq 0 ]; then
        LOOPDEV="$output"
        run hfs_mount "$LOOPDEV"
        [ "$status" -ne 0 ]
    fi
}

@test "hfs_attach fails for a file that does not exist" {
    run hfs_attach "$BATS_TEST_TMPDIR/absent.img"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such image"* ]]
}

@test "hfs_mount is idempotent: an already-mounted device is a success" {
    # This host is a live desktop session: gvfs/udisks automounting races
    # every loop-setup, and whoever loses gets "already mounted". Winning
    # the race is not something we can arrange; being correct either way
    # is. See the P4 entry in NOTES.md.
    hfs_create "$IMG" 32 MQGTEST
    LOOPDEV=$(hfs_attach "$IMG")
    MNT=$(hfs_mount "$LOOPDEV")
    run hfs_mount "$LOOPDEV"
    [ "$status" -eq 0 ]
    [ "$output" = "$MNT" ]
    hfs_unmount "$LOOPDEV"; hfs_detach "$LOOPDEV"; LOOPDEV=""
}

@test "hfs_create_gpt makes a GPT image with one AF00 HFS+ partition" {
    hfs_create_gpt "$IMG" 32 "OS X Base System"
    run sgdisk -p "$IMG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AF00"* ]]
    [[ "$output" == *"OS X Base System"* ]]
    # No leftover intermediate beside the image.
    run bash -c "ls '$BATS_TEST_TMPDIR' | grep -c hfs-tmp || true"
    [ "$output" = "0" ]
}

@test "hfs_create_gpt refuses to clobber an existing image" {
    hfs_create_gpt "$IMG" 32 MQGTEST
    run hfs_create_gpt "$IMG" 32 MQGTEST
    [ "$status" -ne 0 ]
    [[ "$output" == *"exists"* ]]
}

@test "hfs_with_mounted_part mounts the partition inside a GPT image" {
    # The whole-disk device is not mountable; partition 1 is. This is how
    # media/build-installer-img.sh writes into its target.
    hfs_create_gpt "$IMG" 32 "OS X Base System"
    body_writes() { printf 'in a partition\n' > "$1/written.txt"; }
    hfs_with_mounted_part "$IMG" 1 body_writes
    body_reads() { cat "$1/written.txt"; }
    run hfs_with_mounted_part "$IMG" auto body_reads
    [ "$status" -eq 0 ]
    [ "$output" = "in a partition" ]
    run bash -c "losetup -a 2>/dev/null | grep -c -- '$IMG' || true"
    [ "$output" = "0" ]
}

@test "hfs_with_mounted_part cleans up when the body fails" {
    hfs_create_gpt "$IMG" 32 MQGTEST
    body_that_fails() { return 4; }
    run hfs_with_mounted_part "$IMG" 1 body_that_fails
    [ "$status" -ne 0 ]
    run bash -c "losetup -a 2>/dev/null | grep -c -- '$IMG' || true"
    [ "$output" = "0" ]
}

@test "hfs_with_mounted_part fails clearly for a partition that is not there" {
    hfs_create_gpt "$IMG" 32 MQGTEST
    body_never_runs() { printf 'should not happen\n' > "$1/nope.txt"; }
    run hfs_with_mounted_part "$IMG" 7 body_never_runs
    [ "$status" -ne 0 ]
    run bash -c "losetup -a 2>/dev/null | grep -c -- '$IMG' || true"
    [ "$output" = "0" ]
}

@test "hfs_with_mounted cleans up when the body exits rather than returns" {
    # `die` calls exit. A body that hits one must not take the cleanup down
    # with it: that is how the first real media build left three loop
    # devices and three mounts behind.
    hfs_create "$IMG" 32 MQGTEST
    body_that_dies() { die "nope"; }
    run hfs_with_mounted "$IMG" body_that_dies
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
    run bash -c "losetup -a 2>/dev/null | grep -c -- '$IMG' || true"
    [ "$output" = "0" ]
}

# hfs_mark_clean: the repair for a volume a guest booted.
#
# Linux's hfsplus driver mounts read-only, silently, when the volume header
# does not say the volume was cleanly unmounted -- which is the state of any
# installer medium a VM has been powered off on. `mount -o force` does NOT
# override that particular branch, so the fix has to be in the header.

@test "hfs_mark_clean sets the cleanly-unmounted bit in both volume headers" {
    hfs_create "$IMG" 32 MQGTEST
    # Clear the bit in both headers, the way an unclean shutdown leaves it.
    python3 - "$IMG" <<'PY'
import os
import struct
import sys
path = sys.argv[1]
with open(path, "r+b") as fh:
    fh.seek(1024 + 40)
    block_size, total_blocks = struct.unpack(">II", fh.read(8))
    for where in (1024, block_size * total_blocks - 1024):
        fh.seek(where + 4)
        attrs = struct.unpack(">I", fh.read(4))[0]
        fh.seek(where + 4)
        fh.write(struct.pack(">I", (attrs & ~0x100) | 0x800))
PY
    run hfs_mark_clean "$IMG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-> 0x"* ]]
    # Both headers, not just the first: the kernel reads the alternate one
    # from the end of the device, and a half-repaired volume still mounts
    # read-only.
    again=$(hfs_mark_clean "$IMG")
    [ "$(printf '%s\n' "$again" | grep -c 'already clean')" = "2" ]
}

@test "hfs_mark_clean refuses a file that is not an HFS+ volume" {
    head -c 8192 /dev/zero > "$IMG"
    run hfs_mark_clean "$IMG"
    [ "$status" -ne 0 ]
}

@test "hfs_mark_clean finds the alternate header inside a partitioned image" {
    # The trap this test exists for: taking the end of the FILE rather than
    # the end of the VOLUME finds the GPT backup header instead, and says
    # there is no HFS+ volume there.
    hfs_create_gpt "$IMG" 32 MQGTEST
    run hfs_mark_clean "$IMG" 1048576
    [ "$status" -eq 0 ]
    [[ "$output" != *"no HFS+ volume header"* ]]
}
