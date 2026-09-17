#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/efi.sh"
    IMG="$BATS_TEST_TMPDIR/test.img"
}

@test "efi_image_create makes a GPT image with one EFI System Partition" {
    efi_image_create "$IMG" 48
    [ -f "$IMG" ]
    run sgdisk -p "$IMG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EF00"* ]] || [[ "$output" == *"EFI System"* ]]
}

@test "efi_image_create refuses to clobber an existing image" {
    efi_image_create "$IMG" 48
    run efi_image_create "$IMG" 48
    [ "$status" -ne 0 ]
    [[ "$output" == *"exists"* ]]
}

@test "efi_partition_offset reports where the ESP starts" {
    efi_image_create "$IMG" 48
    run efi_partition_offset "$IMG"
    [ "$status" -eq 0 ]
    [ "$output" -gt 0 ]
}

@test "files copied in are readable back out" {
    efi_image_create "$IMG" 48
    printf 'hello efi\n' > "$BATS_TEST_TMPDIR/f.txt"
    efi_mkdir "$IMG" "::/EFI"
    efi_copy_in "$IMG" "$BATS_TEST_TMPDIR/f.txt" "::/EFI/f.txt"
    efi_copy_out "$IMG" "::/EFI/f.txt" "$BATS_TEST_TMPDIR/out.txt"
    run cat "$BATS_TEST_TMPDIR/out.txt"
    [ "$output" = "hello efi" ]
}

@test "nested directories can be created and populated" {
    efi_image_create "$IMG" 48
    efi_mkdir "$IMG" "::/EFI"
    efi_mkdir "$IMG" "::/EFI/OC"
    efi_mkdir "$IMG" "::/EFI/OC/Drivers"
    # A name that is not 8.3-clean, on purpose. mdir prints the short name
    # in its columns and the long name only beside it, so a test using a
    # short name like "d.efi" would be matching "d        efi" and would
    # not notice long names being lost -- which is exactly what would break
    # OpenCore, since it looks for "OpenHfsPlus.efi" by name.
    printf 'driver\n' > "$BATS_TEST_TMPDIR/OpenHfsPlus.efi"
    efi_copy_in "$IMG" "$BATS_TEST_TMPDIR/OpenHfsPlus.efi" \
        "::/EFI/OC/Drivers/OpenHfsPlus.efi"
    run efi_list "$IMG" "::/EFI/OC/Drivers"
    [[ "$output" == *"OpenHfsPlus.efi"* ]]
}

@test "efi_copy_in fails loudly for a missing source file" {
    efi_image_create "$IMG" 48
    run efi_copy_in "$IMG" "$BATS_TEST_TMPDIR/nope" "::/nope"
    [ "$status" -ne 0 ]
}

# --- beyond the plan --------------------------------------------------

@test "the filesystem stays inside its partition, off the backup GPT" {
    # mtools is told a byte offset, not a partition, so left to itself it
    # formats from that offset to the end of the file -- over the 33
    # sectors GPT reserves at the end for the backup header and table. A
    # filesystem that believes it owns those sectors will eventually write
    # to them. sgdisk is the authority on where the partition ends.
    efi_image_create "$IMG" 48
    last=$(sgdisk -i 1 "$IMG" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
    [ -n "$last" ]
    part_sectors=$(( last - 2048 + 1 ))
    run minfo -i "$IMG@@$(efi_partition_offset "$IMG")"
    [ "$status" -eq 0 ]
    fs_sectors=$(printf '%s\n' "$output" \
        | sed -n 's/^big size: \([0-9]*\) sectors.*/\1/p')
    [ -n "$fs_sectors" ]
    [ "$fs_sectors" -le "$part_sectors" ]
}

@test "efi_fits demands headroom, not merely enough room" {
    # 1 MB of payload in an 8 MiB image: fine.
    run efi_fits 8 1000000
    [ "$status" -eq 0 ]
    # 3 MB of payload in an 8 MiB image: it would physically fit, and that
    # is exactly the case this guard exists to reject.
    run efi_fits 8 3000000
    [ "$status" -ne 0 ]
    # An image too small to hold even the filesystem overhead.
    run efi_fits 2 1
    [ "$status" -ne 0 ]
}

@test "a bundle is copied as a tree, not flattened" {
    efi_image_create "$IMG" 48
    K="$BATS_TEST_TMPDIR/Fake.kext"
    mkdir -p "$K/Contents/MacOS" "$K/Contents/Resources"
    printf 'plist\n' > "$K/Contents/Info.plist"
    printf 'macho\n' > "$K/Contents/MacOS/Fake"
    printf 'extra\n' > "$K/Contents/Resources/thing.bin"
    efi_mkdir "$IMG" "::/EFI"
    efi_mkdir "$IMG" "::/EFI/OC"
    efi_mkdir "$IMG" "::/EFI/OC/Kexts"
    efi_copy_tree "$IMG" "$K" "::/EFI/OC/Kexts/Fake.kext"

    run efi_list "$IMG" "::/EFI/OC/Kexts/Fake.kext/Contents/MacOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Fake"* ]]

    # Files the caller never named individually come along too -- that is
    # the whole point of walking the tree.
    efi_copy_out "$IMG" "::/EFI/OC/Kexts/Fake.kext/Contents/Resources/thing.bin" \
        "$BATS_TEST_TMPDIR/thing.bin"
    run cat "$BATS_TEST_TMPDIR/thing.bin"
    [ "$output" = "extra" ]
}

@test "efi_copy_tree refuses a source that is not a directory" {
    efi_image_create "$IMG" 48
    run efi_copy_tree "$IMG" "$BATS_TEST_TMPDIR/absent.kext" "::/absent.kext"
    [ "$status" -ne 0 ]
}
