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

# A PATH holding exactly what doctor itself runs (real), a stub lscpu
# that reports an Intel CPU, and an executable that does nothing for every
# tool `vmavs image` needs -- minus any names passed as arguments. bats is
# never in it. With CPUINFO and KVM_DEVICE pointed at files this test
# owns, every host fact is known, so the verdict depends only on what the
# test chose -- the same on a CI runner with no QEMU and no /dev/kvm as
# here. Sets STUB.
stub_host() {
    STUB="$BATS_TEST_TMPDIR/stubhost"
    mkdir -p "$STUB"
    for t in bash env uname dirname awk grep cat; do
        ln -s "$(command -v "$t")" "$STUB/$t"
    done
    printf '#!/bin/sh\necho "Vendor ID:  GenuineIntel"\n' > "$STUB/lscpu"
    chmod +x "$STUB/lscpu"
    for t in $(vmavs_tools_for image); do
        case " $* " in *" $t "*) continue ;; esac
        [ -e "$STUB/$t" ] && continue
        printf '#!/bin/sh\nexit 0\n' > "$STUB/$t"
        chmod +x "$STUB/$t"
    done
    printf 'flags\t\t: fpu vmx sse2\n' > "$BATS_TEST_TMPDIR/cpuinfo"
    : > "$BATS_TEST_TMPDIR/kvm"
}

run_stub_doctor() {
    run env PATH="$STUB" CPUINFO="$BATS_TEST_TMPDIR/cpuinfo" \
        KVM_DEVICE="${KVM:-$BATS_TEST_TMPDIR/kvm}" \
        OVMF_DIR="$BATS_TEST_TMPDIR/no-ovmf" "$VMAVS" doctor
}

@test "doctor prints one row per subcommand with a verdict" {
    # Matched as a whole row, not a substring: "run" is also inside
    # "triangulate", which doctor prints on its own line.
    run "$VMAVS" doctor
    for c in fetch boot-stack media install clone run ssh emit image; do
        printf '%s\n' "$output" | grep -qE "^(READY|BLOCKED) +$c( |\$)" \
            || { echo "no verdict row for $c"; false; }
    done
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
    # The row, not the tool name: the tool table above it prints
    # "tool:qemu-system-x86_64" on every host, so a bare substring match
    # passed whether or not the run row said anything.
    printf '%s\n' "$output" \
        | grep -qE '^BLOCKED +run +missing:.* qemu-system-x86_64( |$)' \
        || { echo "no BLOCKED run row naming qemu-system-x86_64:"; echo "$output"; false; }
}

@test "a host with everything vmavs needs but bats gets GO, exit 0" {
    # Final review, MEASURED: bats was in doctor's gating list, so a user
    # with every subcommand READY was told NO-GO. bats runs tests/; it is
    # a developer's tool, reported as INFO and never gating.
    stub_host
    run_stub_doctor
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" | grep -qE '^INFO +tool:bats +not installed' \
        || { echo "no INFO row for bats"; false; }
    [[ "$output" == *"doctor: GO -- ready: fetch boot-stack media install clone run ssh emit image"* ]]
    [[ "$output" != *"NO-GO"* ]]
}

@test "a host missing a tool only image's pipeline needs gets NO-GO, naming it" {
    # Final review, MEASURED: nasm is not in the flat tool table, so the
    # old verdict said GO right under "BLOCKED image". The last line now
    # sums up the subcommand table.
    stub_host nasm
    run_stub_doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"doctor: NO-GO -- ready: fetch media install clone run ssh emit; blocked: boot-stack image (missing: nasm)"* ]] \
        || { echo "$output"; false; }
}

@test "a host fact that FAILs is NO-GO even with every tool present" {
    # The rule: exit 0 iff image is READY and no host-fact row FAILs.
    stub_host
    KVM="$BATS_TEST_TMPDIR/no-such-kvm" run_stub_doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"NO-GO"*"host FAIL: kvm-device"* ]] || { echo "$output"; false; }
}

@test "doctor --help is a usage, not a probe" {
    run "$VMAVS" doctor --help
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "usage: vmavs doctor"* ]]
    [[ "$output" != *"STATUS"* ]]
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
