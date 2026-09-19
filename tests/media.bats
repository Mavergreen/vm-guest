#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "fetch-installesd.sh prints the checksum it expects, without fetching" {
    run "$REPO/media/fetch-installesd.sh" --show-expected
    [ "$status" -eq 0 ]
    # A sha256 is 64 hex characters.
    [[ "$output" =~ [0-9a-f]{64} ]]
}

@test "fetch-installesd.sh refuses to run without the tools it needs" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for t in bash dirname; do ln -sf "$(command -v $t)" "$BATS_TEST_TMPDIR/bin/$t"; done
    run env PATH="$BATS_TEST_TMPDIR/bin" "$REPO/media/fetch-installesd.sh" --show-expected
    # --show-expected must work without curl; the fetch path must not.
    [ "$status" -eq 0 ]
    run env PATH="$BATS_TEST_TMPDIR/bin" "$REPO/media/fetch-installesd.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"curl"* ]]
}

@test "fetch-installesd.sh's pinned checksum matches the one in sources.tsv" {
    # Two places name this checksum: the script, so --show-expected needs
    # nothing but bash, and the registry, so it is recorded where every
    # other third-party artifact is. They must not drift apart.
    expected=$("$REPO/media/fetch-installesd.sh" --show-expected)
    recorded=$(awk -F'\t' '$1 == "apple-installesd-10.9.5" { print $3 }' \
        "$REPO/vendor/sources.tsv")
    [ -n "$recorded" ]
    [ "$expected" = "$recorded" ]
}

@test "fetch-installesd.sh leaves an already-verified download alone" {
    # The one byte of content whose sha256 we can state without a 5 GB
    # download: stand in for InstallESD.dmg by pinning the checksum to it.
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media"
    printf 'pretend installer\n' > "$dir/media/InstallESD.dmg"
    sum=$(sha256sum "$dir/media/InstallESD.dmg" | cut -d' ' -f1)
    run env MQG_IMAGE_DIR="$dir" MQG_INSTALLESD_SHA256="$sum" \
        "$REPO/media/fetch-installesd.sh"
    [ "$status" -eq 0 ]
    # The path is the last line: progress notes go to stderr, which bats
    # merges into $output.
    [ "${lines[${#lines[@]}-1]}" = "$dir/media/InstallESD.dmg" ]
    # Untouched, not re-fetched.
    run cat "$dir/media/InstallESD.dmg"
    [ "$output" = "pretend installer" ]
}

@test "fetch-installesd.sh rejects an already-present file that fails verification" {
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media"
    printf 'corrupted\n' > "$dir/media/InstallESD.dmg"
    run env MQG_IMAGE_DIR="$dir" \
        MQG_INSTALLESD_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        "$REPO/media/fetch-installesd.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
    # It says what is wrong rather than silently deleting 5 GB.
    [ -f "$dir/media/InstallESD.dmg" ]
}

@test "fetch-installesd.sh never renames an unverified download into place" {
    # The point of the whole script: a partial or substituted download must
    # not become InstallESD.dmg. Serve it something wrong and check.
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media" "$BATS_TEST_TMPDIR/fake"
    printf 'not the installer\n' > "$BATS_TEST_TMPDIR/fake/payload"
    run env MQG_IMAGE_DIR="$dir" \
        MQG_INSTALLESD_URL="file://$BATS_TEST_TMPDIR/fake/payload" \
        "$REPO/media/fetch-installesd.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
    [ ! -f "$dir/media/InstallESD.dmg" ]
}

@test "build-installer-img.sh reports the layout it will create" {
    run "$REPO/media/build-installer-img.sh" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"OS X Base System"* ]]
    [[ "$output" == *"AF00"* ]]
}

@test "build-installer-img.sh --describe touches nothing" {
    dir="$BATS_TEST_TMPDIR/img"
    mkdir -p "$dir"
    run env MQG_IMAGE_DIR="$dir" "$REPO/media/build-installer-img.sh" --describe
    [ "$status" -eq 0 ]
    # Not even the media directory: describing is a read of our own
    # intentions, not the first step of a build.
    [ ! -e "$dir/media" ]
}

@test "build-installer-img.sh sizes its partition from the reference" {
    # The Mac-produced reference's HFS+ partition is 6,550,020,096 bytes,
    # which is what get.sh's hdiutil resize asks for. Guessing a size here
    # would be guessing at whether the packages fit.
    run "$REPO/media/build-installer-img.sh" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"6550020096"* ]]
}

@test "build-installer-img.sh fails clearly without InstallESD.dmg" {
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/empty" \
        "$REPO/media/build-installer-img.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"InstallESD"* ]]
}

@test "build-installer-img.sh refuses to clobber an existing image" {
    mkdir -p "$BATS_TEST_TMPDIR/img/media"
    : > "$BATS_TEST_TMPDIR/img/media/InstallESD.dmg"
    : > "$BATS_TEST_TMPDIR/img/media/installer-linux.img"
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/img" \
        "$REPO/media/build-installer-img.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exists"* ]]
}

@test "verify-installer-img.sh reports missing files as a failure" {
    # Two trees, one deliberately missing a file.
    mkdir -p "$BATS_TEST_TMPDIR/a/System/Installation" "$BATS_TEST_TMPDIR/b/System/Installation"
    printf 'x\n' > "$BATS_TEST_TMPDIR/a/System/Installation/OSInstall.mpkg"
    run "$REPO/media/verify-installer-img.sh" --compare-trees \
        "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    [ "$status" -ne 0 ]
    [[ "$output" == *"OSInstall.mpkg"* ]]
}

@test "verify-installer-img.sh passes for identical trees" {
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    printf 'x\n' > "$BATS_TEST_TMPDIR/a/f"; printf 'x\n' > "$BATS_TEST_TMPDIR/b/f"
    run "$REPO/media/verify-installer-img.sh" --compare-trees \
        "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    [ "$status" -eq 0 ]
}

@test "verify-installer-img.sh names the files an install cannot proceed without" {
    run "$REPO/media/verify-installer-img.sh" --required
    [ "$status" -eq 0 ]
    [[ "$output" == *"boot.efi"* ]]
    [[ "$output" == *"OSInstall.mpkg"* ]]
    [[ "$output" == *"BaseSystem.dmg"* ]]
}

@test "verify-installer-img.sh requires all sixteen packages" {
    run "$REPO/media/verify-installer-img.sh" --required
    [ "$status" -eq 0 ]
    run bash -c "'$REPO/media/verify-installer-img.sh' --required \
        | grep -c 'System/Installation/Packages/'"
    [ "$output" = "16" ]
}

@test "verify-installer-img.sh reports a size that differs, not just a name that matches" {
    # A file present on both sides but larger in the build is the signal
    # the plan asks for: an HFS+-compressed file copied decompressed.
    mkdir -p "$BATS_TEST_TMPDIR/a/d" "$BATS_TEST_TMPDIR/b/d"
    printf 'small\n' > "$BATS_TEST_TMPDIR/a/d/sample.txt"
    printf 'much much bigger\n' > "$BATS_TEST_TMPDIR/b/d/sample.txt"
    run "$REPO/media/verify-installer-img.sh" --compare-trees \
        "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    [[ "$output" == *"size"* ]]
    [[ "$output" == *"d/sample.txt"* ]]
}

@test "verify-installer-img.sh is not fooled by Unicode normalization" {
    # HFS+ stores decomposed names; 7z hands them back composed. Comparing
    # the bytes would report every localized filename as missing.
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    printf 'x\n' > "$BATS_TEST_TMPDIR/a/$(printf 'Modern\xc3\xad')"
    printf 'x\n' > "$BATS_TEST_TMPDIR/b/$(printf 'Moderni\xcc\x81')"
    run "$REPO/media/verify-installer-img.sh" --compare-trees \
        "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    [ "$status" -eq 0 ]
}

@test "verify-installer-img.sh fails clearly when an image is missing" {
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/empty" \
        "$REPO/media/verify-installer-img.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"installer-linux.img"* ]]
}

@test "build-installer-img.sh checks the media against Apple, not against itself" {
    # A finished rsync proves nothing: three media builds in six produced a
    # corrupt copy of Apple's 3.2 GB Essentials.pkg with rsync reporting
    # success, and the install found out minutes later. See NOTES.md,
    # Task 34.
    #
    # Checked after the volume has been unmounted and the ownership pass
    # has run, on a FRESH mount -- the first version read the page cache of
    # the mount that had just written the file, and passed on a build whose
    # media was corrupt. And checked against media/apple-packages.sha256
    # rather than against checksums taken from the ESD during this run,
    # which cannot catch a conversion that was already wrong.
    run grep -c 'check_esd_packages' "$REPO/media/build-installer-img.sh"
    [ "$output" -ge 2 ]
    run grep -c 'verify_media_packages' "$REPO/media/build-installer-img.sh"
    [ "$output" -ge 2 ]
    # The verification must happen after the ownership pass, not before:
    # the microVM mounts the volume, and a check that ran first would not
    # cover it. Compare the line numbers of the last call to each.
    own=$(grep -n '^fix_media_ownership ' \
        "$REPO/media/build-installer-img.sh" | tail -1 | cut -d: -f1)
    ver=$(grep -n 'verify_media_packages$' \
        "$REPO/media/build-installer-img.sh" | tail -1 | cut -d: -f1)
    [ -n "$own" ]
    [ -n "$ver" ]
    [ "$ver" -gt "$own" ]
}

@test "Apple's pinned checksums cover exactly the packages an install needs" {
    # The two lists must not drift: REQUIRED says what has to be on the
    # media, apple-packages.sha256 says what those files must contain.
    pinned=$(grep -v '^#' "$REPO/media/apple-packages.sha256" \
        | awk '{ print $2 }' | sed 's|^\./||' | LC_ALL=C sort)
    required=$("$REPO/media/verify-installer-img.sh" --required \
        | grep '^System/Installation/Packages/' \
        | sed 's|^System/Installation/Packages/||' | LC_ALL=C sort)
    [ "$pinned" = "$required" ]
    [ "$(printf '%s\n' "$pinned" | grep -c .)" -eq 16 ]
}

@test "every pinned checksum is a sha256, in sha256sum's own format" {
    while read -r sum name; do
        [[ "$sum" =~ ^[0-9a-f]{64}$ ]]
        [[ "$name" == ./* ]]
    done < <(grep -v '^#' "$REPO/media/apple-packages.sha256")
}

@test "--check-packages names the package that is wrong" {
    # The check that the media build now runs twice. A directory holding a
    # file with the right NAME and the wrong CONTENT is exactly the failure
    # that a finished rsync and matching byte counts both report as
    # success.
    dir="$BATS_TEST_TMPDIR/pkgs"
    mkdir -p "$dir"
    printf 'not what Apple shipped\n' > "$dir/Essentials.pkg"
    run "$REPO/media/verify-installer-img.sh" --check-packages "$dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Essentials.pkg: FAILED"* ]]
    [[ "$output" == *"does not hold what Apple shipped"* ]]
}

@test "--check-packages needs a directory that exists" {
    run "$REPO/media/verify-installer-img.sh" --check-packages \
        "$BATS_TEST_TMPDIR/nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such directory"* ]]
}

@test "content-digest.sh explains itself and needs an image" {
    run "$REPO/media/content-digest.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--list"* ]]
    run "$REPO/media/content-digest.sh"
    [ "$status" -ne 0 ]
    run "$REPO/media/content-digest.sh" /nonexistent.img
    [ "$status" -ne 0 ]
}

@test "the content digest skips what booting a volume leaves behind" {
    # macOS creates .Spotlight-V100 on the installer media the first time a
    # guest boots it, with a fresh UUID in the directory name. That made two
    # media built from one ESD produce different digests while every one of
    # their 39,413 real files matched. See NOTES.md, P4 Task 8.
    for d in .Spotlight-V100 .fseventsd .Trashes; do
        run grep -c -- "$d" "$REPO/media/content-digest.sh"
        [ "$output" -ge 1 ] || { echo "digest does not skip $d"; return 1; }
    done
}

@test "the content digest reports unreadable files rather than dying on them" {
    # BaseSystem ships /.file at mode 0000 -- the marker OS X looks for to
    # decide a volume has a filesystem on it. One sha256sum per file also
    # took five minutes for 39,000 files, against twenty seconds for one
    # xargs, so the bulk path has to stay.
    run grep -c 'UNREADABLE' "$REPO/media/content-digest.sh"
    [ "$output" -ge 1 ]
    run grep -c 'xargs' "$REPO/media/content-digest.sh"
    [ "$output" -ge 1 ]
}
