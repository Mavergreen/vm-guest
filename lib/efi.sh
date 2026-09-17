# shellcheck shell=bash
# Build and populate a GPT + FAT32 EFI System Partition image.
#
# sgdisk plus mtools, deliberately: no loop mounts and no root. Root would
# be a stop-and-ask in this project, and mtools already proved sufficient
# when patching the reference OpenCore image during P1.
#
# Requires lib/common.sh.

# The ESP starts at LBA 2048, the conventional 1 MiB alignment. mtools needs
# a byte offset into the image, which is what efi_partition_offset returns.
EFI_FIRST_LBA=2048
EFI_SECTOR_BYTES=512

# efi_image_create <path> <size-mib>
efi_image_create() {
    local img=$1 mib=$2
    [ ! -e "$img" ] || die "image already exists: $img"
    require_cmd sgdisk mformat
    truncate -s "${mib}M" "$img" || die "cannot create $img"
    sgdisk --clear \
           --new=1:${EFI_FIRST_LBA}:0 \
           --typecode=1:EF00 \
           --change-name=1:"EFI" \
           "$img" >/dev/null 2>&1 || die "sgdisk failed on $img"
    # -T is not decoration. mtools is handed a byte *offset*, not a
    # partition, so without an explicit sector count it formats from there
    # to the end of the file -- including the 33 sectors GPT reserves at
    # the end for the backup header and partition table. The filesystem
    # would then believe it owns space the partition table says it does
    # not, and a large enough write would scribble over the backup GPT.
    # sgdisk is the authority on where the partition ends; ask it.
    mformat -i "$img@@$(efi_partition_offset "$img")" \
            -T "$(efi_partition_sectors "$img")" -F -v EFI :: \
        || die "mformat failed on $img"
}

efi_partition_offset() {
    printf '%s\n' "$((EFI_FIRST_LBA * EFI_SECTOR_BYTES))"
}

# efi_partition_sectors <img> -- how many sectors partition 1 actually has,
# read back from the partition table rather than assumed.
efi_partition_sectors() {
    local img=$1 last
    last=$(sgdisk -i 1 "$img" 2>/dev/null \
           | sed -n 's/^Last sector: \([0-9][0-9]*\).*/\1/p')
    [ -n "$last" ] || die "cannot read partition 1 of $img"
    printf '%s\n' "$(( last - EFI_FIRST_LBA + 1 ))"
}

# efi_fits <size-mib> <payload-bytes>
#
# True when a payload of that size belongs in an image of that size, with
# room to spare. An image that is merely large enough fails later, at
# mcopy time, with a message about the file rather than about the image --
# which is a bad half-hour. The margin is deliberately generous: we are
# sizing a boot partition, not rationing a floppy.
#
# Reserved: 1 MiB before the ESP, ~4 MiB for FAT32's two tables, root
# directory and per-file cluster rounding. Headroom: the payload again,
# so a driver or a kext can double in size without anyone re-doing this
# arithmetic.
efi_fits() {
    local mib=$1 bytes=$2 capacity
    capacity=$(( (mib - 1) * 1024 * 1024 - 4 * 1024 * 1024 ))
    [ "$capacity" -gt 0 ] || return 1
    [ "$(( bytes * 2 ))" -le "$capacity" ]
}

efi_mkdir() {
    local img=$1 path=$2
    mmd -i "$img@@$(efi_partition_offset "$img")" "$path" \
        || die "cannot create directory $path in $img"
}

# efi_copy_in <img> <host-file> <::/path/in/image>
efi_copy_in() {
    local img=$1 src=$2 dst=$3
    [ -f "$src" ] || die "no such file: $src"
    mcopy -o -i "$img@@$(efi_partition_offset "$img")" "$src" "$dst" \
        || die "cannot copy $src to $dst in $img"
}

# efi_copy_tree <img> <host-dir> <::/path/in/image>
#
# Copy a directory in whole, keeping its shape. Kexts are the reason: a
# .kext is a bundle, and OpenCore looks inside it for the exact paths the
# config's PlistPath and ExecutablePath name. Copying the two files we
# happen to know about would work today and break silently the day a
# release ships a third, so the tree is walked instead.
#
# Directories are created parent-first: a lexicographic sort puts a parent
# before anything beneath it, because the parent's path is a prefix of the
# child's.
efi_copy_tree() {
    local img=$1 src=$2 dst=$3 rel
    [ -d "$src" ] || die "no such directory: $src"
    efi_mkdir "$img" "$dst"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        efi_mkdir "$img" "$dst/$rel"
    done < <(cd "$src" && find . -mindepth 1 -type d -printf '%P\n' | sort)
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        efi_copy_in "$img" "$src/$rel" "$dst/$rel"
    done < <(cd "$src" && find . -type f -printf '%P\n' | sort)
}

efi_copy_out() {
    local img=$1 src=$2 dst=$3
    mcopy -n -i "$img@@$(efi_partition_offset "$img")" "$src" "$dst" \
        || die "cannot copy $src out of $img"
}

efi_list() {
    local img=$1 path=${2:-::}
    mdir -i "$img@@$(efi_partition_offset "$img")" "$path"
}
