#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/preconditions.sh"
}

@test "check_result formats a pass row" {
    run check_result PASS "kvm" "/dev/kvm is writable"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" == *"kvm"* ]]
}

@test "cpu_vendor_verdict passes for GenuineIntel" {
    run cpu_vendor_verdict "GenuineIntel"
    [ "$status" -eq 0 ]
    [[ "$output" == PASS* ]]
}

@test "cpu_vendor_verdict fails for AuthenticAMD and explains why" {
    run cpu_vendor_verdict "AuthenticAMD"
    [ "$status" -eq 0 ]
    [[ "$output" == FAIL* ]]
    [[ "$output" == *"AMD"* ]]
}

@test "ignore_msrs_verdict passes when set to Y" {
    run ignore_msrs_verdict "Y"
    [ "$status" -eq 0 ]
    [[ "$output" == PASS* ]]
}

@test "ignore_msrs_verdict warns when set to N and says it needs sudo" {
    run ignore_msrs_verdict "N"
    [ "$status" -eq 0 ]
    [[ "$output" == WARN* ]]
    [[ "$output" == *"sudo"* ]]
}

@test "ovmf_verdict passes when both code and vars are present" {
    mkdir -p "$BATS_TEST_TMPDIR/OVMF"
    touch "$BATS_TEST_TMPDIR/OVMF/OVMF_CODE_4M.fd" \
          "$BATS_TEST_TMPDIR/OVMF/OVMF_VARS_4M.fd"
    run ovmf_verdict "$BATS_TEST_TMPDIR/OVMF"
    [ "$status" -eq 0 ]
    [[ "$output" == PASS* ]]
}

@test "ovmf_verdict fails when the directory is empty" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run ovmf_verdict "$BATS_TEST_TMPDIR/empty"
    [ "$status" -eq 0 ]
    [[ "$output" == FAIL* ]]
}

@test "verdicts_exit_code is 0 when nothing failed" {
    run verdicts_exit_code "PASS a
WARN b
PASS c"
    [ "$status" -eq 0 ]
}

@test "verdicts_exit_code is non-zero when anything failed" {
    run verdicts_exit_code "PASS a
FAIL b"
    [ "$status" -ne 0 ]
}

# Regression: verdicts_exit_code used to pipe into `grep -q '^FAIL'`. grep -q
# exits on first match, SIGPIPEing the writer; with `set -o pipefail` the
# pipeline reported 141 and the function returned 0 -- GO, because it found a
# FAIL. The failure needs a long list with the FAIL early, which is exactly
# why short test inputs missed it.
@test "verdicts_exit_code catches a FAIL early in a long list" {
    long="FAIL first-check something went wrong"
    for i in $(seq 200); do
        long="$long
PASS filler-$i all good here with enough text to fill the pipe buffer"
    done
    run verdicts_exit_code "$long"
    [ "$status" -ne 0 ]
}

@test "verdicts_exit_code catches a FAIL late in a long list" {
    long="PASS first-check fine"
    for i in $(seq 200); do
        long="$long
PASS filler-$i all good here"
    done
    long="$long
FAIL last-check broken"
    run verdicts_exit_code "$long"
    [ "$status" -ne 0 ]
}

@test "verdicts_exit_code does not match FAIL appearing mid-line" {
    run verdicts_exit_code "PASS note the word FAIL inside a detail field
PASS another"
    [ "$status" -eq 0 ]
}
