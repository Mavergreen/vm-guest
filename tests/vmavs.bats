#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VMAVS="$REPO/bin/vmavs"
}

teardown() {
    # Crash-safe cleanup for the stale-VERSION test below: this runs even
    # if that test fails partway through, so a bad run cannot leave a
    # VERSION file sitting in the real checkout for the next test (or the
    # next `git status`) to trip over. `rm -f` is a no-op for every other
    # test here, which never creates this file.
    rm -f "$REPO/VERSION"
    # The read-only test below makes its tree unwritable; give it back so
    # bats can delete $BATS_TEST_TMPDIR, pass or fail.
    if [ -d "$BATS_TEST_TMPDIR/ro" ]; then
        chmod -R u+w "$BATS_TEST_TMPDIR/ro"
    fi
}

# Builds a tree with no .git, holding only what vmavs needs to run: itself,
# lib/common.sh (which it sources), and build/version.sh (present so the
# tree looks like a real install, though the no-.git branch never calls
# it). Sets ITREE and leaves $ITREE/bin/vmavs ready to run.
setup_installed_tree() {
    ITREE="$BATS_TEST_TMPDIR/installed"
    mkdir -p "$ITREE/bin" "$ITREE/lib" "$ITREE/build"
    cp "$REPO/bin/vmavs" "$ITREE/bin/vmavs"
    cp "$REPO/lib/common.sh" "$ITREE/lib/common.sh"
    cp "$REPO/build/version.sh" "$ITREE/build/version.sh"
    chmod +x "$ITREE/bin/vmavs" "$ITREE/build/version.sh"
}

@test "vmavs help lists every subcommand decisions/0007 names" {
    run "$VMAVS" help
    [ "$status" -eq 0 ]
    for c in doctor fetch boot-stack media install clone run ssh emit image; do
        [[ "$output" == *"$c"* ]] || { echo "missing: $c"; false; }
    done
}

@test "no arguments is a usage error, not a silent success" {
    run "$VMAVS"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage"* ]]
}

@test "an unknown subcommand names itself and lists the real ones" {
    run "$VMAVS" instal
    [ "$status" -eq 2 ]
    [[ "$output" == *"instal"* ]]
    [[ "$output" == *"install"* ]]
}

@test "vmavs version prints the version and nothing else on stdout" {
    run "$VMAVS" version
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" =~ ^[0-9]{8}\.[0-9]+$ ]]
}

@test "vmavs --version is the same as vmavs version" {
    a=$("$VMAVS" version)
    b=$("$VMAVS" --version)
    [ "$a" = "$b" ]
}

@test "vmavs finds its repository through a symlink on PATH" {
    # This is how an installed copy works: the tree under a libdir, one
    # symlink in bindir. readlink -f would have been the obvious way to
    # resolve it and is GNU-only -- absent on 10.9 and NetBSD, the two
    # hosts this command exists to reach.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    ln -s "$VMAVS" "$BATS_TEST_TMPDIR/bin/vmavs"
    run "$BATS_TEST_TMPDIR/bin/vmavs" version
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" =~ ^[0-9]{8}\.[0-9]+$ ]]
}

@test "vmavs finds its repository through a chain of two symlinks" {
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    ln -s "$VMAVS" "$BATS_TEST_TMPDIR/a/vmavs"
    ln -s "$BATS_TEST_TMPDIR/a/vmavs" "$BATS_TEST_TMPDIR/b/vmavs"
    run "$BATS_TEST_TMPDIR/b/vmavs" version
    [ "$status" -eq 0 ]
}

@test "every subcommand in the table has a one-line description" {
    # A table row with no description is how a subcommand ships
    # undocumented: it appears in help as a bare word and nobody notices.
    run bash -c "'$VMAVS' help | sed -n 's/^  \([a-z-]*\) *\(.*\)/\1|\2/p'"
    while IFS='|' read -r name desc; do
        [ -n "$name" ] || continue
        [ -n "$desc" ] || { echo "no description: $name"; false; }
    done <<< "$output"
}

@test "in a checkout, vmavs version ignores a stale VERSION file" {
    # Controller ruling on version(): build/version.sh writes VERSION on
    # every call, so if version() preferred a pre-existing VERSION file
    # the way an installed tree does, a checkout would freeze at whatever
    # was first computed. A checkout is detected by $MQG_REPO_ROOT/.git
    # existing; there, version() must always recompute via
    # build/version.sh auto rather than trust a stale VERSION on disk.
    [ -e "$REPO/.git" ] || skip "not a git checkout"
    printf '19990101.1\n' > "$REPO/VERSION"
    run "$VMAVS" version
    [ "$status" -eq 0 ]
    [ "${lines[0]}" != "19990101.1" ]
    # Cleanup also happens in teardown() (crash-safe); doing it here too
    # keeps other tests in this same run from seeing the stale file.
    rm -f "$REPO/VERSION"
}

@test "an installed tree (no .git) with a VERSION file prints its content" {
    setup_installed_tree
    printf '20260101.3\n' > "$ITREE/VERSION"
    run "$ITREE/bin/vmavs" version
    [ "$status" -eq 0 ]
    [ "$output" = "20260101.3" ]
}

@test "an installed tree (no .git) with no VERSION file dies naming it, not a bare traceback" {
    # This is the case the fix addresses: under `set -euo pipefail`, a
    # naive `tr -d ... < "$MQG_REPO_ROOT/VERSION"` on a missing file fails
    # the redirection itself and aborts with bash's own "No such file or
    # directory" -- never reaching `die`, and never saying VERSION is what
    # is missing. version() must check for the file first.
    setup_installed_tree
    run "$ITREE/bin/vmavs" version
    [ "$status" -ne 0 ]
    # Not just *a* mention of VERSION: the raw bash redirection failure
    # this replaces ALSO mentions VERSION, because it is naming the path
    # it could not open ("line N: /.../VERSION: No such file or
    # directory") -- so a bare substring check on "VERSION" alone would
    # pass against the bug this test exists to catch. What only the fixed
    # `die` call produces is this project's own error prefix.
    [[ "$output" == *"vmavs: error:"* ]]
    [[ "$output" == *"VERSION"* ]]
    [[ "$output" != *"No such file or directory"* ]]
    # No bare/empty version line ever reached stdout.
    ! printf '%s\n' "$output" | grep -qE '^[0-9]{8}\.[0-9]+$'
}

# --- pipeline subcommands: fetch, boot-stack, media, install, image --------
#
# These forward to image/build-image.sh's own --describe, whose "stages, in
# order" section is followed by a "manifest fields" section that names an
# "InstallESD.dmg" and an "installer media" -- so a substring check against
# the WHOLE output can pass or fail for a reason that has nothing to do
# with which stages ran. Scoped to just the stages section instead, the
# same way tests/image.bats checks --stage's own filtering of --describe.

stages_section() {
    printf '%s\n' "$1" | sed -n '/today)/,/^$/p'
}

stage_names_in() {
    stages_section "$1" | sed -n 's/^    \([a-z]*\)[[:space:]].*/\1/p' | xargs
}

@test "vmavs image passes its arguments through to build-image.sh" {
    run "$VMAVS" image --describe
    [ "$status" -eq 0 ]
    [ "$(stage_names_in "$output")" = \
        "esd opencore ovmf efi openssh payload media target install verify manifest" ]
}

@test "vmavs media runs the payload and media stages, and only those" {
    # media consumes payload's output directly -- build-installer-img.sh
    # dies if --firstboot-pkg does not already exist on disk -- so this is
    # --stage payload,media, not --stage media alone. --describe touches
    # nothing, so this asserts the plan, not a build.
    run "$VMAVS" media --describe
    [ "$status" -eq 0 ]
    [ "$(stage_names_in "$output")" = "payload media" ]
}

@test "vmavs boot-stack covers opencore, ovmf and efi, and only those" {
    run "$VMAVS" boot-stack --describe
    [ "$status" -eq 0 ]
    [ "$(stage_names_in "$output")" = "opencore ovmf efi" ]
}

@test "vmavs fetch defaults to Apple's installer and takes a named input" {
    run "$VMAVS" fetch --describe
    [ "$status" -eq 0 ]
    [ "$(stage_names_in "$output")" = "esd" ]
    run "$VMAVS" fetch openssh --describe
    [ "$status" -eq 0 ]
    [ "$(stage_names_in "$output")" = "openssh" ]
}

@test "vmavs fetch refuses an input it does not have" {
    run "$VMAVS" fetch xcode
    [ "$status" -ne 0 ]
    [[ "$output" == *"xcode"* ]]
    [[ "$output" == *"esd"* ]]
}

@test "vmavs install covers target then install, and only those" {
    run "$VMAVS" install --describe
    [ "$status" -eq 0 ]
    [ "$(stage_names_in "$output")" = "target install" ]
}

@test "every pipeline subcommand forwards --help to the script behind it" {
    for c in image media boot-stack install fetch; do
        run "$VMAVS" "$c" --help
        [ "$status" -eq 0 ] || { echo "$c --help failed"; false; }
        [[ "$output" == *"--accel"* ]] || { echo "$c --help is not build-image's"; false; }
    done
}

# --- second-tier subcommands: not part of decisions/0007's ten -------------
#
# triangulate, golden, compare, freshness and staleness are real scripts
# with real user-facing CLIs today (bin/triangulate.sh, vm/golden.sh,
# image/compare-images.sh, build-image.sh --freshness,
# bin/image-staleness.sh). This task is proposed rather than decided and
# can be struck without affecting anything else -- but leaving vmavs
# unable to reach them would make vmavs strictly less capable than the
# scripts it replaces, which is a bad trade for a front door.

@test "the second-tier subcommands reach their scripts" {
    run "$VMAVS" triangulate --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--probe"* ]]
    # Isolated from whatever this host already has, not just under its
    # real $MQG_IMAGE_DIR but under its real $HOME too: fix-round-1
    # finding -- isolating MQG_IMAGE_DIR alone still leaves
    # lib/sshkey.sh's sshkey_find searching the invoking user's REAL
    # ~/.ssh/id_*.pub, and on any host where that glob matches something,
    # resolve_ssh_key(soft) finds a key, never warns, and the original
    # loose "stage" or "would" substring check fails -- not because
    # anything is wrong, but because the test depended on an unrelated
    # fact about the host running it. Both MQG_IMAGE_DIR and HOME point
    # at fresh, empty temp directories here, the one state every host --
    # including CI, which starts with neither -- can be put into on
    # demand. That state is also asserted STRUCTURALLY rather than with a
    # loose substring: build-image.sh --freshness prints one
    # "<stage><TAB><verdict><TAB><reason>" row per stage, and on a
    # from-scratch image dir the "esd" stage's output file cannot exist
    # yet, so its verdict is unconditionally "run" -- the same
    # tab-separated shape every other reader of this output in this
    # project (build-image.sh's own --freshness branch, stage_freshness)
    # relies on.
    run env HOME="$BATS_TEST_TMPDIR/no-home" \
            MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/no-image-dir" "$VMAVS" freshness
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE '^esd[[:space:]]+run[[:space:]]+' \
        || { echo "unexpected --freshness output:"; echo "$output"; false; }
}

@test "help keeps the ten from decisions/0007 separate from the rest" {
    run "$VMAVS" help
    [[ "$output" == *"triangulate"* ]]
    # The ten appear above whatever divides the sections.
    ten=$(printf '%s\n' "$output" | grep -n '  image ' | cut -d: -f1)
    extra=$(printf '%s\n' "$output" | grep -n '  triangulate' | cut -d: -f1)
    [ "$ten" -lt "$extra" ]
}

@test "vmavs does not tell the human to type the vmavs form they just typed" {
    # Final review, MEASURED: at a terminal, `vmavs run` printed "note:
    # `vmavs run` is the documented way to do this." vmavs execs the
    # script, and the script's vmavs_hint could not tell who ran it.
    # VMAVS_FORCE_HINT stands in for the terminal (bats pipes stderr).
    # run and image are representative: both die or print usage before
    # touching QEMU, so this needs no host tools.
    for c in run image; do
        run env VMAVS_FORCE_HINT=1 "$VMAVS" "$c" --help
        [[ "$output" != *"note:"* ]] || { echo "vmavs $c hinted: $output"; false; }
    done
    # The control: the direct script still points at vmavs.
    run env VMAVS_FORCE_HINT=1 "$REPO/vm/run.sh" --help
    [[ "$output" == *'note: `vmavs run`'* ]]
    run env VMAVS_FORCE_HINT=1 "$REPO/image/build-image.sh" --help
    [[ "$output" == *'note: `vmavs image`'* ]]
}

@test "every subcommand vmavs help lists takes --help: exit 0 and a usage line" {
    # Final review, MEASURED: help said "Every subcommand takes --help",
    # and six did not -- doctor ran the whole probe, run/clone/staleness
    # took --help for a profile/golden/manifest name, golden printed its
    # usage but exited 1, emit called it an unknown target. Both tiers,
    # read off the help itself so a new row cannot skip this. Every
    # --help exits before any tool is run, so this needs no QEMU.
    run "$VMAVS" help
    cmds=$(printf '%s\n' "$output" | sed -n 's/^  \([a-z-]*\)  *[A-Z].*/\1/p')
    [ "$(printf '%s\n' "$cmds" | wc -l)" -ge 17 ] || { echo "parsed: $cmds"; false; }
    for c in $cmds; do
        run "$VMAVS" "$c" --help
        [ "$status" -eq 0 ] || { echo "vmavs $c --help: exit $status: $output"; false; }
        printf '%s\n' "$output" | grep -qi '^usage' \
            || { echo "vmavs $c --help: no usage line: $output"; false; }
    done
}

@test "vmavs run --help lists the profiles" {
    run "$VMAVS" run --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"p4-linuxmedia"* ]]
}

@test "help's footer is the README's quickstart, and sends nobody to an internal plan" {
    # Final review: the footer still advertised `vmavs run p4-linuxmedia`
    # and a bare `vmavs ssh` after the README stopped offering them (the
    # profile boots a development disk nothing shipped creates, on a port
    # the bare ssh does not use), and pointed strangers at a plan's task.
    run "$VMAVS" help
    [[ "$output" == *"vmavs doctor"* ]]
    [[ "$output" == *"vmavs image --describe"* ]]
    [[ "$output" != *"p4-linuxmedia"* ]]
    [[ "$output" != *"docs/superpowers"* ]]
    [[ "$output" != *"~30 minutes"* ]]
    if printf '%s\n' "$output" | grep -qE '^ +vmavs ssh *$'; then
        echo "help offers a bare vmavs ssh"; false
    fi
}

@test "vmavs version answers in a read-only checkout, and writes nothing" {
    # Final review, MEASURED: in a `chmod a-w` clone, `vmavs version`
    # died "cannot create .../VERSION: Permission denied", rc=2, because
    # build/version.sh wrote VERSION on every call. Reporting a version is
    # a read. A throwaway git repo holding what version() needs, then
    # made unwritable.
    RO="$BATS_TEST_TMPDIR/ro"
    mkdir -p "$RO/bin" "$RO/lib" "$RO/build"
    cp "$REPO/bin/vmavs" "$RO/bin/"
    cp "$REPO/lib/common.sh" "$RO/lib/"
    cp "$REPO/build/version.sh" "$RO/build/"
    printf '20260922\n' > "$RO/UPSTREAM_VERSION"
    git -C "$RO" init -q
    git -C "$RO" add -A
    git -C "$RO" -c user.name=t -c user.email=t@example.invalid \
        -c commit.gpgsign=false commit -qm fixture
    chmod -R a-w "$RO"
    run "$RO/bin/vmavs" version
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$output" = "20260922.1" ]
    [ ! -e "$RO/VERSION" ]
}
