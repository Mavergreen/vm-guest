#!/usr/bin/env bats
#
# lib/ccache.sh -- the optional compiler cache for the firmware builds.
#
# ccache is NOT installed on the primary host, which is the whole reason
# every branch below is reachable through MQG_CCACHE_BIN: a code path whose
# input is "is this program installed" cannot be tested on a host that
# answers one way, and installing a program to test a detection is not a
# reasonable price. Same seam, and the same argument, as MQG_COMPILER in
# lib/compiler.sh and MQG_PKG_MANAGER in boot/prereqs.sh.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/ccache.sh"
    STUB="$BATS_TEST_TMPDIR/ccache"
    printf '#!/bin/sh\nexec "$@"\n' > "$STUB"
    chmod 755 "$STUB"
    unset MQG_CCACHE MQG_CCACHE_BIN
}

# --- the default is a claim, not a preference -------------------------------

@test "ccache is off by default, because nobody has measured it here" {
    # docs/decisions/0004's claim is that this boot stack is reproducible.
    # Turning a build-speed tool on by default would put that claim behind
    # an unverified one. The constant is asserted rather than the behaviour
    # alone, so changing the default is visibly changing a claim.
    [ "$MQG_CCACHE_DEFAULT" = 0 ]
    export MQG_CCACHE_BIN="$STUB"
    run ccache_status
    [[ "$output" == OFF* ]]
}

@test "an absent ccache is reported, never fatal" {
    export MQG_CCACHE_BIN="$BATS_TEST_TMPDIR/nope"
    run ccache_status
    [ "$status" -eq 0 ]
    [[ "$output" == OFF* ]]
    [[ "$output" == *"not installed"* ]]
}

@test "asking for a ccache that is not there warns and builds anyway" {
    export MQG_CCACHE=1
    export MQG_CCACHE_BIN="$BATS_TEST_TMPDIR/nope"
    run ccache_status
    [ "$status" -eq 0 ]
    [[ "$output" == MISSING* ]]
    run ccache_setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"not installed"* ]]
}

@test "MQG_CCACHE=1 with ccache present uses it" {
    export MQG_CCACHE=1
    export MQG_CCACHE_BIN="$STUB"
    run ccache_status
    [[ "$output" == USED* ]]
    [[ "$output" == *"$STUB"* ]]
}

@test "a value that is neither 1 nor 0 warns and does not use ccache" {
    export MQG_CCACHE=maybe
    export MQG_CCACHE_BIN="$STUB"
    run ccache_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"not 1 or 0"* ]]
    [[ "$output" == *OFF* ]]
}

# --- the judging half is pure ----------------------------------------------

@test "ccache_verdict judges without running or detecting anything" {
    [[ "$(ccache_verdict 1 /usr/bin/ccache)" == USED* ]]
    [[ "$(ccache_verdict 1 '')" == MISSING* ]]
    [[ "$(ccache_verdict 0 /usr/bin/ccache)" == OFF* ]]
    [[ "$(ccache_verdict 0 '')" == OFF* ]]
    # "you could turn this on" and "install it first" are different pieces
    # of advice and must not be the same sentence.
    [[ "$(ccache_verdict 0 /usr/bin/ccache)" == *"MQG_CCACHE=1"* ]]
    [[ "$(ccache_verdict 0 '')" == *"not installed"* ]]
}

# --- the shim --------------------------------------------------------------

@test "the shim wraps the real compiler by absolute path, not by name" {
    # `exec ccache gcc` in a directory that is first on PATH would find
    # itself. The real compiler is resolved before the shim is installed.
    dir="$BATS_TEST_TMPDIR/shim"
    run ccache_shim_dir "$dir" "$STUB"
    [ "$status" -eq 0 ]
    [ -x "$dir/gcc" ]
    real="$(command -v gcc)"
    grep -q -- "$STUB" "$dir/gcc"
    grep -q -- "$real" "$dir/gcc"
    [[ "$(grep exec "$dir/gcc")" != *"exec $STUB gcc "* ]]
}

@test "the shim still answers --version as the compiler it wraps" {
    # lib/compiler.sh asks `gcc --version` to decide what this host has,
    # and image/build-image.sh records the answer in the manifest. If a
    # shim changed that answer, turning ccache on would change an image's
    # recorded provenance and the stage input stamps with it.
    dir="$BATS_TEST_TMPDIR/shim"
    ccache_shim_dir "$dir" "$STUB" >/dev/null
    bare="$(gcc --version | head -1)"
    shimmed="$(PATH="$dir:$PATH" gcc --version | head -1)"
    [ "$bare" = "$shimmed" ]
}

@test "the cache goes under the build directory, never the repository" {
    # The repo is NFS at 9-15 ms per file create and a ccache directory is
    # thousands of small files: caching there would be slower than not
    # caching. It is also a build artifact, and nothing the pipeline
    # writes belongs in the checkout.
    export MQG_CCACHE=1
    export MQG_CCACHE_BIN="$STUB"
    export MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build"
    run ccache_setup
    [ "$status" -eq 0 ]
    [ -d "$MQG_BUILD_DIR/ccache" ]
    [[ "$output" == *"$MQG_BUILD_DIR/ccache"* ]]
    run git -C "$REPO" status --porcelain --ignored -- ccache ccache-bin
    [ -z "$output" ]
}

# --- what the build scripts and the manifest say ---------------------------

@test "the build scripts report whether ccache was used" {
    run "$REPO/boot/build-opencore.sh" --ccache
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    MQG_CCACHE=1 MQG_CCACHE_BIN="$STUB" run "$REPO/boot/build-opencore.sh" --ccache
    [ "$status" -eq 0 ]
}

@test "the manifest records it, so the no-effect claim stays checkable" {
    run "$REPO/image/build-image.sh" --manifest-fields
    [ "$status" -eq 0 ]
    [[ "$output" == *"ccache"* ]]
}

@test "ccache is not one of the inputs a stage reruns on" {
    # It is a build-time tool that is claimed to change nothing, so it must
    # not appear in a stage's recorded inputs -- otherwise installing it
    # would rebuild the firmware, which is the opposite of the point. The
    # compiler identity is in there and must stay: the shim answers
    # --version as the compiler it wraps, so the two are compatible.
    run "$REPO/bin/ingredient-fingerprint.sh" --stage opencore --list
    [ "$status" -eq 0 ]
    [[ "$output" != *ccache* ]]
    [[ "$output" == *compiler* ]]
}
