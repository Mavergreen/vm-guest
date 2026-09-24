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
