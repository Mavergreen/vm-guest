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
        "$REPO/assets/pins/sources.tsv")
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
    own=$(grep -n '^fix_media_ownership "' \
        "$REPO/media/build-installer-img.sh" | tail -1 | cut -d: -f1)
    ver=$(grep -n '^verify_media_packages "' \
        "$REPO/media/build-installer-img.sh" | tail -1 | cut -d: -f1)
    [ -n "$own" ]
    [ -n "$ver" ]
    [ "$ver" -gt "$own" ]
}

# --- G26: the build must not need a desktop seat -------------------------

@test "the media build attaches no loop device and mounts nothing" {
    # udisks2's polkit policy grants loop-setup to a user AT A SEAT. An
    # SSH session has none, so ap-juicer -- a headless server, and every
    # CI runner P6 will ever use -- could not build media at all. The
    # whole HFS+ assembly now happens inside the privops microVM.
    #
    # Asserted against the script rather than by running it, because the
    # failure it guards against is a host this suite is not running on.
    ! grep -qE '^[^#]*\b(udisksctl|losetup|findmnt|lsblk)\b' \
        "$REPO/media/build-installer-img.sh"
    ! grep -qE '^[^#]*\bhfs_(attach|mount|with_mounted)' \
        "$REPO/media/build-installer-img.sh"
    # hfs_create_gpt stays: it writes a plain file with mkfs.hfsplus,
    # sgdisk and dd, and needs no privilege and no mount.
    grep -q 'hfs_create_gpt' "$REPO/media/build-installer-img.sh"
}

@test "the media build refuses before dmg2img when the backend is missing" {
    # Five gigabytes of conversion, and then "the privops backend is not
    # available on this host" is how squirrel-zapper spent an hour. The
    # backend is now what builds the media at all, so it is checked first.
    check=$(grep -n 'privops_backend_missing' \
        "$REPO/media/build-installer-img.sh" | head -1 | cut -d: -f1)
    convert=$(grep -n 'dmg2img -s -i "$esd_dmg"' \
        "$REPO/media/build-installer-img.sh" | head -1 | cut -d: -f1)
    [ -n "$check" ]
    [ -n "$convert" ]
    [ "$check" -lt "$convert" ]
}

@test "the assembly payload never chowns: that is the ownership pass's job" {
    # fix-ownership.sh records the six setuid and setgid modes BEFORE the
    # chown that strips them and restores them after. A chown anywhere
    # else would run before the code that makes it reversible -- a mistake
    # that has already cost this project a full rebuild.
    ! grep -qE '^[^#]*\bchown\b' "$REPO/media/privops/assemble.sh"
    grep -q 'SPECIAL=' "$REPO/media/privops/fix-ownership.sh"
}

@test "what gets injected is staged before the ownership pass runs" {
    # Anything injected after the chown would be the one uid-1000 file on
    # otherwise root-owned media -- the state that made launchd say
    # "Dubious ownership on file (skipping)" and load nothing at all.
    asm=$(grep -n '^assemble_media$' \
        "$REPO/media/build-installer-img.sh" | tail -1 | cut -d: -f1)
    own=$(grep -n '^fix_media_ownership "' \
        "$REPO/media/build-installer-img.sh" | tail -1 | cut -d: -f1)
    [ -n "$asm" ]
    [ -n "$own" ]
    [ "$asm" -lt "$own" ]
    grep -q 'MQG_RAW3' "$REPO/media/privops/assemble.sh"
    # And the injection's status is tar's, not a pipeline's. busybox ash
    # has no pipefail, so `tar ... | sed` would report sed's success
    # whatever tar did, and the media would ship without its install
    # hooks. This project has written that lesson down twice already.
    ! grep -qE 'tar x.*\|' "$REPO/media/privops/assemble.sh"
}

@test "--check-sums holds guest-computed digests to the same constant" {
    # The host cannot read the media any more, so the digests come from
    # the microVM. The comparison is still against media/apple-packages.sha256
    # -- what Apple shipped -- and still lives in the script whose job is
    # "is this what it should be".
    sums=$BATS_TEST_TMPDIR/sums.txt
    grep -v '^#' "$REPO/media/apple-packages.sha256" \
        | sed 's|  \./|  |' > "$sums"
    run "$REPO/media/verify-installer-img.sh" --check-sums "$sums"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all 16 of Apple's packages match"* ]]

    # One wrong digest is named, not merely counted.
    sed 's/^a0609f3d/b0609f3d/' "$sums" > "$sums.bad"
    run "$REPO/media/verify-installer-img.sh" --check-sums "$sums.bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Essentials.pkg: FAILED"* ]]

    # And a package the guest never reported is MISSING, not passed over.
    grep -v 'OSInstall.mpkg' "$sums" > "$sums.short"
    run "$REPO/media/verify-installer-img.sh" --check-sums "$sums.short"
    [ "$status" -ne 0 ]
    [[ "$output" == *"OSInstall.mpkg: MISSING"* ]]
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

@test "build-installer-img.sh refuses to start beside another builder" {
    # The one corruption mechanism this project ever caught in the act: an
    # orphaned builder still rsyncing into the image a newer build had
    # started writing. Two loop devices over one backing file means two
    # page caches, each self-consistent, and a file on disk that is a mix.
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media"
    printf 'pretend installer\n' > "$dir/media/InstallESD.dmg"
    # A lock held by a process that is genuinely alive.
    sleep 30 &
    holder=$!
    mkdir "$dir/media/installer-linux.img.lock"
    printf '%s\n' "$holder" > "$dir/media/installer-linux.img.lock/pid"
    run env MQG_IMAGE_DIR="$dir" "$REPO/media/build-installer-img.sh" --force
    kill "$holder" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"is already building"* ]]
    # And it must not have touched anything on its way out.
    [ -d "$dir/media/installer-linux.img.lock" ]
    run cat "$dir/media/InstallESD.dmg"
    [ "$output" = "pretend installer" ]
}

@test "build-installer-img.sh takes over a lock whose holder is gone" {
    # A lock left by a build that died must not block every build after it.
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media"
    printf 'pretend installer\n' > "$dir/media/InstallESD.dmg"
    mkdir "$dir/media/installer-linux.img.lock"
    # A pid that cannot be running: sh -c 'exit' and reuse its number.
    sleep 0 &
    dead=$!
    wait "$dead" 2>/dev/null || true
    printf '%s\n' "$dead" > "$dir/media/installer-linux.img.lock/pid"
    run env MQG_IMAGE_DIR="$dir" "$REPO/media/build-installer-img.sh" --force
    [[ "$output" == *"stale lock"* ]]
    # It goes on to fail on the pretend ESD, which is the point: it got past
    # the lock.
    [ "$status" -ne 0 ]
    [[ "$output" != *"is already building"* ]]
}

@test "build-installer-img.sh removes its lock when it exits" {
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media"
    printf 'pretend installer\n' > "$dir/media/InstallESD.dmg"
    run env MQG_IMAGE_DIR="$dir" "$REPO/media/build-installer-img.sh" --force
    [ "$status" -ne 0 ]
    [ ! -e "$dir/media/installer-linux.img.lock" ]
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
    #
    # The walk moved into the microVM payload when the host stopped
    # mounting; the pruning had to move with it, which is the kind of thing
    # that gets dropped in a rewrite.
    for d in .Spotlight-V100 .fseventsd .Trashes; do
        run grep -c -- "$d" "$REPO/media/privops/content-digest.sh"
        [ "$output" -ge 1 ] || { echo "digest does not skip $d"; return 1; }
    done
}

@test "the content digest hashes in bulk, not one process per file" {
    # 39,000 separate sha256sum processes took five minutes here, against
    # twenty seconds for one xargs. Inside the microVM that matters more,
    # not less: busybox's sha256sum is about a third the speed of
    # coreutils', so the per-process overhead has nothing to hide behind.
    run grep -c 'xargs' "$REPO/media/privops/content-digest.sh"
    [ "$output" -ge 1 ]
}

@test "the content digest counts the files it found and the files it hashed" {
    # The old host-side walk listed a file it could not read rather than
    # skipping it, because a digest that silently omits files is a digest
    # of a different thing depending on who ran it. Inside the microVM we
    # are uid 0 and BaseSystem's mode-0000 /.file reads fine, so that
    # category is gone -- but an I/O error off a corrupt volume would still
    # make sha256sum print nothing for a file and carry on. The two counts
    # are what catches it.
    grep -q 'MQG-DIGEST-FILES' "$REPO/media/privops/content-digest.sh"
    grep -q 'MQG-DIGEST-HASHED' "$REPO/media/privops/content-digest.sh"
    # And the host must refuse when they disagree, not merely print them.
    grep -q '\[ "$files" = "$hashed" \]' "$REPO/media/content-digest.sh"
}

@test "the content digest mounts nothing on this host" {
    # It used to reach the volume through a udisks loop device, which needs
    # a desktop seat (G26) -- and image/build-image.sh calls this for every
    # manifest's `mediacontent` line with stderr discarded, so on a
    # headless host the field came out empty and nothing said why.
    ! grep -qE '^[^#]*\b(udisksctl|losetup|findmnt|lsblk)\b' \
        "$REPO/media/content-digest.sh"
    ! grep -qE '^[^#]*\bhfs_(attach|mount|unmount|detach|with_mounted|partition_dev)' \
        "$REPO/media/content-digest.sh"
    # hfs_create stays: it writes a plain file with mkfs.hfsplus and needs
    # no privilege and no mount. The microVM needs a target disk to mount.
    grep -q 'hfs_create ' "$REPO/media/content-digest.sh"
    grep -q 'privops_run' "$REPO/media/content-digest.sh"
}

@test "the content digest keeps the image read-only" {
    # A digest that rewrites the volume header of the file it is reporting
    # on is not a measurement. The old udisks mount was read-write and did
    # exactly that; `ro:` is mounted -o ro off a readonly=on virtio disk.
    grep -q '"ro:$img"' "$REPO/media/content-digest.sh"
    ! grep -q '"raw:$img"' "$REPO/media/content-digest.sh"
}
