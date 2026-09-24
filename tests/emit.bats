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

@test "the template says out loud that no Packer has parsed it" {
    emit
    run grep -ci 'never been\|unverified\|packer validate' "$OUT"
    [ "$output" -ge 1 ]
}

@test "--describe prints where each field's value came from and writes nothing" {
    run "$VMAVS" emit packer --profile p4-linuxmedia --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"MEASURED"* || "$output" == *"REASONED"* ]]
    [ ! -f "$OUT" ]
}

@test "--check says plainly that it could not validate when packer is absent" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run env PATH="$BATS_TEST_TMPDIR/empty:$PATH" \
        "$VMAVS" emit packer --profile p4-linuxmedia --out "$OUT" --check
    # Cannot-verify is never a pass.
    [ "$status" -ne 0 ]
    [[ "$output" == *"packer"* ]]
    [[ "$output" == *"not"* ]]
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

@test "tier-check covers emit/, so a template cannot reach into the Tier 2 quarantine" {
    run grep -c 'emit' "$REPO/bin/tier-check.sh"
    [ "$output" -ge 1 ]
}

@test "a template that reached into the Tier 2 quarantine fails tier-check --strict" {
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
}
