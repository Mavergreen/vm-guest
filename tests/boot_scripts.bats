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
