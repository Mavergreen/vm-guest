#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "run.sh in dry-run mode prints the command without executing it" {
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" base-kvm
    [ "$status" -eq 0 ]
    [[ "$output" == *"qemu-system-x86_64"* ]]
    [[ "$output" == *"-enable-kvm"* ]]
}

@test "run.sh appends extra arguments after the profile's own" {
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" base-kvm -snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *"-snapshot"* ]]
}

@test "run.sh fails with usage when given no profile" {
    run "$REPO/vm/run.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

@test "run.sh fails for an unknown profile" {
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" no-such-profile
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such profile"* ]]
}

@test "tier-check reports clean when no profile uses the quarantine" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf '%s\n' '-enable-kvm' > "$BATS_TEST_TMPDIR/profiles/clean.args"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        "$REPO/bin/tier-check.sh"
    [ "$status" -eq 0 ]
}

@test "tier-check names a profile that references the quarantine" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf '%s\n' '-drive' 'file=%VENDOR%/efi.img' \
        > "$BATS_TEST_TMPDIR/profiles/dirty.args"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        MQG_VENDOR_DIR="$BATS_TEST_TMPDIR/vendor-reference" \
        "$REPO/bin/tier-check.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dirty"* ]]
}

@test "tier-check --strict fails when a profile references the quarantine" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf '%s\n' '-drive' 'file=%VENDOR%/efi.img' \
        > "$BATS_TEST_TMPDIR/profiles/dirty.args"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        MQG_VENDOR_DIR="$BATS_TEST_TMPDIR/vendor-reference" \
        "$REPO/bin/tier-check.sh" --strict
    [ "$status" -ne 0 ]
}

# --- Additional coverage found during verification, beyond the assigned scope ---

# base-kvm deliberately does not set -machine: profiles need to add
# properties to it (p1-reference wants q35,vmport=off), and two -machine
# flags means the last silently wins.
@test "run.sh prints exactly the expected command for base-kvm" {
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" base-kvm
    [ "$status" -eq 0 ]
    [ "$output" = "qemu-system-x86_64 -enable-kvm -m 4096 -smp 2" ]
}

@test "run.sh fails with 'expanded to nothing' for a profile that is only comments" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf '%s\n' '# nothing but a comment' '' > "$BATS_TEST_TMPDIR/profiles/onlycomments.args"
    run env PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" MQG_DRY_RUN=1 \
        "$REPO/vm/run.sh" onlycomments
    [ "$status" -ne 0 ]
    [[ "$output" == *"expanded to nothing"* ]]
}

@test "run.sh's usage message lists available profiles without itself failing" {
    run "$REPO/vm/run.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"base-kvm"* ]]
}

@test "run.sh's usage message does not fail when PROFILE_DIR has no profiles" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run env PROFILE_DIR="$BATS_TEST_TMPDIR/empty" "$REPO/vm/run.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

@test "run.sh does not append to run.log in dry-run mode" {
    rm -f "$REPO/run.log"
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" base-kvm
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/run.log" ]
}

@test "run.sh's dry-run output round-trips through the shell for args with commas, equals, and spaces" {
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" base-kvm -device 'foo,bar=1,baz=2' -name 'has space'
    [ "$status" -eq 0 ]
    eval "reconstructed=($output)"
    n=${#reconstructed[@]}
    [ "${reconstructed[$((n-1))]}" = "has space" ]
    [ "${reconstructed[$((n-2))]}" = "-name" ]
    [ "${reconstructed[$((n-3))]}" = "foo,bar=1,baz=2" ]
    [ "${reconstructed[$((n-4))]}" = "-device" ]
}

@test "tier-check checks a profile whose name contains a space, instead of silently skipping it" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf '%s\n' '-drive' 'file=%VENDOR%/x.img' \
        > "$BATS_TEST_TMPDIR/profiles/with space.args"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        MQG_VENDOR_DIR="$BATS_TEST_TMPDIR/vendor-reference" \
        "$REPO/bin/tier-check.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"with space"* ]]
}

@test "tier-check catches a reference to the quarantine that spells out the resolved path directly, not just one that goes through %VENDOR%" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf '%s\n' '-drive' "file=$BATS_TEST_TMPDIR/vendor-reference/x.img" \
        > "$BATS_TEST_TMPDIR/profiles/direct.args"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        MQG_VENDOR_DIR="$BATS_TEST_TMPDIR/vendor-reference" \
        "$REPO/bin/tier-check.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"direct"* ]]
}

@test "tier-check warns, but does not fail --strict, when there are no profiles at all" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/empty" \
        "$REPO/bin/tier-check.sh" --strict
    [ "$status" -eq 0 ]
    [[ "$output" == *"no profiles found"* ]]
}

# Regression: tier-check used to pipe into `grep -qF`. grep -q exits on first
# match, SIGPIPEing the still-writing profile_expand; under `set -o pipefail`
# the pipeline reported 141 and the `if` took the false branch *because* the
# match succeeded -- the gate reported clean exactly when it found a
# violation. It only showed up once a profile was long enough that the writer
# had not already finished, so the short profiles in the tests above passed.
@test "tier-check catches a quarantine reference early in a long profile" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    {
        printf -- '-drive\nfile=%%VENDOR%%/opencore/EFI.img\n'
        for i in $(seq 300); do
            printf -- '-device\nfiller-device-%s,with=some,long=arguments,to=fill,the=pipe\n' "$i"
        done
    } > "$BATS_TEST_TMPDIR/profiles/longdirty.args"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        MQG_VENDOR_DIR="$BATS_TEST_TMPDIR/vendor" \
        "$REPO/bin/tier-check.sh" --strict
    [ "$status" -ne 0 ]
    [[ "$output" == *"longdirty"* ]]
}
