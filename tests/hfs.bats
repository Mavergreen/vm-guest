#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/hfs.sh"
    IMG="$BATS_TEST_TMPDIR/t.img"
}

# NOTHING HERE MOUNTS, so nothing here is opt-in any more.
#
# Fourteen tests used to exercise hfs_attach, hfs_mount, hfs_unmount,
# hfs_detach, hfs_with_mounted and hfs_partition_dev through udisks2. They
# were skipped by default -- udisks mounts under /run/media/$USER, which
# is exactly where desktop handlers look, so every run of the suite threw
# a notification and a file-manager window per mount -- and a test that
# does not run is not cover, however healthy the count looks. They went
# with the functions on 2026-09-21, once nothing called them.
#
# What is left is what the pipeline calls: three functions that write a
# plain file and need no privilege. A test that needs an HFS+ volume read
# or written belongs where that now happens -- hand a payload to
# privops_run and let the microVM do it as uid 0. bin/privops-selftest.sh
# is the end-to-end version of that, and it checks a volume name by
# mounting it in the guest.

@test "hfs_create makes an HFS+ image" {
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
    # THE VOLUME NAME IS NOT CHECKED HERE ANY MORE. It lives in the
    # catalog's root thread record, not the volume header, so seeing it
    # takes an HFS+ reader -- which used to mean a udisks mount, whose
    # mountpoint udisks names after the volume. The two places it is still
    # observed are the GPT partition label below (hfs_create_gpt passes
    # the same string to sgdisk -c) and bin/privops-selftest.sh, which
    # mounts inside the microVM.
}

@test "hfs_create refuses to clobber an existing image" {
    hfs_create "$IMG" 32 MQGTEST
    run hfs_create "$IMG" 32 MQGTEST
    [ "$status" -ne 0 ]
    [[ "$output" == *"exists"* ]]
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

# --- the whole repository, not just this file ----------------------------

@test "no shell script in this repository mounts anything on the host" {
    # The one assertion that cannot drift as callers come and go. Both
    # halves of the old path are named: the tools (udisks2's client, and
    # the three that inspect what it attached) and the functions that
    # wrapped them.
    #
    # It matters beyond tidiness. udisks2's polkit policy grants
    # `loop-setup` to a user AT A SEAT, so anything reaching for it
    # refuses an SSH session to a headless host -- every CI runner, and
    # the machine this project actually wanted to build on (G26). And a
    # mount lands under /run/media/$USER, which is where desktop handlers
    # look, so it pops a window at anyone who does have a seat.
    #
    # Comment lines are exempt: the reasons above are written down in
    # several of these files and must stay written down.
    found=""
    while IFS= read -r f; do
        grep -qE '^[^#]*\b(udisksctl|losetup|findmnt|lsblk)\b' "$f" \
            && found="$found $f"
        grep -qE '^[^#]*\bhfs_(attach|mount|unmount|detach|with_mounted|with_mounted_part|partition_dev|backing_file|mountpoint)\b' "$f" \
            && found="$found $f"
    done < <(find "$REPO" -name .git -prune -o -name '*.sh' -print)
    [ -z "$found" ] || { echo "these still reach for the host mount path:$found"; false; }
}
