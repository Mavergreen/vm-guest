# shellcheck shell=bash
# Golden images: read-only, checksummed, with a metadata sidecar.
#
# Nothing ever writes to a golden. Experiments run on overlays created by
# vm/clone.sh. Promotion is deliberate and, per the design, requires
# measurement and the user's approval -- this library only enforces the
# mechanical half.
#
# Requires lib/common.sh. Callers set GOLDEN_DIR.

golden_image() { printf '%s/%s.qcow2\n'  "${GOLDEN_DIR:?GOLDEN_DIR is unset}" "$1"; }
golden_sum()   { printf '%s/%s.sha256\n' "${GOLDEN_DIR:?}" "$1"; }
golden_meta()  { printf '%s/%s.meta\n'   "${GOLDEN_DIR:?}" "$1"; }

# golden_promote <source-image> <name> <description>
#
# Builds the image, checksum and metadata as temp files under GOLDEN_DIR and
# only renames them into place once all three are complete -- so a golden
# never appears at its real name half-written, and dying midway (a bad
# source, a full disk, qemu-img choking on the copy) never leaves a
# writable, half-promoted image sitting where a read-only golden belongs.
# The final rename uses `mv -n` so two promotions racing on the same name
# can't silently clobber one another: the loser dies instead of winning
# quietly.
golden_promote() {
    local src=$1 name=$2 desc=$3
    local img sum meta tmp_img tmp_sum tmp_meta suffix info

    [ -f "$src" ] || die "no such image: $src"
    img=$(golden_image "$name")
    [ ! -e "$img" ] || die "golden $name already exists at $img"
    sum=$(golden_sum "$name")
    meta=$(golden_meta "$name")

    mkdir -p "$GOLDEN_DIR"
    # btrfs copy-on-write fragments qcow2 files badly. The no-COW attribute
    # only applies to files created after it is set on their directory, so
    # it must land here, before the temp image below is written -- setting
    # it on the image file afterwards would do nothing. Not every
    # filesystem supports the attribute (notably not every filesystem a
    # test tmpdir might sit on), so a failure here is a warning, not fatal.
    chattr +C "$GOLDEN_DIR" 2>/dev/null \
        || warn "could not set +C (no-COW) on $GOLDEN_DIR; images may fragment on this filesystem"

    tmp_img=$(mktemp "$GOLDEN_DIR/.${name}.qcow2.XXXXXX") \
        || die "cannot create temp file in $GOLDEN_DIR"
    suffix=${tmp_img##*.}
    tmp_sum="$GOLDEN_DIR/.${name}.sha256.$suffix"
    tmp_meta="$GOLDEN_DIR/.${name}.meta.$suffix"

    log "promoting $src to golden $name (this copies the whole image)"
    if ! cp --reflink=auto "$src" "$tmp_img"; then
        rm -f "$tmp_img"
        die "copy failed while promoting $name"
    fi

    sha256_file "$tmp_img" > "$tmp_sum"

    if ! info=$(qemu-img info "$tmp_img" 2>&1); then
        rm -f "$tmp_img" "$tmp_sum"
        die "qemu-img info failed on the copy while promoting $name: $info"
    fi

    {
        printf 'name: %s\n'        "$name"
        printf 'description: %s\n' "$desc"
        printf 'promoted: %s\n'    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'source: %s\n'      "$src"
        printf 'sha256: %s\n'      "$(cat "$tmp_sum")"
        printf 'qemu-img-info:\n'
        printf '%s\n' "$info" | sed 's/^/  /'
    } > "$tmp_meta"

    chmod 0444 "$tmp_img"

    if ! mv -n "$tmp_img" "$img"; then
        rm -f "$tmp_img" "$tmp_sum" "$tmp_meta"
        die "golden $name already exists at $img (lost a race with a concurrent promotion?)"
    fi
    mv -f "$tmp_sum" "$sum"
    mv -f "$tmp_meta" "$meta"
    log "golden $name promoted"
}

golden_verify() {
    local name=$1 img sum
    img=$(golden_image "$name")
    sum=$(golden_sum "$name")
    [ -f "$img" ] || die "no such golden: $name"
    [ -f "$sum" ] || die "golden $name has no recorded checksum"
    verify_sha256 "$img" "$(cat "$sum")"
    log "golden $name verified"
}

golden_path() {
    local img
    img=$(golden_image "$1")
    [ -f "$img" ] || die "no such golden: $1"
    printf '%s\n' "$img"
}

golden_list() {
    local g
    for g in "${GOLDEN_DIR:?}"/*.qcow2; do
        [ -e "$g" ] || continue
        basename "$g" .qcow2
    done
}
