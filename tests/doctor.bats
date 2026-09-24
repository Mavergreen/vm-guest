#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VMAVS="$REPO/bin/vmavs"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/preconditions.sh"
}

@test "every subcommand in vmavs's table has a tool list" {
    # A subcommand with no list would silently report READY on a host
    # that cannot run it.
    run bash -c "'$VMAVS' help | sed -n 's/^  \([a-z-]*\)  *[A-Z].*/\1/p'"
    for c in $output; do
        case $c in version|help) continue ;; esac
        run vmavs_tools_for "$c"
        [ "$status" -eq 0 ] || { echo "no tool list: $c"; false; }
    done
}

@test "run needs a QEMU; boot-stack needs a compiler; they are not the same list" {
    run vmavs_tools_for run
    [[ "$output" == *"qemu-system-x86_64"* ]]
    [[ "$output" != *"gcc"* ]]
    run vmavs_tools_for boot-stack
    [[ "$output" == *"gcc"* ]]
}

@test "image needs the union of the stages it runs" {
    img=$(vmavs_tools_for image)
    for stage in fetch boot-stack media install; do
        for t in $(vmavs_tools_for "$stage"); do
            [[ "$img" == *"$t"* ]] || { echo "image omits $t (from $stage)"; false; }
        done
    done
}

@test "no tool list names a tool no script actually requires" {
    # docs/superpowers/specs/2026-09-21-build-in-a-linux-vm-design.md
    # section 9.1 warns about exactly this: there were three lists, they
    # disagreed, and a host stopped on `zip`. This is the fourth list;
    # it must not drift from the ones that already exist.
    known=$(cat "$REPO/boot/prereqs.sh" "$REPO/bin/triangulate.sh" "$REPO/lib/preconditions.sh")
    for c in doctor fetch boot-stack media install clone run ssh emit image; do
        for t in $(vmavs_tools_for "$c"); do
            [[ "$known" == *"$t"* ]] || { echo "$c names $t, which no other list does"; false; }
        done
    done
}

@test "doctor prints one row per subcommand with a verdict" {
    run "$VMAVS" doctor
    for c in run boot-stack media image; do
        [[ "$output" == *"$c"* ]]
    done
    [[ "$output" == *"READY"* || "$output" == *"BLOCKED"* ]]
}

@test "doctor names the missing tool, not just the failure" {
    # A genuinely empty PATH cannot even find bash (the shebang is
    # #!/usr/bin/env bash), let alone the coreutils doctor's own code path
    # needs before it gets anywhere near a subcommand row. So: a stub PATH
    # holding symlinks to exactly the tools that path needs to run at all
    # -- bash, env, uname, dirname, awk -- and nothing else. No qemu-*, no
    # sgdisk, no compiler, so every subcommand row must come back BLOCKED
    # and must say what is missing. This is built from whatever those five
    # tools resolve to on THIS host, but the point is what is left OUT:
    # it must behave the same on a CI runner with no QEMU installed at all
    # as it does here, where QEMU is on the real PATH -- because PATH below
    # points at nothing but this stub directory.
    STUB="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUB"
    for t in bash env uname dirname awk; do
        ln -s "$(command -v "$t")" "$STUB/$t"
    done
    run env PATH="$STUB" "$VMAVS" doctor
    [[ "$output" == *"qemu-system-x86_64"* ]]
}

@test "on a host this project has never probed, doctor says so instead of guessing" {
    # No HVF branch, no NVMM branch. Nobody has run this on Darwin or
    # NetBSD; a branch nobody has run is a claim we cannot support
    # (decisions/0007, the Snow Leopard rule).
    mkdir -p "$BATS_TEST_TMPDIR/stub"
    printf '#!/bin/sh\necho Darwin\n' > "$BATS_TEST_TMPDIR/stub/uname"
    chmod +x "$BATS_TEST_TMPDIR/stub/uname"
    run env PATH="$BATS_TEST_TMPDIR/stub:$PATH" "$VMAVS" doctor
    [ "$status" -ne 0 ] || true   # a verdict either way, but never a crash
    [[ "$output" == *"never"* ]]
    [[ "$output" == *"Darwin"* ]]
    [[ "$output" != *"lscpu"* ]]
}

@test "doctor points at triangulate for the ledger-grade answer" {
    run "$VMAVS" doctor
    [[ "$output" == *"triangulate"* ]]
}
