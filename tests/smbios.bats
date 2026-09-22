#!/usr/bin/env bats
#
# The guest SMBIOS tested-options table and the plist edit behind
# --smbios (lib/smbios.sh, docs/decisions/0010).
#
# Same discipline as tests/cpu.bats: the verdict function is pure, so every
# branch is exercised on one host, and the constants are asserted so that a
# change to the table cannot quietly leave the ADR, the ledger and
# docs/test-hosts.md describing something else.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/smbios.sh"
    PLIST="$REPO/boot/config/config.plist"
}

# --- what the table IS ------------------------------------------------------

@test "the default is the model three full installs were done with" {
    [ "$MQG_SMBIOS_DEFAULT" = 'iMac14,2' ]
    run smbios_verdict "$MQG_SMBIOS_DEFAULT"
    [ "$status" -eq 0 ]
    [[ "$output" == VERIFIED* ]]
}

# The value in the config and the default in the table are the same claim
# written twice. If they ever disagree, every image built without --smbios
# gets one of them and every message about it says the other.
@test "the default matches what boot/config/config.plist actually ships" {
    run smbios_plist_product_name "$PLIST"
    [ "$status" -eq 0 ]
    [ "$output" = "$MQG_SMBIOS_DEFAULT" ]
}

@test "MacPro5,1 is PANICKED, dates every sighting, and now carries the measured cause" {
    run smbios_verdict MacPro5,1
    [ "$status" -eq 0 ]
    [[ "$output" == PANICKED* ]]
    [[ "$output" == *"AppleTyMCEDriver"* ]]
    # Every sighting with its date: a row that said only "it panics" would
    # be the inherited, undated claim this project has been wrong about
    # four times.
    [[ "$output" == *"2026-09-17"* ]]
    [[ "$output" == *"2026-09-21"* ]]
    [[ "$output" == *"2026-09-22"* ]]
}

# This test replaced one that asserted the explanation was STILL UNTESTED
# and that "only a Xeon host can test it". Both were true until
# 2026-09-22 and both are now false -- a Xeon panicked too, and the cause
# was measured off the panic screen. The assertions below are what the
# row has to keep saying instead, and they are deliberately specific: the
# ONE number that settles it, and the ONE control that proves it.
@test "the MacPro5,1 row names the MSR and the accelerator control" {
    run smbios_verdict MacPro5,1
    [ "$status" -eq 0 ]
    # RCX = 0x280 = IA32_MC0_CTL2, read straight off the panic dump.
    [[ "$output" == *"0x280"* ]]
    [[ "$output" == *"IA32_MC0_CTL2"* ]]
    # Why ignore_msrs cannot help: KVM returns 1, not the UNSUPPORTED
    # sentinel, so the knob is never consulted.
    [[ "$output" == *"MCG_CMCI_P"* ]]
    [[ "$output" == *"ignore_msrs"* ]]
    # The one-variable control, which is what makes it a measurement
    # rather than a story.
    [[ "$output" == *"tcg"* ]]
    # And the falsifier, written down before anyone tries.
    [[ "$output" == *"FALSIFY"* ]]
    [[ "$output" == *"older than 6.0"* ]]
}

@test "an unknown model is UNLISTED, which is not a refusal" {
    run smbios_verdict iMac11,2
    [ "$status" -eq 0 ]
    [[ "$output" == UNLISTED* ]]
    [[ "$output" == *"still works"* ]]
}

@test "every row has a status this file has a sentence for" {
    while IFS=$'\t' read -r model status evidence; do
        [ -n "$model" ]
        [ -n "$evidence" ]
        run smbios_status_text "$status"
        [ "$status" != "" ]
        [[ "$output" != unknown\ status* ]]
    done < <(smbios_models)
}

# --- what is refused, and what is only warned about -------------------------

@test "an arbitrary model is well-formed: the table is guidance, not a whitelist" {
    run smbios_wellformed "MacBookPro11,3"
    [ "$status" -eq 0 ]
}

@test "a string that would break the plist is refused" {
    # Each of these produces a config.plist failure that looks like a guest
    # failure, which is the one thing worth refusing over.
    local bad
    for bad in "" "Mac Pro5,1" "<iMac14,2>" "a&b" "iMac14,2\"" "iMac14,2'"; do
        run smbios_wellformed "$bad"
        [ "$status" -ne 0 ]
    done
}

@test "a 65-character model is refused and a 64-character one is not" {
    run smbios_wellformed "$(printf 'a%.0s' $(seq 1 64))"
    [ "$status" -eq 0 ]
    run smbios_wellformed "$(printf 'a%.0s' $(seq 1 65))"
    [ "$status" -ne 0 ]
}

# --- the plist edit ---------------------------------------------------------

@test "smbios_plist_set changes SystemProductName and nothing else" {
    run smbios_plist_set "$PLIST" MacPro5,1
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/out.plist"
    # Exactly one line differs from the original.
    run diff "$PLIST" "$BATS_TEST_TMPDIR/out.plist"
    [ "$status" -ne 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^[<>]')" -eq 2 ]
    [[ "$output" == *"<string>iMac14,2</string>"* ]]
    [[ "$output" == *"<string>MacPro5,1</string>"* ]]
}

@test "the result is still a plist, and the fields we deliberately leave alone are untouched" {
    smbios_plist_set "$PLIST" MacPro5,1 > "$BATS_TEST_TMPDIR/out.plist"
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))['PlatformInfo']
g=d['Generic']
print(g['SystemProductName'], g['SystemSerialNumber'], g['MLB'], g['SystemUUID'], d['Automatic'])" \
        "$BATS_TEST_TMPDIR/out.plist"
    [ "$status" -eq 0 ]
    # The serial, the board serial and the UUID are the placeholders the
    # repo config ships, on purpose: OpenCore derives the board id from the
    # product name because Automatic is true, and a half-changed SMBIOS
    # would produce a failure about our edit rather than about the guest.
    # See docs/decisions/0010.
    [ "$output" = "MacPro5,1 W00000000001 M0000000000000001 00000000-0000-0000-0000-000000000000 True" ]
}

@test "setting the model that is already there is a no-op on the bytes" {
    smbios_plist_set "$PLIST" iMac14,2 > "$BATS_TEST_TMPDIR/same.plist"
    run cmp -s "$PLIST" "$BATS_TEST_TMPDIR/same.plist"
    [ "$status" -eq 0 ]
}

@test "smbios_plist_set refuses a value it cannot write" {
    run smbios_plist_set "$PLIST" "<oops>"
    [ "$status" -ne 0 ]
}

@test "smbios_plist_set refuses a plist that does not have exactly one SystemProductName" {
    # Two keys means two answers to "what is this machine", and guessing
    # which one PlatformInfo reads is how a half-changed SMBIOS happens.
    sed 's|<key>SystemProductName</key>|<key>SystemProductName</key>\
\t\t\t<string>iMac14,2</string>\
\t\t\t<key>SystemProductName</key>|' "$PLIST" > "$BATS_TEST_TMPDIR/two.plist"
    run smbios_plist_set "$BATS_TEST_TMPDIR/two.plist" MacPro5,1
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to guess"* ]]
}

# --- the manifest line ------------------------------------------------------

@test "the manifest line carries the status and the evidence" {
    run smbios_manifest iMac14,2
    [ "$status" -eq 0 ]
    [[ "$output" == VERIFIED\ --* ]]
    [[ "$output" == *"three hosts"* ]]
}

@test "smbios_check warns and never dies on an unlisted model" {
    run smbios_check SomeMac1,1
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning"* ]]
}

@test "smbios_check warns and never dies on the model that panicked" {
    run smbios_check MacPro5,1
    [ "$status" -eq 0 ]
    [[ "$output" == *"screenshot"* ]]
}
