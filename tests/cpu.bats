#!/usr/bin/env bats
#
# The guest CPU tested-options table (lib/cpu.sh, docs/decisions/0009).
#
# The same discipline as tests/compiler.bats: the verdict function is pure,
# so every branch is exercised on a host with one CPU, and the constants are
# asserted so that a change to the table cannot quietly leave the ADR, the
# ledger and docs/test-hosts.md describing something else.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/cpu.sh"
}

# --- what the table IS ------------------------------------------------------

# The numbers and statuses here are duplicated on purpose. They are also
# written down in docs/decisions/0009, docs/host-profile.md (G3, G25) and
# docs/test-hosts.md, and a change here that does not update those leaves a
# claim with nothing behind it. If you are here because this test failed,
# that is the reminder.
@test "the default is the line two full installs were done on" {
    [ "$MQG_CPU_DEFAULT" = 'Penryn,+ssse3,+sse4.1,+sse4.2' ]
    run cpu_line_verdict "$MQG_CPU_DEFAULT"
    [ "$status" -eq 0 ]
    [[ "$output" == VERIFIED* ]]
}

@test "Conroe is BOOTED, not VERIFIED: nothing has been installed on it" {
    run cpu_line_verdict Conroe
    [ "$status" -eq 0 ]
    [[ "$output" == BOOTED* ]]
    [[ "$output" == *"SSSE3"* ]]
    [[ "$output" == *"INSTALLED"* ]]
}

@test "bare Penryn is BOOTED and the row says it has no SSE4.2" {
    run cpu_line_verdict Penryn
    [ "$status" -eq 0 ]
    [[ "$output" == BOOTED* ]]
    [[ "$output" == *"no SSE4.2"* ]]
}

@test "everything nobody has booted says NOT-TESTED" {
    local m
    for m in Nehalem Westmere SandyBridge IvyBridge Haswell-noTSX host qemu64; do
        run cpu_line_verdict "$m"
        [ "$status" -eq 0 ]
        [[ "$output" == NOT-TESTED* ]] || {
            echo "$m reported: $output"
            return 1
        }
    done
}

# The whole point of the P5 note: one record of the question, not two.
@test "the Haswell-noTSX row tells P5 to fill in this table" {
    run cpu_line_verdict Haswell-noTSX
    [[ "$output" == *"P5"* ]]
    [[ "$output" == *"0009"* ]]
}

# --- the list is guidance, not a whitelist ----------------------------------

@test "an arbitrary -cpu string is UNLISTED, never an error" {
    run cpu_line_verdict 'EPYC-Rome,+invtsc'
    [ "$status" -eq 0 ]
    [[ "$output" == UNLISTED* ]]
    [[ "$output" == *"not a refusal"* ]]
}

@test "cpu_line_check never dies, whatever it is handed" {
    local m
    for m in "$MQG_CPU_DEFAULT" Conroe Nehalem 'nonsense-not-a-cpu'; do
        run cpu_line_check "$m"
        [ "$status" -eq 0 ] || {
            echo "cpu_line_check died on $m: $output"
            return 1
        }
    done
}

@test "an unlisted line is warned about and the known-good lines are named" {
    run cpu_line_check 'nonsense-not-a-cpu'
    [ "$status" -eq 0 ]
    [[ "$output" == *"guidance, not a whitelist"* ]]
    [[ "$output" == *"Conroe"* ]]
}

# --- matching is exact, and that is deliberate ------------------------------

# "Penryn" and "Penryn,+sse4.2" are different CPUs. A prefix or substring
# match would report one row's evidence as the other's, which is exactly
# the confusion this file exists to prevent.
@test "a flagged line does not inherit the bare model's row" {
    run cpu_line_verdict 'Penryn,+sse4.2'
    [[ "$output" == UNLISTED* ]]
}

@test "cpu_model_base strips flags so a probe can ask QEMU about the model" {
    run cpu_model_base 'Penryn,+ssse3,+sse4.1,+sse4.2'
    [ "$output" = Penryn ]
    run cpu_model_base Conroe
    [ "$output" = Conroe ]
}

# --- the manifest line ------------------------------------------------------

@test "the manifest line carries the status word and the evidence" {
    run cpu_line_manifest "$MQG_CPU_DEFAULT"
    [ "$status" -eq 0 ]
    [[ "$output" == VERIFIED\ --* ]]
    [[ "$output" == *"squirrel-zapper"* ]]
}

@test "an image built on an untested model says so in its manifest" {
    run cpu_line_manifest 'Haswell-noTSX'
    [[ "$output" == NOT-TESTED\ --* ]]
    [[ "$output" == *"not the same as knowing it fails"* ]]
}

# --- the table and its consumers stay in step -------------------------------

@test "every row has three fields and a status the verdict understands" {
    local line st
    while IFS=$'\t' read -r line st _; do
        [ -n "$line" ]
        case $st in
            VERIFIED|BOOTED|EXPECTED|NOT-TESTED) ;;
            *) echo "row '$line' has unknown status '$st'"; return 1 ;;
        esac
    done < <(cpu_models)
}

@test "cpu_model_lines lists every row and nothing else" {
    local n_rows n_lines
    n_rows=$(cpu_models | wc -l)
    n_lines=$(cpu_model_lines | wc -l)
    [ "$n_rows" -eq "$n_lines" ]
    [ "$n_rows" -ge 3 ]
}

@test "build-image takes its default from the table" {
    run grep -q 'cpu=\$MQG_CPU_DEFAULT' "$REPO/image/build-image.sh"
    [ "$status" -eq 0 ]
}
