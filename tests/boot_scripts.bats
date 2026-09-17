#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # A PATH containing only our stubs, so a missing stub really is missing
    # rather than falling through to the real tool elsewhere on this host.
    # prereqs.sh itself is `#!/usr/bin/env bash` (env needs to find bash in
    # that same restricted PATH) and uses external `dirname` to locate its
    # own repo root before it ever gets to checking REQUIRED. Symlink just
    # those two in, rather than widening the PATH to their real directory
    # (/usr/bin), which would also expose every real tool living next to
    # them -- nasm, gcc, iasl, ... -- and defeat the "missing tool" tests.
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    ln -s "$(command -v bash)" "$STUB_BIN/bash"
    ln -s "$(command -v dirname)" "$STUB_BIN/dirname"
}

@test "prereqs.sh reports success when everything it needs is present" {
    # PATH containing stubs for every required tool.
    for t in gcc make git python3 nasm iasl mtools sgdisk mcopy mformat; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    run env PATH="$STUB_BIN" "$REPO/boot/prereqs.sh"
    [ "$status" -eq 0 ]
}

@test "prereqs.sh names every missing tool, not just the first" {
    for t in gcc make git python3 mtools sgdisk mcopy mformat; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    run env PATH="$STUB_BIN" "$REPO/boot/prereqs.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nasm"* ]]
    [[ "$output" == *"iasl"* ]]
}

@test "prereqs.sh names the packages to install, not just the binaries" {
    for t in gcc make git python3 mtools sgdisk mcopy mformat; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    run env PATH="$STUB_BIN" "$REPO/boot/prereqs.sh"
    [[ "$output" == *"acpica-tools"* ]]
}

@test "prereqs.sh does not attempt to install anything" {
    # A stub apt-get that fails loudly if called at all.
    for t in gcc make git python3 nasm iasl mtools sgdisk mcopy mformat; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    printf '#!/bin/sh\necho CALLED-APT >&2\nexit 42\n' > "$STUB_BIN/apt-get"
    printf '#!/bin/sh\necho CALLED-SUDO >&2\nexit 42\n' > "$STUB_BIN/sudo"
    chmod +x "$STUB_BIN/apt-get" "$STUB_BIN/sudo"
    run env PATH="$STUB_BIN" "$REPO/boot/prereqs.sh"
    [[ "$output" != *"CALLED-APT"* ]]
    [[ "$output" != *"CALLED-SUDO"* ]]
}

@test "fetch-opencorepkg.sh refuses an unpinned checksum" {
    # The name here must match what fetch-opencorepkg.sh looks up
    # (opencorepkg-src, per vendor/sources.tsv) -- a mismatched name would
    # die with "no such source" instead, which is a different failure than
    # the one this test means to exercise.
    printf '%s\n' \
        '# name	url	sha256' \
        'opencorepkg-src	https://example.invalid/oc.tar.gz	TOFU' \
        > "$BATS_TEST_TMPDIR/sources.tsv"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        MQG_REQUIRE_PINNED=1 \
        "$REPO/boot/fetch-opencorepkg.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not pinned"* ]]
}

@test "fetch-opencorepkg.sh reports the tag it is pinned to" {
    run "$REPO/boot/fetch-opencorepkg.sh" --show-version
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0.7"* ]]
}

@test "build-opencore.sh fails clearly when the source tree is absent" {
    run env MQG_BUILD_DIR="$BATS_TEST_TMPDIR/nonexistent" \
        "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"source tree"* ]]
}

@test "build-opencore.sh lists the artifacts it intends to produce" {
    run "$REPO/boot/build-opencore.sh" --list-artifacts
    [ "$status" -eq 0 ]
    [[ "$output" == *"OpenCore.efi"* ]]
    [[ "$output" == *"BOOTx64.efi"* ]]
    [[ "$output" == *"OpenHfsPlus.efi"* ]]
    [[ "$output" == *"OpenRuntime.efi"* ]]
}

# --- pinned, offline OpenCore build -----------------------------------
#
# build_oc.tool's last act used to be
#   src=$(curl -LfsS https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh) && eval "$src"
# and the script that came back cloned acidanthera/audk at master. Two of
# three build inputs floated and fetched shell ran at build time. These
# tests are the guard rail on the fix.

@test "build-opencore.sh pins every EDK II input to a commit, not a branch" {
    run "$REPO/boot/build-opencore.sh" --show-pins
    [ "$status" -eq 0 ]
    # ocbuild, for efibuild.sh...
    [[ "$output" == *"ocbuild-efibuild"$'\t'"e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a"* ]]
    # ...and acidanthera/audk, the EDK II base.
    [[ "$output" == *"audk-src"$'\t'"0672a009e9ca85753d240324d761341adf0291b3"* ]]
    # No pin may be a branch name: every one is a full 40-hex commit.
    local lines=0
    while IFS=$'\t' read -r name commit; do
        [ -n "$name" ]
        [[ "$commit" =~ ^[0-9a-f]{40}$ ]]
        lines=$(( lines + 1 ))
    done <<< "$output"
    [ "$lines" -ge 2 ]
}

@test "every input build-opencore.sh pins has a real checksum in sources.tsv" {
    run "$REPO/boot/build-opencore.sh" --show-pins
    [ "$status" -eq 0 ]
    while IFS=$'\t' read -r name _commit; do
        sha=$(awk -F'\t' -v n="$name" \
            '$0 !~ /^#/ && $1 == n { print $3; exit }' "$REPO/vendor/sources.tsv")
        # A name with no row at all is as broken as an unpinned one.
        [ -n "$sha" ]
        [ "$sha" != "TOFU" ]
        [[ "$sha" =~ ^[0-9a-f]{64}$ ]]
    done <<< "$output"
}

@test "sources.tsv points every pinned input at its pinned commit" {
    run "$REPO/boot/build-opencore.sh" --show-pins
    [ "$status" -eq 0 ]
    while IFS=$'\t' read -r name commit; do
        url=$(awk -F'\t' -v n="$name" \
            '$0 !~ /^#/ && $1 == n { print $2; exit }' "$REPO/vendor/sources.tsv")
        [[ "$url" == *"$commit"* ]]
    done <<< "$output"
}

@test "nothing in the build path fetches from a mutable branch" {
    # The regression guard. Shell scripts are checked whole; patches are
    # checked on their added lines only, since a *removed* line naming
    # ocbuild's master branch is precisely the fix.
    hits=$(
        {
            find "$REPO/boot" "$REPO/lib" "$REPO/bin" -name '*.sh' -print0 \
                | xargs -0 grep -HnE \
                    'raw\.githubusercontent\.com/[^/]+/[^/]+/(master|main)/' || true
            for p in "$REPO"/boot/patches/*.patch; do
                [ -e "$p" ] || continue
                grep -n '^+' "$p" \
                    | grep -E 'raw\.githubusercontent\.com/[^/]+/[^/]+/(master|main)/' \
                    | sed "s|^|$p:|" || true
            done
        }
    )
    [ -z "$hits" ]
}

@test "build-opencore.sh refuses a source whose URL names a different commit" {
    mkdir -p "$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7"
    printf '%s\n' \
        '# name	url	sha256' \
        'ocbuild-efibuild	https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh	'"$(printf '%064d' 0)" \
        > "$BATS_TEST_TMPDIR/sources.tsv"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not name commit"* ]]
}

@test "build-opencore.sh refuses an unpinned checksum" {
    mkdir -p "$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7"
    printf '%s\n' \
        '# name	url	sha256' \
        'ocbuild-efibuild	https://raw.githubusercontent.com/acidanthera/ocbuild/e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a/efibuild.sh	TOFU' \
        > "$BATS_TEST_TMPDIR/sources.tsv"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not pinned"* ]]
}

@test "build-opencore.sh says which fetch script to run when an input is absent" {
    mkdir -p "$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7"
    run env MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"fetch-edk2.sh"* ]]
}

@test "fetch-edk2.sh takes its list from the build script's pins" {
    run "$REPO/boot/fetch-edk2.sh" --list-sources
    [ "$status" -eq 0 ]
    run "$REPO/boot/build-opencore.sh" --show-pins
    pins=$(printf '%s\n' "$output" | cut -f1)
    run "$REPO/boot/fetch-edk2.sh" --list-sources
    [ "$output" = "$pins" ]
}

@test "fetch-edk2.sh refuses an unpinned checksum" {
    printf '%s\n' \
        '# name	url	sha256' \
        'ocbuild-efibuild	https://example.invalid/efibuild.sh	TOFU' \
        > "$BATS_TEST_TMPDIR/sources.tsv"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        MQG_REQUIRE_PINNED=1 \
        "$REPO/boot/fetch-edk2.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not pinned"* ]]
}

@test "the build_oc.tool patch removes the fetch and adds no new one" {
    p="$REPO/boot/patches/0001-build_oc-source-pinned-efibuild.patch"
    [ -f "$p" ]
    # The curl line goes away...
    grep -q '^-src=\$(curl .*ocbuild/master/efibuild.sh' "$p"
    # ...and what replaces it reads a local file.
    grep -q '^+src=\$(cat "\${EFIBUILD_SH}")' "$p"
}
