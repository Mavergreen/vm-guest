#!/usr/bin/env bats
#
# The declared host-compiler range (lib/compiler.sh, docs/decisions/0004).
#
# Every branch is exercised on a host that has exactly one compiler, which
# is what MQG_COMPILER and the pure verdict function are for. A range check
# nobody could test without installing three GCCs would be a range check
# nobody tested.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/compiler.sh"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
}

# stub_gcc <first line of --version> -- a `gcc` first on PATH that says so.
# Real detection then has something to detect, so the tests below cover
# compiler_banner and not only the override.
stub_gcc() {
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$STUB_BIN/gcc"
    chmod +x "$STUB_BIN/gcc"
}

# --- what the range IS ------------------------------------------------------

# This test exists to make the range's evidence and the range itself move
# together. The numbers are duplicated on purpose: they are written down in
# docs/decisions/0004, INGREDIENTS.md and docs/host-profile.md G22, and a
# change here that does not update those leaves a claim with nothing behind
# it. If you are here because this test failed, that is the reminder.
@test "the declared range is gcc 13-14, verified only at 13.3.0" {
    [ "$MQG_CC_FAMILY" = gcc ]
    [ "$MQG_CC_FLOOR" -eq 13 ]
    [ "$MQG_CC_CEILING" -eq 14 ]
    [ "$MQG_CC_VERIFIED" = 13.3.0 ]
}

# The point of the whole option: the range must not imply a test that never
# happened. 13.3.0 is the only version anyone has built with; GCC 15 is the
# version that MOTIVATED this work and is still unverified, so it is outside.
@test "the range text says which version was actually verified" {
    run compiler_range_text
    [[ "$output" == *"verified only at gcc 13.3.0"* ]]
}

@test "gcc 15 is not claimed as supported until someone builds with it" {
    run compiler_range_verdict gcc 15.1.1
    [[ "$output" == ABOVE* ]]
}

# --- parsing ---------------------------------------------------------------

@test "compiler_parse reads a Debian/Ubuntu gcc banner" {
    run compiler_parse "gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0"
    [ "$status" -eq 0 ]
    [[ "$output" == "gcc	13.3.0	"* ]]
}

# Arch's banner has a build date after the version, and the version itself
# is three-part: "gcc (GCC) 15.1.1 20250425". The first bare dotted number
# is the version; the packaging field is not one.
@test "compiler_parse reads an Arch gcc banner with a trailing date" {
    run compiler_parse "gcc (GCC) 15.1.1 20250425"
    [ "$status" -eq 0 ]
    [[ "$output" == "gcc	15.1.1	"* ]]
}

@test "compiler_parse reads gcc invoked as cc" {
    run compiler_parse "cc (Debian 12.2.0-14) 12.2.0"
    [ "$status" -eq 0 ]
    [[ "$output" == "gcc	12.2.0	"* ]]
}

# The macOS trap: `gcc` there is clang wearing gcc's name. Parsing that as
# GCC would compare clang's version number against a GCC range and answer
# confidently and wrongly.
@test "compiler_parse calls Apple's gcc what it is, which is clang" {
    run compiler_parse "Apple clang version 17.0.0 (clang-1700.0.13.3)"
    [ "$status" -eq 0 ]
    [[ "$output" == "clang	17.0.0	"* ]]
}

@test "compiler_parse reads a plain clang banner" {
    run compiler_parse "clang version 18.1.8 (Fedora 18.1.8-1.fc40)"
    [ "$status" -eq 0 ]
    [[ "$output" == "clang	18.1.8	"* ]]
}

# The override's shape, which is not a banner shape.
@test "compiler_parse reads the MQG_COMPILER form" {
    run compiler_parse "gcc 13.3.0"
    [ "$status" -eq 0 ]
    [[ "$output" == "gcc	13.3.0	"* ]]
}

@test "compiler_parse says unknown rather than guessing" {
    run compiler_parse "frobnicator wizard edition"
    [ "$status" -eq 0 ]
    [[ "$output" == "unknown		frobnicator wizard edition" ]]
}

@test "compiler_parse survives an empty banner" {
    run compiler_parse ""
    [ "$status" -eq 0 ]
    [[ "$output" == "unknown"* ]]
}

# --- the verdict, at the edges ---------------------------------------------

@test "one major below the floor is BELOW" {
    run compiler_range_verdict gcc "$(( MQG_CC_FLOOR - 1 )).9.9"
    [ "$status" -eq 0 ]
    [[ "$output" == BELOW* ]]
}

@test "the floor itself is INSIDE" {
    run compiler_range_verdict gcc "$MQG_CC_FLOOR.0.0"
    [ "$status" -eq 0 ]
    [[ "$output" == INSIDE* ]]
}

@test "the verified version is INSIDE" {
    run compiler_range_verdict gcc "$MQG_CC_VERIFIED"
    [ "$status" -eq 0 ]
    [[ "$output" == INSIDE* ]]
}

@test "the ceiling itself is INSIDE" {
    run compiler_range_verdict gcc "$MQG_CC_CEILING.2.0"
    [ "$status" -eq 0 ]
    [[ "$output" == INSIDE* ]]
}

@test "one major above the ceiling is ABOVE" {
    run compiler_range_verdict gcc "$(( MQG_CC_CEILING + 1 )).0.0"
    [ "$status" -eq 0 ]
    [[ "$output" == ABOVE* ]]
}

# clang is a real answer, just not one the range covers: this project
# builds with TOOLCHAINS=GCC and has never built with clang. Saying UNKNOWN
# is the honest report; saying INSIDE or BELOW would be a claim.
@test "clang gets UNKNOWN, not a verdict against the gcc range" {
    run compiler_range_verdict clang 17.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == UNKNOWN* ]]
    [[ "$output" == *clang* ]]
}

@test "an unrecognised compiler gets UNKNOWN" {
    run compiler_range_verdict unknown ""
    [ "$status" -eq 0 ]
    [[ "$output" == UNKNOWN* ]]
}

@test "a version that is not a number gets UNKNOWN, not a comparison" {
    run compiler_range_verdict gcc "trunk"
    [ "$status" -eq 0 ]
    [[ "$output" == UNKNOWN* ]]
}

# --- detection, through a stub compiler ------------------------------------

@test "detection reads the compiler on PATH" {
    stub_gcc "gcc (GCC) 15.1.1 20250425"
    run env PATH="$STUB_BIN:$PATH" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_status"
    [ "$status" -eq 0 ]
    [[ "$output" == ABOVE* ]]
    [[ "$output" == *15.1.1* ]]
}

# "I cannot tell" is its own outcome: it names what it could not read.
@test "an unparseable compiler is reported with what it actually said" {
    stub_gcc "frobnicator wizard edition"
    run env PATH="$STUB_BIN:$PATH" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_status"
    [ "$status" -eq 0 ]
    [[ "$output" == UNKNOWN* ]]
    [[ "$output" == *"frobnicator wizard edition"* ]]
}

# A missing compiler is not this check's failure to report -- boot/prereqs.sh
# is what says gcc is missing, and it says it as one of twelve tools.
#
# GCC_BIN is also the prefix EDK II itself uses to find the compiler
# (DEF(GCC_X64_PREFIX) is ENV(GCC_BIN)), so pointing it at nothing is both
# how this test removes the compiler and a check that we ask about the same
# binary the build will run.
@test "no compiler at all is UNKNOWN, not a failure" {
    run env GCC_BIN="$BATS_TEST_TMPDIR/nowhere/" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_status"
    [ "$status" -eq 0 ]
    [[ "$output" == UNKNOWN* ]]
    [[ "$output" == *"nowhere/gcc"* ]]
}

# --- the four outcomes, as the build scripts see them ----------------------

@test "inside the range, the check says so and returns" {
    run env MQG_COMPILER="gcc $MQG_CC_VERIFIED" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_check"
    [ "$status" -eq 0 ]
    [[ "$output" == *"inside"* ]]
}

# Above the ceiling the build usually SUCCEEDS and produces something else,
# which is exactly what OVMF did under C23. The warning has to say that, or
# someone up here reads a green build as proof.
@test "above the ceiling, the check warns that silence is not proof" {
    run env MQG_COMPILER="gcc $(( MQG_CC_CEILING + 1 )).1.0" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_check"
    [ "$status" -eq 0 ]
    [[ "$output" == *"untested territory"* ]]
    [[ "$output" == *"DIFFERENT firmware bytes"* ]]
    [[ "$output" == *"not proof"* ]]
}

# Below the floor is a refusal, and the refusal has to distinguish "we have
# not tested this" from "this is known to fail". It is the former.
@test "below the floor, the check fails and says it was never tested" {
    run env MQG_COMPILER="gcc $(( MQG_CC_FLOOR - 1 )).4.0" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_check"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT tested"* ]]
    [[ "$output" == *"nobody has ever tried"* ]]
    [[ "$output" == *"$(( MQG_CC_FLOOR - 1 )).4.0"* ]]
    [[ "$output" == *"gcc 13 through 14"* ]]
}

@test "an unknown compiler warns, names it, and proceeds" {
    run env MQG_COMPILER="frobnicator 0.1" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_check"
    [ "$status" -eq 0 ]
    [[ "$output" == *"frobnicator 0.1"* ]]
    [[ "$output" == *"unchecked"* ]]
}

# --- the manifest line -----------------------------------------------------

@test "the manifest line carries the verdict" {
    run env MQG_COMPILER="gcc $MQG_CC_VERIFIED" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_line"
    [ "$status" -eq 0 ]
    [[ "$output" == INSIDE* ]]
}

# An image built with the check talked out of the way has to say so, or the
# override launders an untested compiler into an apparently supported build.
@test "the manifest line records that the override was in effect" {
    run env MQG_COMPILER="gcc 99.0.0" bash -c \
        ". '$REPO/lib/common.sh'; . '$REPO/lib/compiler.sh'; compiler_range_line"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MQG_COMPILER override in effect"* ]]
}

# --- the build scripts -----------------------------------------------------

@test "build-opencore.sh refuses to start below the floor" {
    run env MQG_COMPILER="gcc $(( MQG_CC_FLOOR - 1 )).1.0" \
        MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/img" "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported compiler"* ]]
    # And it stopped THERE: no source tree was looked for, which is the
    # cheap-failure-first ordering this check is placed for.
    [[ "$output" != *"OpenCorePkg source tree"* ]]
}

@test "build-ovmf.sh refuses to start below the floor" {
    run env MQG_COMPILER="gcc $(( MQG_CC_FLOOR - 1 )).1.0" \
        MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/img" "$REPO/boot/build-ovmf.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported compiler"* ]]
    [[ "$output" != *"assembled EDK II tree"* ]]
}

# Above the ceiling it must WARN and carry on -- a project that refused
# here would refuse to build on every new distribution, which is a worse
# failure than the one it would prevent.
@test "build-opencore.sh warns above the ceiling and keeps going" {
    run env MQG_COMPILER="gcc $(( MQG_CC_CEILING + 1 )).1.0" \
        MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/img" "$REPO/boot/build-opencore.sh"
    [[ "$output" == *"untested territory"* ]]
    # It got past the check and failed on the next thing instead.
    [[ "$output" == *"OpenCorePkg source tree"* ]]
}

@test "the build scripts can report the range verdict for the manifest" {
    run "$REPO/boot/build-opencore.sh" --compiler-range
    [ "$status" -eq 0 ]
    [[ "$output" == *"supported range"* || "$output" == *"has nothing to say"* ]]
}

# The override moves the CHECK and nothing else. --compiler is provenance:
# it reports the compiler that will actually run, so an image built with
# the check overridden has a manifest whose two compiler lines disagree,
# which is the point.
@test "MQG_COMPILER does not change what the manifest records as the compiler" {
    honest=$("$REPO/boot/build-opencore.sh" --compiler)
    run env MQG_COMPILER="gcc 99.0.0" "$REPO/boot/build-opencore.sh" --compiler
    [ "$status" -eq 0 ]
    [ "$output" = "$honest" ]
    [[ "$output" != *"99.0.0"* ]]
}
