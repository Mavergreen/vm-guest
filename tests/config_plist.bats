#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PLIST="$REPO/boot/config/config.plist"
}

@test "our config.plist exists and is a readable plist" {
    [ -f "$PLIST" ]
    run python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$PLIST"
    [ "$status" -eq 0 ]
}

@test "SMBIOS is iMac14,2, not MacPro5,1" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
print(d['PlatformInfo']['Generic']['SystemProductName'])" "$PLIST"
    [ "$output" = "iMac14,2" ]
}

@test "the HFS+ driver is OpenHfsPlus, never Apple's HfsPlus" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
for x in d['UEFI']['Drivers']:
    print(x['Path'] if isinstance(x,dict) else x)" "$PLIST"
    [ "$status" -eq 0 ]
    # Whole names, not substrings. "OpenHfsPlus.efi" *contains* the string
    # "HfsPlus.efi", so a substring test for Apple's driver can never pass
    # while ours is present -- it would look like a passing guard and guard
    # nothing. See docs/decisions/0002.
    seen_ours=0
    while read -r driver; do
        [ -n "$driver" ] || continue
        [ "$driver" != "HfsPlus.efi" ]
        [ "$driver" != "HfsPlusLegacy.efi" ]
        if [ "$driver" = "OpenHfsPlus.efi" ]; then
            seen_ours=1
        fi
    done <<< "$output"
    [ "$seen_ours" -eq 1 ]
}

@test "SecureBootModel is disabled, since 10.9 predates it" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
print(d['Misc']['Security']['SecureBootModel'])" "$PLIST"
    [ "$output" = "Disabled" ]
}

@test "ScanPolicy is 0, so the picker scans everything" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
print(d['Misc']['Security']['ScanPolicy'])" "$PLIST"
    [ "$output" = "0" ]
}

@test "every enabled kext in Kernel>Add is one we have pinned" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
for k in d['Kernel']['Add']:
    if k.get('Enabled'): print(k['BundlePath'])" "$PLIST"
    [ "$status" -eq 0 ]
    while read -r bundle; do
        [ -z "$bundle" ] && continue
        grep -q "${bundle%%.kext}" "$REPO/vendor/sources.tsv" \
            || { echo "kext not pinned in sources.tsv: $bundle"; return 1; }
    done <<< "$output"
}
