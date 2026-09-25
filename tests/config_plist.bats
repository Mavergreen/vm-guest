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

@test "ScanPolicy admits only HFS+ on SATA, so the picker has exactly one entry" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
print(d['Misc']['Security']['ScanPolicy'])" "$PLIST"
    policy="$output"

    # Not 0. ScanPolicy 0 means scan everything, which made OpenCore list its
    # own image as a boot entry, default to it, time out into it and hang --
    # the bug that made the guest need a keypress to boot.
    [ "$policy" -ne 0 ]

    # OC_SCAN_FILE_SYSTEM_LOCK 0x1 and OC_SCAN_DEVICE_LOCK 0x2: without the
    # lock bits the allow bits mean nothing, and OpenCore rejects an allow
    # bit whose lock is missing ("Invalid ScanPolicy").
    [ $(( policy & 0x1 )) -ne 0 ]
    [ $(( policy & 0x2 )) -ne 0 ]

    # OC_SCAN_ALLOW_FS_HFS 0x200 -- the macOS volume.
    [ $(( policy & 0x200 )) -ne 0 ]

    # OC_SCAN_ALLOW_DEVICE_SATA 0x10000 -- q35's ide-hd presents as SATA.
    [ $(( policy & 0x10000 )) -ne 0 ]

    # And NOT usb: the OpenCore image lives on usb-storage, and admitting it
    # is what caused the hang.
    [ $(( policy & 0x80000 )) -eq 0 ]
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
        grep -q "${bundle%%.kext}" "$REPO/assets/pins/sources.tsv" \
            || { echo "kext not pinned in sources.tsv: $bundle"; return 1; }
    done <<< "$output"
}
