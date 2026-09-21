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

# The prediction above was half right and its CONCLUSION was wrong: a
# Woodcrest host really cannot provide SSE4.1, and 10.9 does not need it
# (docs/decisions/0009). So G3's refutation now has to point at the row of
# the table that host should use, or the report repeats the mistake that
# wrote the machine off in the first place.
@test "G3's refutation sends an SSE4.1-less host to the Conroe row" {
    run g3_verdict "Intel(R) Xeon(R) CPU 5150 @ 2.66GHz" no rejected
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"Conroe"* ]]
    [[ "$output" == *"NOT a stopper"* ]]
}

# --- G25: which rows of the table a host can actually provide ---------------
#
# The whole reason this entry exists is that a host can answer it in about
# a second, with nothing installed. The verdicts below are the ones the Mac
# Pro 1,1 will produce when somebody finally runs it there.

@test "G25 confirms when every row is available, as on the primary host" {
    run g25_verdict 8.2.2 kvm "Conroe Penryn Nehalem" "" "" ""
    [ "$status" -eq 0 ]
    [[ "$output" == CONFIRM* ]]
}

@test "G25 refutes on a host too old for some rows, and names the rest" {
    run g25_verdict 8.2.2 kvm "Conroe" "Penryn Penryn,+ssse3,+sse4.1,+sse4.2" "" \
        "Penryn needs sse4.1 this host does not have"
    [ "$status" -eq 0 ]
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"Conroe"* ]]
    [[ "$output" == *"sse4.1"* ]]
    [[ "$output" == *"not a broken host"* ]]
}

# TCG implements SSE4.1 itself, so a 2006 host passes every row under it
# and the answer describes the emulator. A confident yes from the wrong
# measurement is how docs/test-hosts.md wrote a machine off for a year.
@test "G25 cannot say anything from a TCG run" {
    run g25_verdict 8.2.2 tcg "Conroe Penryn Nehalem" "" "" ""
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *"tcg"* ]]
}

@test "G25 cannot say without a QEMU to ask" {
    run g25_verdict "" kvm "" "" "" ""
    [[ "$output" == CANNOT-SAY* ]]
}

@test "G25 cannot say when the QEMU has none of the models by name" {
    run g25_verdict 11.1.1 kvm "" "" "Conroe Penryn" ""
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *"Conroe"* ]]
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

# --- a stage is judged by what IT did, not by what the run did -------------
#
# The regression these guard: on squirrel-zapper 2026-09-20 the opencore
# stage failed to compile under a C23-default GCC, the media stage never
# ran, and the report said "G20 REFUTE -- media build or its post-unmount
# verification failed on this host". It had not. A reader would have gone
# looking for a filesystem bug that was not there.

# A report of the shape run_stage builds: "<stage>\t<result>\t<seconds>".
tri_report() {
    printf 'esd\tok\t248s\nopencore\tFAILED\t111s\n'
}

@test "tri_stage_result reports a stage that never ran as not-run" {
    [ "$(tri_stage_result media "$(tri_report)")" = not-run ]
    [ "$(tri_stage_result esd "$(tri_report)")" = ok ]
    [ "$(tri_stage_result opencore "$(tri_report)")" = FAILED ]
}

@test "tri_stage_result calls an empty report not-run rather than empty" {
    [ "$(tri_stage_result media "")" = not-run ]
}

@test "tri_failed_stage names the stage that failed, and nothing when none did" {
    [ "$(tri_failed_stage "$(tri_report)")" = opencore ]
    [ -z "$(tri_failed_stage "$(printf 'esd\tok\t1s\n')")" ]
}

@test "G20 does not blame media for a failure in an earlier stage" {
    run g20_verdict not-run opencore
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *opencore* ]]
    [[ "$output" != *REFUTE* ]]
}

# The same class of misattribution, one level finer. On squirrel-zapper
# 2026-09-20 the media stage built 52,292 entries with every one of Apple's
# packages matching its pinned checksum, and then died restoring root
# ownership because the privops backend was not available on that
# distribution. The ledger said "G20 REFUTE -- media build or its
# post-unmount verification failed". No second writer, no corruption, no
# verification even attempted.

@test "G20 refutes only when the post-unmount verification found corruption" {
    run g20_verdict no media verification "the media does not contain what Apple shipped."
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"post-unmount"* ]]
}

@test "G20 does not blame corruption for a media stage that failed for another reason" {
    run g20_verdict no media other \
        "privops backend 'qemu-linux' is not available on this host"
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *privops* ]]
    [[ "$output" != *REFUTE* ]]
}

@test "G20 will not guess when the log does not say what failed" {
    run g20_verdict no media unknown ""
    [[ "$output" == CANNOT-SAY* ]]
}

# --- telling the two kinds of media-stage failure apart --------------------

@test "tri_media_failure_kind recognises the post-unmount check by its message" {
    printf 'mqg: error: the media does not contain what Apple shipped. Re-run\n' \
        > "$BATS_TEST_TMPDIR/log"
    [ "$(tri_media_failure_kind "$BATS_TEST_TMPDIR/log")" = verification ]
}

@test "tri_media_failure_kind calls anything else other, and no log unknown" {
    printf "mqg: error: privops backend 'qemu-linux' is not available on this host\n" \
        > "$BATS_TEST_TMPDIR/log"
    [ "$(tri_media_failure_kind "$BATS_TEST_TMPDIR/log")" = other ]
    [ "$(tri_media_failure_kind "$BATS_TEST_TMPDIR/nosuchlog")" = unknown ]
    [ "$(tri_media_failure_kind)" = unknown ]
}

# The ESD check dies with nearly the same sentence about a different thing:
# a bad conversion off Apple's image, before any media exists. Reading that
# as media corruption would be the same bug with a different suspect.
@test "tri_media_failure_kind does not mistake the ESD check for the media check" {
    printf 'mqg: error: the ESD does not contain what Apple shipped. The suspects are dmg2img\n' \
        > "$BATS_TEST_TMPDIR/log"
    [ "$(tri_media_failure_kind "$BATS_TEST_TMPDIR/log")" = other ]
}

@test "tri_media_failure_reason returns the last error the pipeline printed" {
    printf 'mqg: error: an earlier one\nmqg: some chatter\nmqg: error: the last one\n' \
        > "$BATS_TEST_TMPDIR/log"
    [ "$(tri_media_failure_reason "$BATS_TEST_TMPDIR/log")" = "the last one" ]
    [ -z "$(tri_media_failure_reason "$BATS_TEST_TMPDIR/nosuchlog")" ]
}

@test "G5 blames the stage that stopped the build, not the missing checksums" {
    run g5_verdict "" "" unknown opencore
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *opencore* ]]
    [[ "$output" == *0004* ]]
}

@test "G24 refutes when the host's QEMU has no e1000-82545em to default to" {
    # The default guest NIC became e1000-82545em on measurement taken
    # entirely under QEMU 8.2.2 (docs/decisions/0008). A host whose QEMU
    # cannot offer the device refutes the default outright, and should be
    # told so rather than discovering it mid-install.
    run g24_verdict " e1000-82545em" unknown 9.0.0
    [[ "$output" == REFUTE* ]]
    [[ "$output" == *"usb-net"* ]]
}

@test "G24 confirms only from an install, not from a device list" {
    # Every number behind the decision came from one QEMU. A probe can say
    # the device exists; only a guest that installed and answered SSH over
    # it says the device works on this one.
    run g24_verdict "" unknown 11.1.1
    [[ "$output" == CANNOT-SAY* ]]
    run g24_verdict "" yes 11.1.1
    [[ "$output" == CONFIRM* ]]
    [[ "$output" == *"11.1.1"* ]]
}

@test "G24 does not blame the NIC for an install that failed elsewhere" {
    run g24_verdict "" no 11.1.1
    [[ "$output" == CANNOT-SAY* ]]
    [[ "$output" == *"stage table"* ]]
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
                "$(g20_verdict unknown)" \
                "$(g20_verdict not-run opencore)" \
                "$(g24_verdict '' unknown 8.2.2)"; do
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

@test "a failed build salvages logs before cleanup removes the build tree" {
    # squirrel-zapper 2026-09-20: the ovmf stage failed, the run said
    # "report the error rather than working around it", and then cleanup
    # deleted the log that held the error. A cleanup that runs on failure
    # must not destroy the evidence of the failure.
    run bash -c '
        set -e
        . '"$REPO"'/bin/triangulate.sh --source-only 2>/dev/null || true
        true
    '
    # The salvage function exists and is called on the failure path, not
    # only defined. Asserting the wiring, because a salvage routine nobody
    # calls is the same as no salvage routine.
    grep -q "^    salvage_logs$" "$REPO/bin/triangulate.sh"
    grep -q "salvage_logs()" "$REPO/bin/triangulate.sh"
}

@test "salvage_logs copies .log files out of a doomed directory" {
    doomed="$BATS_TEST_TMPDIR/build"
    mkdir -p "$doomed/deep"
    printf 'the error that matters\n' > "$doomed/deep/ovmf-build.log"
    printf 'not a log\n' > "$doomed/notes.txt"

    cd "$BATS_TEST_TMPDIR"
    run bash -c '
        scratch=$(mktemp -d)
        created_list=$scratch/created
        printf "%s\n" "'"$doomed"'" > "$created_list"
        keep=0
        PWD_SAVE=$PWD
        '"$(sed -n '/^salvage_logs() {/,/^}/p' "$REPO/bin/triangulate.sh")"'
        salvage_logs
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"saved 1 file"* ]]
    found=$(find "$BATS_TEST_TMPDIR" -name 'ovmf-build.log' -path '*triangulate-logs-*' | wc -l)
    [ "$found" -eq 1 ]
    # It copies logs, not everything: the build tree is gigabytes.
    notes=$(find "$BATS_TEST_TMPDIR" -name 'notes.txt' -path '*triangulate-logs-*' | wc -l)
    [ "$notes" -eq 0 ]
}

@test "a failed run salvages the report, not only the build logs" {
    # squirrel-zapper 2026-09-20, third run: both firmware builds succeeded
    # and something after them failed. The salvaged logs all said "- Done -";
    # the stage table naming the failure existed only on the user's
    # terminal. The report is the deliverable, so it has to survive too --
    # including when the failing stage produced no .log at all.
    grep -q 'report.txt' "$REPO/bin/triangulate.sh"
    # Written from $report, inside salvage_logs, before the trap runs.
    sed -n '/^salvage_logs() {/,/^}/p' "$REPO/bin/triangulate.sh" \
        | grep -q 'report.txt'
}

@test "a failed run salvages pipeline.log, which holds the stage's stderr" {
    # The stage output goes to $scratch/pipeline.log with 2>&1, and cleanup
    # deletes $scratch unconditionally. On squirrel-zapper 2026-09-20 a
    # microVM failure fell past the end of the report's 25-line window and
    # the only copy of it was already gone.
    sed -n '/^salvage_logs() {/,/^}/p' "$REPO/bin/triangulate.sh" \
        | grep -q 'pipeline.log'
}

# --- what a run leaves behind ----------------------------------------------
#
# bin/triangulate.sh:663 used to track $MQG_IMAGE_DIR itself as created, so
# cleanup deleted the whole thing -- about fourteen minutes of firmware
# rebuild on every run of a script whose entire purpose is repeated runs on
# new hosts. Leaving a host as it was found is still the default; what is
# new is that there is now a middle setting.

# The cleanup decision, lifted out of the script and driven directly.
run_cleanup_image_dir() {
    local dir=$1 keep=$2 keep_build=$3
    run bash -c '
        image_dir='"$dir"'
        build_dir=$image_dir/build
        image_dir_exists=no
        keep='"$keep"'
        keep_build='"$keep_build"'
        '"$(sed -n '/^cleanup_image_dir() {/,/^}/p' "$REPO/bin/triangulate.sh")"'
        cleanup_image_dir
    '
}

populate_image_dir() {
    local dir=$1
    mkdir -p "$dir/build/artifacts" "$dir/images" "$dir/media" "$dir/work"
    printf 'firmware\n' > "$dir/build/artifacts/SHA256SUMS"
    printf 'a guest\n' > "$dir/images/triangulate.qcow2"
    printf 'apple bytes\n' > "$dir/media/InstallESD.dmg"
}

@test "the default still leaves the host as it was found" {
    dir="$BATS_TEST_TMPDIR/imagedir"
    populate_image_dir "$dir"
    run_cleanup_image_dir "$dir" 0 0
    [ "$status" -eq 0 ]
    [ ! -d "$dir" ]
}

@test "--keep-build keeps the build tree and removes the images" {
    dir="$BATS_TEST_TMPDIR/imagedir"
    populate_image_dir "$dir"
    run_cleanup_image_dir "$dir" 0 1
    [ "$status" -eq 0 ]
    # The fourteen minutes stay.
    [ -f "$dir/build/artifacts/SHA256SUMS" ]
    # The gigabytes do not.
    [ ! -d "$dir/images" ]
    [ ! -d "$dir/media" ]
    [[ "$output" == *"kept"* ]]
}

@test "--keep still keeps everything, including the images" {
    dir="$BATS_TEST_TMPDIR/imagedir"
    populate_image_dir "$dir"
    run_cleanup_image_dir "$dir" 1 0
    [ "$status" -eq 0 ]
    [ -f "$dir/images/triangulate.qcow2" ]
    [ -f "$dir/build/artifacts/SHA256SUMS" ]
}

@test "--keep-build is a distinct flag from --keep" {
    run "$REPO/bin/triangulate.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--keep-build"* ]]
    [[ "$output" == *"--keep "* ]]
}

@test "a run that did not create the image directory does not remove it" {
    # Someone else's build tree is not this script's to delete, whatever
    # the flags say.
    dir="$BATS_TEST_TMPDIR/imagedir"
    populate_image_dir "$dir"
    run bash -c '
        image_dir='"$dir"'
        build_dir=$image_dir/build
        image_dir_exists=yes
        keep=0
        keep_build=0
        '"$(sed -n '/^cleanup_image_dir() {/,/^}/p' "$REPO/bin/triangulate.sh")"'
        cleanup_image_dir
    '
    [ "$status" -eq 0 ]
    [ -f "$dir/images/triangulate.qcow2" ]
}

@test "the build tree is still searched for logs after it left created_list" {
    # The 2026-09-20 wound: cleanup removed the one artifact needed to
    # diagnose the failure it had just reported. $MQG_IMAGE_DIR is no
    # longer in $created_list, so salvage_logs has to be told about the
    # build tree separately or that fix quietly stops working.
    grep -q 'salvage_extra=\$build_dir' "$REPO/bin/triangulate.sh"
    sed -n '/^salvage_logs() {/,/^}/p' "$REPO/bin/triangulate.sh" \
        | grep -q 'salvage_extra'
}

@test "the report says what stays and what a second run therefore skips" {
    grep -q 'What stays on this host' "$REPO/bin/triangulate.sh"
    grep -q 'A SECOND RUN THEREFORE SKIPS' "$REPO/bin/triangulate.sh"
}

@test "build_tree_kept is one value, not two lines" {
    # ap-juicer 2026-09-21: the value was built with
    #   [ ... ] && echo n/a || { ... } && echo yes || echo no
    # and on a probe `echo n/a` succeeds, so `&& echo yes` ran too. The
    # report printed a second line with no fact name on it.
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/img" "$REPO/bin/triangulate.sh" --probe
    [ "$status" -eq 0 ]
    line=$(printf '%s\n' "$output" | grep -c '^  build_tree_kept')
    [ "$line" -eq 1 ]
    # No fact line may be a bare value with no name.
    ! printf '%s\n' "$output" | grep -qE '^  (yes|no|n/a)[[:space:]]*$'
}

@test "threads per core is never zero" {
    # Same host: 4 cores, 3 online logical CPUs, so logical/cores was 0 --
    # a quotient describing no machine. cpu_cores reads topology and
    # cpu_logical counts ONLINE processors; they are not comparable.
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/img" "$REPO/bin/triangulate.sh" --probe
    [ "$status" -eq 0 ]
    t=$(printf '%s\n' "$output" | awk '/^  cpu_threads_per_core/ { print $2 }')
    [ -n "$t" ]
    [ "$t" != 0 ]
}
