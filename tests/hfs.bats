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
