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
    [ -d "$REPO/.git" ] || skip "not a git checkout"
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
    # Isolated from whatever this host already has under its real
    # $MQG_IMAGE_DIR: on a machine with a from-scratch build state (CI has
    # none at all; a dev box may have a stale or a fresh one) the exact
    # wording of --freshness's per-stage lines depends on what is already
    # on disk. A brand-new, empty MQG_IMAGE_DIR is the one state every
    # host -- including CI, which is the case this project has to hold --
    # can be put into on demand, and it is the state build-image.sh
    # --freshness itself documents: every stage reports "no output ...
    # yet" and resolve_ssh_key(soft) warns about the missing key while
    # naming the payload stage by name.
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/no-image-dir" "$VMAVS" freshness
    [ "$status" -eq 0 ]
    [[ "$output" == *"stage"* || "$output" == *"would"* ]]
}

@test "help keeps the ten from decisions/0007 separate from the rest" {
    run "$VMAVS" help
    [[ "$output" == *"triangulate"* ]]
    # The ten appear above whatever divides the sections.
    ten=$(printf '%s\n' "$output" | grep -n '  image ' | cut -d: -f1)
    extra=$(printf '%s\n' "$output" | grep -n '  triangulate' | cut -d: -f1)
    [ "$ten" -lt "$extra" ]
}
