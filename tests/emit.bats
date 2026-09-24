#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VMAVS="$REPO/bin/vmavs"
    OUT="$BATS_TEST_TMPDIR/mavericks.pkr.hcl"
}

emit() { "$VMAVS" emit packer --profile p4-linuxmedia --out "$OUT" "$@"; }

@test "emit packer writes a template with a qemu source and a build block" {
    run emit
    [ "$status" -eq 0 ]
    [ -s "$OUT" ]
    run grep -c '^source "qemu"' "$OUT"
    [ "$output" = "1" ]
    run grep -c '^build {' "$OUT"
    [ "$output" = "1" ]
}

@test "no emitted line packs a multi-argument block onto one line" {
    # HCL native syntax forbids `blockType "label" { a = 1  b = 2 }`
    # (Packer's own error is "Invalid single-argument block definition")
    # -- each attribute inside a block needs its own line. An earlier
    # version of this template wrote every `variable "x" { type = ...
    # description = ... }` exactly that way. A single-line object
    # CONSTRUCTOR (e.g. `qemu = { source = "...", version = "..." }`,
    # assigned to one attribute) is legitimate HCL as long as its entries
    # are comma-separated, so this check only flags braces whose content
    # has more than one `=` and no comma between them.
    emit
    run python3 - "$OUT" <<'PY'
import re, sys
bad = []
for i, line in enumerate(open(sys.argv[1]), 1):
    for m in re.finditer(r'\{([^{}]*)\}', line):
        body = m.group(1)
        if body.count('=') > 1 and ',' not in body:
            bad.append((i, line.rstrip()))
if bad:
    for i, l in bad:
        print(f"{i}: {l}")
    sys.exit(1)
PY
    [ "$status" -eq 0 ]
}

@test "the template carries the CPU and SMBIOS this project measured" {
    emit
    run grep -c 'Penryn' "$OUT"
    [ "$output" -ge 1 ]
    run grep -c 'iMac14,2' "$OUT"
    [ "$output" -ge 1 ]
}

@test "the template has no boot_command, and says why" {
    # P4's finding: Apple's own installer hooks drive the install, so the
    # GUI keystroke automation that is Packer's core value is not needed.
    # An empty boot_command with no explanation reads as an omission. A
    # comment that merely MENTIONS boot_command, to explain its absence,
    # is fine -- an actual assignment is not, so this checks specifically
    # for the assignment form rather than the bare word.
    emit
    run grep -c '^[[:space:]]*boot_command[[:space:]]*=' "$OUT"
    [ "$output" = "0" ]
    run grep -c 'rc.cdrom.local\|minstallconfig\|Apple.s own' "$OUT"
    [ "$output" -ge 1 ]
}

@test "the template embeds no Apple bytes -- only paths and a checksum" {
    emit
    # Naming the file as a local path is fine; carrying it is not.
    run grep -cE 'InstallESD|BaseSystem' "$OUT"
    [ "$output" = "0" ]
    # The profile has no applesmc device and no Apple OSK string, and this
    # template must never carry one either.
    run grep -c 'osk=' "$OUT"
    [ "$output" = "0" ]
    run bash -c "wc -c < '$OUT'"
    [ "$output" -lt 20000 ]
}

@test "the vagrant post-processor is present and is local-only" {
    # decisions/0007 and test-hosts.md: a box made from this can never be
    # shared, because it contains Apple's OS. The template must not point
    # at Vagrant Cloud.
    emit
    run grep -c 'post-processor "vagrant"' "$OUT"
    [ "$output" = "1" ]
    run grep -c 'vagrantcloud\|app.vagrantup.com' "$OUT" || true
    [ "$output" = "0" ]
}

@test "every plugin the template uses is declared in required_plugins" {
    # The vagrant post-processor left Packer's core in 1.10 and is its own
    # plugin now. Undeclared, `packer validate` fails with "Unknown
    # post-processor type "vagrant"" -- MEASURED with Packer 1.16.1, the
    # first time any Packer parsed this template (NOTES.md, 2026-09-24).
    emit
    plugins=$(sed -n '/required_plugins {/,/^  }/p' "$OUT")
    [[ "$plugins" == *'github.com/hashicorp/qemu'* ]]
    [[ "$plugins" == *'github.com/hashicorp/vagrant'* ]]
}

@test "the fixed SSH forward uses host_port_min/max, not the deprecated ssh_ names" {
    # Packer 1.16.1's validate warns that ssh_host_port_min/max "will error
    # your builds" in a future version. p4-linuxmedia forwards 2223.
    emit
    run grep -c '^[[:space:]]*host_port_min[[:space:]]*= 2223$' "$OUT"
    [ "$output" = "1" ]
    run grep -c '^[[:space:]]*host_port_max[[:space:]]*= 2223$' "$OUT"
    [ "$output" = "1" ]
    run grep -c '^[[:space:]]*ssh_host_port_m\(in\|ax\)[[:space:]]*=' "$OUT"
    [ "$output" = "0" ]
}

@test "the template says what packer validate has and has not proven" {
    # Validation checks field names, nesting and types. It does not boot
    # anything: no Packer BUILD has run from this template, so the drive
    # mapping and SSH reachability remain REASONED.
    emit
    run grep -c 'packer validate' "$OUT"
    [ "$output" -ge 1 ]
    run grep -ci 'no packer build has ever run' "$OUT"
    [ "$output" -ge 1 ]
    run grep -c 'NO PACKER HAS EVER PARSED' "$OUT"
    [ "$output" = "0" ]
}

@test "--describe prints where each field's value came from and writes nothing" {
    run "$VMAVS" emit packer --profile p4-linuxmedia --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"MEASURED"* || "$output" == *"REASONED"* ]]
    [ ! -f "$OUT" ]
}

@test "--check says plainly that it could not validate when packer is absent" {
    # A PATH that merely prepends an empty directory hides nothing: if
    # packer is installed anywhere ELSE on the real PATH, it is still
    # found there. The stub PATH below holds symlinks to exactly the
    # tools emit/packer.sh (and the libraries it sources) actually call --
    # bash, env, dirname, cat, sed, tr, head, basename -- and nothing
    # else, the same technique tests/doctor.bats uses to hide qemu. If
    # this host happens to have packer installed, a prepend-only PATH
    # would let this test pass for the wrong reason (or fail outright by
    # actually invoking a real packer validate); the stub PATH does not
    # have that failure mode.
    STUB="$BATS_TEST_TMPDIR/stub-nopacker"
    mkdir -p "$STUB"
    for t in bash env dirname cat sed tr head basename; do
        ln -s "$(command -v "$t")" "$STUB/$t"
    done
    run env PATH="$STUB" \
        "$VMAVS" emit packer --profile p4-linuxmedia --out "$OUT" --check
    # Cannot-verify is never a pass. Checking "packer" and "not" as two
    # separate substrings would also be satisfied by bash's own "packer:
    # command not found" if this script ever called the bare command
    # instead of checking with `command -v` first -- which is precisely
    # the failure this stub PATH exists to distinguish from a real,
    # deliberate refusal. Asserting the specific "not installed" phrase
    # from this script's own die message pins it to that refusal.
    [ "$status" -ne 0 ]
    [[ "$output" == *"packer is not installed"* ]]
}

# A stub PATH holding what --check needs plus a fake packer that records
# its arguments, and whether each file-valued -var existed while it ran.
check_stub() {
    STUB="$BATS_TEST_TMPDIR/stub-recpacker"
    mkdir -p "$STUB"
    for t in bash env dirname cat sed tr head basename mktemp rm ssh-keygen grep; do
        ln -s "$(command -v "$t")" "$STUB/$t"
    done
    cat > "$STUB/packer" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/packer-args"
for a in "\$@"; do
    case \$a in
        ssh_key=*) f=\${a#ssh_key=}; [ -s "\$f" ] && grep -q 'OPENSSH PRIVATE KEY' "\$f" \
                       && echo present > "$BATS_TEST_TMPDIR/key-seen" ;;
    esac
done
exit ${1:-0}
EOF
    chmod +x "$STUB/packer"
}

@test "--check gives packer validate a value for every variable, and a real key" {
    # validate refuses unset variables, and the qemu plugin parses
    # ssh_private_key_file -- an empty or missing file fails with "no key
    # found". MEASURED with Packer 1.16.1 / qemu plugin 1.1.6.
    check_stub 0
    run env PATH="$STUB" \
        "$VMAVS" emit packer --profile p4-linuxmedia --out "$OUT" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"packer validate: OK"* ]]
    args=$(cat "$BATS_TEST_TMPDIR/packer-args")
    [[ "$args" == validate* ]]
    for v in $(sed -n 's/^variable "\([a-z_]*\)" {$/\1/p' "$OUT"); do
        [[ "$args" == *"$v="* ]] || { echo "no -var for $v"; false; }
    done
    [ "$(cat "$BATS_TEST_TMPDIR/key-seen")" = present ]
}

@test "--check leaves no placeholder key behind" {
    check_stub 0
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    run env PATH="$STUB" TMPDIR="$TMPDIR" \
        "$VMAVS" emit packer --profile p4-linuxmedia --out "$OUT" --check
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "emit refuses a profile that does not exist, and lists the ones that do" {
    run "$VMAVS" emit packer --profile nonesuch --out "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nonesuch"* ]]
    [[ "$output" == *"p4-linuxmedia"* ]]
}

@test "emit refuses a target it does not have" {
    run "$VMAVS" emit libvirt
    [ "$status" -ne 0 ]
    [[ "$output" == *"packer"* ]]
}

# --- fix round 1: drive mapping, provenance, and the Tier 2 quarantine -----

@test "emit packer on p3-full derives its real NIC, and never fabricates a port forward" {
    # p3-full uses e1000-82545em with no hostfwd at all -- unlike
    # p4-linuxmedia, which uses usb-net with hostfwd tcp::2223-:22. An
    # earlier version of this script hardcoded "usb-net" and defaulted a
    # missing hostfwd to 2222, so EVERY profile's template claimed a
    # forwarded port regardless of what that profile actually configures.
    run "$VMAVS" emit packer --profile p3-full --out "$OUT"
    [ "$status" -eq 0 ]
    run grep -c 'e1000-82545em' "$OUT"
    [ "$output" -ge 1 ]
    run grep -c 'usb-net' "$OUT"
    [ "$output" = "0" ]
    run grep -c 'hostfwd=tcp::2222\|hostfwd=tcp::2223' "$OUT"
    [ "$output" = "0" ]
    # A comment MENTIONING ssh_host_port_min/max, to explain their
    # absence, is fine (and expected) -- an actual assignment is not.
    run grep -c '^[[:space:]]*ssh_host_port_m\(in\|ax\)[[:space:]]*=' "$OUT"
    [ "$output" = "0" ]
}

@test "a value the profile does not set is labelled REASONED, not MEASURED" {
    # A scratch profile with none of -machine/-cpu/-m/-smp/-netdev of its
    # own (and no @include), so every one of those fields can only come
    # from this script's or image/build-image.sh's fallback default --
    # and --describe must say so, not claim MEASURED or INHERITED for a
    # value nothing in vm/profiles/ actually set.
    SCRATCH="$BATS_TEST_TMPDIR/profiles"
    mkdir -p "$SCRATCH"
    printf '%s\n' '# scratch profile: no -cpu/-machine/-m/-smp/-netdev of its own' \
        '-display' 'none' > "$SCRATCH/scratch-minimal.args"
    run env PROFILE_DIR="$SCRATCH" \
        "$VMAVS" emit packer --profile scratch-minimal --describe
    [ "$status" -eq 0 ]
    cpu_row=$(printf '%s\n' "$output" | grep -A1 '  cpu_model')
    [[ "$cpu_row" == *"REASONED"* ]]
    [[ "$cpu_row" != *"MEASURED"* ]]
    machine_row=$(printf '%s\n' "$output" | grep -A1 '  machine_type')
    [[ "$machine_row" == *"REASONED"* ]]
}

@test "a value two @include hops away is kept, not overwritten by a fallback" {
    # Fix-round-2 finding: value_source originally looked only ONE level
    # of @include deep, and the code that decided whether to apply a
    # fallback default trusted that shallow check -- so a value arriving
    # through a SECOND @include hop (deep -> p4-linuxmedia -> base-kvm)
    # was treated as absent and OVERWRITTEN with the wrong default, even
    # though profile_expand (fully recursive) had already parsed the
    # right one. This scratch tree reproduces exactly that shape: a
    # "deep" profile that only @includes p4-linuxmedia (itself unmodified
    # -- it sets -machine/-cpu directly, one hop from "deep"), whose own
    # @include base-kvm is replaced here with a scratch copy carrying -m
    # 8192 instead of the real 4096, so a pass that accidentally read the
    # real vm/profiles/base-kvm.args instead of this scratch one would be
    # caught by the wrong number.
    SCRATCH="$BATS_TEST_TMPDIR/profiles"
    mkdir -p "$SCRATCH"
    cp "$REPO/vm/profiles/p4-linuxmedia.args" "$SCRATCH/p4-linuxmedia.args"
    printf '%s\n' '-enable-kvm' '-m' '8192' '-smp' '2' > "$SCRATCH/base-kvm.args"
    printf '%s\n' '@include p4-linuxmedia' > "$SCRATCH/deep.args"

    run env PROFILE_DIR="$SCRATCH" \
        "$VMAVS" emit packer --profile deep --describe
    [ "$status" -eq 0 ]

    # memory: two hops away (deep -> p4-linuxmedia -> base-kvm). Must be
    # the scratch base-kvm's real value (8192), and must NOT be
    # REASONED/fallback -- it plainly is not absent.
    mem_row=$(printf '%s\n' "$output" | grep -A1 '  memory')
    [[ "$mem_row" == *"8192"* ]]
    [[ "$mem_row" != *"REASONED"* ]]
    [[ "$mem_row" == *"INHERITED"* ]]

    # machine_type: one hop away (deep -> p4-linuxmedia, which sets
    # -machine directly). A regression here would mean the fix broke the
    # already-working one-hop case while fixing the two-hop one.
    machine_row=$(printf '%s\n' "$output" | grep -A1 '  machine_type')
    [[ "$machine_row" == *"vmport=off"* ]]
    [[ "$machine_row" != *"REASONED"* ]]
}

@test "a value two @include hops away survives into the written template too" {
    # Same scratch tree as the --describe test above, this time checking
    # the emitted file itself rather than --describe's report.
    SCRATCH="$BATS_TEST_TMPDIR/profiles"
    mkdir -p "$SCRATCH"
    cp "$REPO/vm/profiles/p4-linuxmedia.args" "$SCRATCH/p4-linuxmedia.args"
    printf '%s\n' '-enable-kvm' '-m' '8192' '-smp' '2' > "$SCRATCH/base-kvm.args"
    printf '%s\n' '@include p4-linuxmedia' > "$SCRATCH/deep.args"

    run env PROFILE_DIR="$SCRATCH" \
        "$VMAVS" emit packer --profile deep --out "$OUT"
    [ "$status" -eq 0 ]
    run grep -c 'memory       = 8192' "$OUT"
    [ "$output" = "1" ]
    run grep -c 'machine_type = "q35,vmport=off"' "$OUT"
    [ "$output" = "1" ]
}

@test "emit refuses a profile that expands into the Tier 2 quarantine" {
    # A %VENDOR% placeholder in a profile is exactly what
    # bin/tier-check.sh guards vm/profiles/ against; emit must refuse it
    # at the source rather than faithfully copying a quarantine path into
    # an emitted template. Proven with a scratch PROFILE_DIR -- nothing
    # planted in the real vm/profiles/.
    SCRATCH="$BATS_TEST_TMPDIR/profiles"
    mkdir -p "$SCRATCH"
    printf '%s\n' '-drive' 'file=%VENDOR%/some-reference.img' \
        > "$SCRATCH/scratch-tier2.args"
    run env PROFILE_DIR="$SCRATCH" MQG_VENDOR_DIR="$BATS_TEST_TMPDIR/vendor" \
        "$VMAVS" emit packer --profile scratch-tier2 --out "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scratch-tier2"* ]]
    [[ "$output" == *"quarantine"* || "$output" == *"Tier 2"* ]]
    [ ! -f "$OUT" ]
}

@test "tier-check covers emit/, so a template cannot reach into the Tier 2 quarantine" {
    run grep -c 'emit' "$REPO/bin/tier-check.sh"
    [ "$output" -ge 1 ]
}

@test "tier-check flags a planted Tier 2 reference under emit/, names it, and a clean control passes" {
    # bin/tier-check.sh scans vm/profiles via PROFILE_DIR for references to
    # MQG_VENDOR_DIR; this task extends that same scan to emit/. Proven
    # against the REAL tier-check.sh, but pointed at a throwaway directory
    # (MQG_TIER_EMIT_DIR) holding one planted offender -- never against the
    # real repository, so nothing planted ever ships.
    export MQG_VENDOR_DIR="$BATS_TEST_TMPDIR/vendor-quarantine"
    EMITDIR="$BATS_TEST_TMPDIR/emit"
    mkdir -p "$EMITDIR"
    printf 'vendor_path = "%s/whatever"\n' "$MQG_VENDOR_DIR" > "$EMITDIR/planted.hcl"
    run env MQG_VENDOR_DIR="$MQG_VENDOR_DIR" MQG_TIER_EMIT_DIR="$EMITDIR" \
        "$REPO/bin/tier-check.sh" --strict
    [ "$status" -ne 0 ]
    [[ "$output" == *"planted.hcl"* ]]

    # Clean control: the SAME emit dir, holding only an inoffensive file,
    # must pass -- proving the failure above is caused by the planted
    # reference and not by some other property of a nonstandard
    # MQG_TIER_EMIT_DIR (a missing directory, an empty one, etc).
    rm -f "$EMITDIR/planted.hcl"
    printf '# nothing interesting here\n' > "$EMITDIR/clean.hcl"
    run env MQG_VENDOR_DIR="$MQG_VENDOR_DIR" MQG_TIER_EMIT_DIR="$EMITDIR" \
        "$REPO/bin/tier-check.sh" --strict
    [ "$status" -eq 0 ]
}

# --- final review: a profile that cannot be expanded writes nothing ---------

@test "an include cycle fails, names the cycle, and writes no template" {
    # MEASURED before the fix: a -> b -> a, with -cpu set only in b,
    # exited 0 and wrote a template whose cpu_model was labelled
    # "REASONED -- no -cpu line anywhere". profile_expand died inside a
    # process substitution, which ends only the subshell.
    SCRATCH="$BATS_TEST_TMPDIR/profiles"
    mkdir -p "$SCRATCH"
    printf '%s\n' '@include b' '-m' '4096' > "$SCRATCH/a.args"
    printf '%s\n' '-cpu' 'Penryn' '@include a' > "$SCRATCH/b.args"
    run env PROFILE_DIR="$SCRATCH" "$VMAVS" emit packer --profile a --out "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"profile include cycle"* ]]
    [ ! -e "$OUT" ]
    run env PROFILE_DIR="$SCRATCH" "$VMAVS" emit packer --profile a --describe
    [ "$status" -ne 0 ]
    [[ "$output" != *"cpu_model"* ]]
}

@test "a missing @include fails, names the missing profile, and says it in words" {
    # MEASURED before the fix: exit 0, plus eight raw bash "No such file
    # or directory" lines from the provenance helpers.
    SCRATCH="$BATS_TEST_TMPDIR/profiles"
    mkdir -p "$SCRATCH"
    printf '%s\n' '@include nonesuch' '-m' '4096' > "$SCRATCH/lonely.args"
    run env PROFILE_DIR="$SCRATCH" "$VMAVS" emit packer --profile lonely --out "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such profile: nonesuch"* ]]
    [[ "$output" != *"No such file"* ]]
    [ ! -e "$OUT" ]
}

@test "--check without --out fails before writing the template anywhere" {
    run "$VMAVS" emit packer --profile p4-linuxmedia --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"--check needs --out"* ]]
    [[ "$output" != *'source "qemu"'* ]]
}

@test "--check says packer init may be needed, and does not call the template broken" {
    # A packer that fails validate, as a real one does when the plugin
    # required_plugins names has not been fetched by `packer init`. This
    # script never runs init (it downloads), so it must not present that
    # failure as a verified template defect. The stub PATH holds only the
    # tools emit needs plus this fake packer -- no real one can be found.
    STUB="$BATS_TEST_TMPDIR/stub-badpacker"
    mkdir -p "$STUB"
    for t in bash env dirname cat sed tr head basename mktemp rm ssh-keygen; do
        ln -s "$(command -v "$t")" "$STUB/$t"
    done
    printf '#!/bin/sh\necho "Error: Missing plugins" >&2\nexit 1\n' > "$STUB/packer"
    chmod +x "$STUB/packer"
    run env PATH="$STUB" \
        "$VMAVS" emit packer --profile p4-linuxmedia --out "$OUT" --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"packer init"* ]]
    [[ "$output" == *"NOT yet a verified template failure"* ]]
}

@test "provenance names the profile's commit in a git worktree, where .git is a file" {
    # profile_commit tested `-d .git`; in a worktree .git is a file, so
    # the commit silently vanished from the header. A throwaway repo
    # holding just what emit needs, and a worktree of it.
    T="$BATS_TEST_TMPDIR/wt-src"
    mkdir -p "$T/vm" "$T/image"
    cp -R "$REPO/bin" "$REPO/lib" "$REPO/emit" "$T/"
    cp -R "$REPO/vm/profiles" "$T/vm/"
    cp "$REPO/image/build-image.sh" "$T/image/"
    git -C "$T" init -q
    git -C "$T" add -A
    git -C "$T" -c user.name=t -c user.email=t@example.invalid \
        -c commit.gpgsign=false commit -qm fixture
    git -C "$T" worktree add -q "$BATS_TEST_TMPDIR/wt" 2>/dev/null
    [ -f "$BATS_TEST_TMPDIR/wt/.git" ]
    want=$(git -C "$T" log -1 --format=%h)
    run "$BATS_TEST_TMPDIR/wt/bin/vmavs" emit packer --profile p4-linuxmedia --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"p4-linuxmedia.args @ $want"* ]] || { echo "$output"; false; }
}
