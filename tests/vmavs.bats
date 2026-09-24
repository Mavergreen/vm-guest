#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VMAVS="$REPO/bin/vmavs"
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
    rm -f "$REPO/VERSION"
}
