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
    #
    # `known` MUST NOT include lib/preconditions.sh, where vmavs_tools_for
    # itself lives: doing so would let it check itself against itself --
    # every tool it names would trivially satisfy the search, a typo'd or
    # invented tool could never be caught, and this test would be unable
    # to fail no matter what vmavs_tools_for said. So `known` is built
    # only from independent sources: the require_cmd declarations in the
    # rest of the repository's scripts (the authority; see
    # tests/boot_scripts.bats), boot/prereqs.sh's package table, and
    # bin/triangulate.sh's RUNTIME_TOOLS/BUILD_TOOLS -- the same three
    # lists that drifted from each other in the incident this comment
    # cites, deliberately never touching the fourth (this one).
    #
    # Matching is whole-word, not substring: `[[ "$known" == *"$t"* ]]`
    # would let `ssh` pass by matching inside `ssh-keygen`, or `make`
    # pass by matching inside some unrelated word in prose. The `case`
    # below only matches a tool name bounded by spaces on both sides.
    #
    # `require_cmd curl unzip` names TWO tools, and a `require_cmd` line
    # can name any number more. Fix round 1's extraction --
    # `grep -oE 'require_cmd [a-zA-Z0-9._-]+'` -- had no space in its
    # character class, so it captured only the FIRST argument of every
    # declaration (curl, but not unzip; qemu-img, but not ssh or
    # ssh-keygen or python3 or sha256sum) and silently dropped about ten
    # tools from `reqcmd`. That test still passed, because
    # boot/prereqs.sh happened to list the dropped tools too -- which
    # defeats the entire point of require_cmd as an INDEPENDENT authority
    # and is exactly the kind of silent narrowing this test exists to
    # catch in vmavs_tools_for, just relocated one level up into the test
    # itself. Fixed by matching the WHOLE declaration --
    # `require_cmd( [a-zA-Z0-9._-]+)+`, one or more space-prefixed
    # arguments -- and only on code lines: comment-only lines (first
    # non-blank character `#`) are dropped first, both because a
    # `require_cmd` mentioned in prose is not a declaration (this is also
    # what kept fix round 1's near-miss -- boot/prereqs.sh's own comments
    # saying "every `require_cmd`" -- from ever matching) and because
    # dropping them is cheap insurance against the next comment that
    # happens to say "require_cmd <lowercase words>".
    reqcmd=$(find "$REPO" -name '*.sh' ! -path "$REPO/lib/preconditions.sh" \
                 ! -path "$REPO/.git/*" -print0 \
             | xargs -0 cat 2>/dev/null \
             | grep -v '^[[:space:]]*#' \
             | grep -oE 'require_cmd( [a-zA-Z0-9._-]+)+' \
             | sed 's/require_cmd //' | tr ' ' '\n' | grep -v '^$')
    # A cheap guard against this exact regression recurring silently: pick
    # a tool that appears ONLY as a non-first argument of some
    # require_cmd line -- ssh-keygen, the third word of
    # image/build-image.sh's `require_cmd qemu-img ssh ssh-keygen python3
    # sha256sum` -- and assert it is in reqcmd BY ITSELF, before reqcmd is
    # ever merged with prereqs/triangulate. A regex that regresses to
    # first-argument-only drops ssh-keygen from reqcmd but the merged
    # `known` set would still contain it (boot/prereqs.sh lists it too),
    # so only checking reqcmd alone actually catches the regression.
    case " $(printf '%s\n' "$reqcmd" | tr '\n' ' ') " in
        *" ssh-keygen "*) : ;;
        *) echo "reqcmd lost ssh-keygen -- require_cmd extraction regressed to first-argument-only"
           false ;;
    esac
    prereqs=$(sed -n 's/^\([a-z0-9._-]*\)|.*/\1/p' "$REPO/boot/prereqs.sh")
    tri=$(sed -n 's/^RUNTIME_TOOLS="\(.*\)"$/\1/p;s/^BUILD_TOOLS="\(.*\)"$/\1/p' \
              "$REPO/bin/triangulate.sh" | tr ' ' '\n')
    known=" $(printf '%s\n%s\n%s\n' "$reqcmd" "$prereqs" "$tri" \
                | grep -v '^$' | sort -u | tr '\n' ' ')"
    for c in doctor fetch boot-stack media install clone run ssh emit image; do
        for t in $(vmavs_tools_for "$c"); do
            case "$known" in
                *" $t "*) : ;;
                *) echo "$c names $t, which no other list does"; false ;;
            esac
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
