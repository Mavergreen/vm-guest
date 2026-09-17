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
