#!/usr/bin/env bats
#
# The judging half of bin/triangulate.sh, tested against facts from hosts
# nobody here has. That is the whole reason lib/triangulate.sh is pure: the
# Woodcrest case below is docs/test-hosts.md's prediction about the Mac Pro
# 1,1, and it can be checked today, on a Coffee Lake, without waiting for
# the hardware.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/triangulate.sh"
}

# --- flag spelling ---------------------------------------------------------

@test "cpu_has_flag finds the Linux spelling" {
    run cpu_has_flag "fpu vme sse4_1 sse4_2 ssse3" sse4_1
    [ "$status" -eq 0 ]
}

@test "cpu_has_flag finds the macOS spelling of the same flag" {
    run cpu_has_flag "FPU VME SSE4.1 SSE4.2 SSSE3" sse4_1
    [ "$status" -eq 0 ]
}

@test "cpu_has_flag finds the NetBSD comma-separated spelling" {
    run cpu_has_flag "FPU,VME,SSE4.1,SSE4.2" sse4_1
    [ "$status" -eq 0 ]
}

@test "cpu_has_flag does not match a prefix" {
    run cpu_has_flag "sse4_2 ssse3" sse4_1
    [ "$status" -ne 0 ]
}

# --- accelerator choice ----------------------------------------------------

@test "accel_pick prefers kvm, then hvf, then nvmm, then tcg" {
    [ "$(accel_pick yes yes yes)" = kvm ]
    [ "$(accel_pick no yes yes)" = hvf ]
    [ "$(accel_pick no no yes)" = nvmm ]
    [ "$(accel_pick no no no)" = tcg ]
}

# --- filesystem classification ---------------------------------------------

@test "fs_is_remote knows nfs and smb and not btrfs" {
    run fs_is_remote nfs
    [ "$status" -eq 0 ]
    run fs_is_remote smbfs
    [ "$status" -eq 0 ]
    run fs_is_remote btrfs
    [ "$status" -ne 0 ]
}

@test "fs_needs_nocow is btrfs and nothing else" {
    run fs_needs_nocow btrfs
    [ "$status" -eq 0 ]
    run fs_needs_nocow ext4
    [ "$status" -ne 0 ]
    run fs_needs_nocow apfs
    [ "$status" -ne 0 ]
}

# --- the Mac Pro 1,1 prediction --------------------------------------------
#
# docs/test-hosts.md: Woodcrest is 2006 and SSE4.1 arrived with Penryn in
# 2007, so `-cpu Penryn,+sse4.1` should be rejected outright. Confirming
# the prediction is worth as much as refuting it, and either way the report
# has to say the right thing before the hardware is in front of anyone.

@test "G3 refutes on a host older than the CPU model we ask for" {
    run g3_verdict "Intel(R) Xeon(R) CPU 5150 @ 2.66GHz" no rejected
    [ "$status" -eq 0 ]
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"SSE4.1"* ]]
    [[ "$output" == *"parameter"* ]]
}

@test "G3 confirms on a host newer than the model, as on the primary host" {
    run g3_verdict "Intel(R) Core(TM) i7-8700B CPU @ 3.20GHz" yes accepted
    [ "$status" -eq 0 ]
    [[ "$output" == CONFIRM* ]]
}

@test "G3 cannot say when the cpu line was never exercised" {
    run g3_verdict "some CPU" yes unknown
    [[ "$output" == CANNOT-SAY* ]]
}

@test "G14 notices a Xeon and says what settling it would still take" {
    run g14_verdict "Intel(R) Xeon(R) CPU 5150 @ 2.66GHz"
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *"Xeon"* ]]
    [[ "$output" == *"MacPro5,1"* ]]
}

# --- the EndeavourOS host --------------------------------------------------

@test "G10 refutes on a filesystem without reflinks and says what it costs" {
    run g10_verdict ext4 no
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"full copy"* ]]
}

@test "G10 flags a filesystem that should have had reflinks but did not" {
    run g10_verdict btrfs no
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"usually"* ]]
}

@test "G11 confirms off btrfs, where the chore does not apply" {
    run g11_verdict ext4 unknown
    [[ "$output" == CONFIRM* ]]
    [[ "$output" == *"not btrfs"* ]]
}

@test "G9 calls a local repo the portable half of the entry" {
    run g9_verdict ext4 ext4
    [[ "$output" == CONFIRM* ]]
    [[ "$output" == *"local"* ]]
}

@test "G9 refutes when images would land on remote storage" {
    run g9_verdict nfs nfs
    [[ "$output" == REFUTE* ]]
}

# --- the macOS and NetBSD hosts --------------------------------------------

@test "G1 refutes on a non-Apple host and says the constraint is legal" {
    run g1_verdict "Dell Inc."
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"EULA"* ]]
    [[ "$output" == *"legal"* ]]
}

@test "G2 refutes on AMD rather than pretending it cannot judge" {
    run g2_verdict AuthenticAMD svm
    [[ "$output" == REFUTE* ]]
}

@test "G17 cannot say when /sys is not there to be read" {
    run g17_verdict unknown
    [[ "$output" == CANNOT-SAY* ]]
}

@test "G18 refutes without EPT and names the decision it blocks" {
    run g18_verdict no
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"0005"* ]]
}

# --- levels ----------------------------------------------------------------

@test "G13 cannot say from a probe, and confirms only after an install" {
    run g13_verdict yes unknown
    [[ "$output" == CANNOT-SAY* ]]
    run g13_verdict yes yes
    [[ "$output" == CONFIRM* ]]
}

@test "G20 will not claim evidence from media it only reused" {
    run g20_verdict reused
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *"reused"* ]]
}

@test "G19 is permanently cannot-say, and says why" {
    run g19_verdict
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *"two installs"* ]]
}

@test "G5 distinguishes artifacts this run built from ones it found" {
    run g5_verdict aaa bbb yes
    [[ "$output" == *"built here by this host's toolchain"* ]]
    run g5_verdict aaa bbb no
    [[ "$output" == *"already on this host"* ]]
}

# --- every verdict is one of the three -------------------------------------

@test "every judge returns a verdict from the vocabulary" {
    local line
    for line in "$(g1_verdict 'Dell Inc.')" \
                "$(g2_verdict GenuineIntel vmx)" \
                "$(g3_verdict cpu no rejected)" \
                "$(g4_verdict 4 1)" \
                "$(g5_verdict '' '' unknown)" \
                "$(g6_verdict 9.0.0)" \
                "$(g7_verdict 6.1.0)" \
                "$(g8_verdict 4096 1000)" \
                "$(g9_verdict ext4 ext4)" \
                "$(g10_verdict ext4 no)" \
                "$(g11_verdict btrfs yes)" \
                "$(g12_verdict ext4 1 1)" \
                "$(g13_verdict yes unknown)" \
                "$(g14_verdict cpu)" \
                "$(g16_verdict '')" \
                "$(g17_verdict Y)" \
                "$(g18_verdict yes)" \
                "$(g19_verdict)" \
                "$(g20_verdict unknown)"; do
        run tri_is_verdict "${line%%	*}"
        [ "$status" -eq 0 ]
    done
}

# --- accumulators and JSON -------------------------------------------------

@test "tri_fact_get returns a value that contains spaces" {
    tri_fact cpu_brand "Intel(R) Xeon(R) CPU 5150 @ 2.66GHz"
    [ "$(tri_fact_get cpu_brand)" = "Intel(R) Xeon(R) CPU 5150 @ 2.66GHz" ]
}

@test "json_escape escapes quotes and backslashes" {
    run json_escape 'a "b" \c'
    [ "$output" = 'a \"b\" \\c' ]
}

# --- the script itself ------------------------------------------------------

@test "triangulate.sh --help says the default is the safe level" {
    run "$REPO/bin/triangulate.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--probe"* ]]
    [[ "$output" == *"default"* ]]
}

@test "triangulate.sh rejects an unknown option rather than guessing" {
    run "$REPO/bin/triangulate.sh" --install-everything
    [ "$status" -eq 2 ]
}

@test "the probe names tools, and no package to install them from" {
    run "$REPO/bin/triangulate.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"by tool, never by package name"* ]]
    [[ "$output" != *"apt install"* ]]
    [[ "$output" != *"pacman -S"* ]]
}

@test "the probe emits a ledger table with a row per entry it can reach" {
    run "$REPO/bin/triangulate.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| Entry | Verdict | Host | Observation |"* ]]
    [[ "$output" == *"| G13 |"* ]]
    [[ "$output" == *"| G19 |"* ]]
}

# Not `run`, which folds stderr into stdout: the whole claim here is that
# the two streams are separate, so the test has to keep them separate too.
@test "--json emits parseable JSON on stdout and the report on stderr" {
    local json
    json=$("$REPO/bin/triangulate.sh" --json 2>"$BATS_TEST_TMPDIR/report")
    printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"]=="mqg-triangulate-1"; assert d["level"]=="probe"; assert len(d["ledger"]) > 10'
    grep -q "triangulation report" "$BATS_TEST_TMPDIR/report"
}

@test "--json-out writes the JSON to a file and the report to stdout" {
    run "$REPO/bin/triangulate.sh" --json-out "$BATS_TEST_TMPDIR/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"triangulation report"* ]]
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$BATS_TEST_TMPDIR/out.json"
}

@test "the probe leaves nothing behind in the repository" {
    local before after
    before=$(find "$REPO" -maxdepth 1 -name '.mqg-triangulate*' | wc -l)
    run "$REPO/bin/triangulate.sh"
    [ "$status" -eq 0 ]
    after=$(find "$REPO" -maxdepth 1 -name '.mqg-triangulate*' | wc -l)
    [ "$before" -eq "$after" ]
}
