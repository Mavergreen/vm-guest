#!/usr/bin/env bats
#
# The unattended install. Two kinds of test here:
#
#   * static checks that the injected files say what they must say -- the
#     partition scheme especially, because getting it wrong is invisible
#     until after a full install;
#   * behavioural checks of the target-disk selection, driven against
#     captured `diskutil list` output. Picking the wrong disk erases the
#     installer media, so "I read the code carefully" is not enough.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    AUTO="$REPO/image/autoinstall/autoinstall.sh"
}

# Writes a stub `diskutil` that answers `list`, `list /dev/diskN` and
# `info /dev/diskN` from a table of "<id> <bytes> <slices>" lines.
make_diskutil() {
    local specs=( "$@" ) spec id bytes slices i
    mkdir -p "$BATS_TEST_TMPDIR/stub"
    STUB="$BATS_TEST_TMPDIR/stub/diskutil"
    {
        echo '#!/bin/sh'
        echo 'case "$1 ${2:-}" in'
        printf '"list ")\n'
        for spec in "${specs[@]}"; do
            read -r id bytes slices <<< "$spec"
            printf '  echo "/dev/%s"\n' "$id"
            printf '  echo "   0:  something  *size  %s"\n' "$id"
            for ((i = 1; i <= slices; i++)); do
                printf '  echo "   %d:  Apple_HFS name  size  %ss%d"\n' "$i" "$id" "$i"
            done
        done
        printf '  ;;\n'
        for spec in "${specs[@]}"; do
            read -r id bytes slices <<< "$spec"
            printf '"list /dev/%s")\n' "$id"
            printf '  echo "/dev/%s"\n' "$id"
            printf '  echo "   0:  something  *size  %s"\n' "$id"
            for ((i = 1; i <= slices; i++)); do
                printf '  echo "   %d:  Apple_HFS name  size  %ss%d"\n' "$i" "$id" "$i"
            done
            printf '  ;;\n'
            printf '"info /dev/%s")\n' "$id"
            printf '  echo "   Total Size: x GB (%s Bytes) (exactly n 512-Byte-Units)"\n' "$bytes"
            printf '  ;;\n'
        done
        printf '*) echo "unhandled: $*" >&2; exit 1 ;;\n'
        echo 'esac'
    } > "$STUB"
    chmod +x "$STUB"
}

run_selection() {
    run env MQG_AUTOINSTALL_DRY_RUN=1 \
        MQG_DISKUTIL="$STUB" \
        MQG_AUTOINSTALL_LOG="$BATS_TEST_TMPDIR/auto.log" \
        MQG_TARGET_WAIT=0 \
        "$AUTO"
}

@test "autoinstall.sh partitions GPT, never the older Apple scheme" {
    run grep -c 'GPT' "$AUTO"
    [ "$output" -ge 1 ]
    run grep -ci 'APM\|Apple_partition_scheme' "$AUTO"
    [ "$output" = "0" ]
}

@test "autoinstall.sh refuses to erase when the target is ambiguous" {
    run grep -cE 'refus|ambiguous|more than one' "$AUTO"
    [ "$output" -ge 1 ]
}

@test "autoinstall.sh never hardcodes the first disk" {
    run grep -cE '/dev/disk0([^0-9]|$)' "$AUTO"
    [ "$output" = "0" ]
}

@test "the only unpartitioned disk is the one chosen" {
    # p4-linuxmedia's actual layout: a blank 60 GB target, the 6.7 GB
    # installer media, and the 200 MB OpenCore image.
    make_diskutil "disk0 64424509440 0" "disk1 6686769152 1" "disk2 201326592 1"
    run_selection
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "disk0" ]
}

@test "the chosen disk is not assumed to be the first one" {
    make_diskutil "disk0 6686769152 1" "disk1 201326592 1" "disk2 64424509440 0"
    run_selection
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "disk2" ]
}

@test "two blank disks erase nothing" {
    # The failure that matters. Two candidates means we cannot tell the
    # target from something else blank, so nothing is touched.
    make_diskutil "disk0 64424509440 0" "disk1 64424509440 0" "disk2 201326592 1"
    run_selection
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING TO PROCEED"* ]]
    [[ "$output" == *"more than one"* ]]
}

@test "no blank disk erases nothing" {
    make_diskutil "disk0 6686769152 1" "disk1 201326592 1"
    run_selection
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING TO PROCEED"* ]]
}

@test "a blank disk too small to be the target is not chosen" {
    # Guards against a future profile attaching a small scratch disk and
    # this quietly erasing it.
    make_diskutil "disk0 268435456 0" "disk1 6686769152 1"
    run_selection
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING TO PROCEED"* ]]
}

@test "the installer media is never a candidate, whatever its size" {
    # Partitioned is partitioned: the media is 6.7 GB and would pass a
    # size test on its own.
    make_diskutil "disk0 6686769152 1"
    run_selection
    [[ "$output" == *"already partitioned"* ]]
    [ "$status" -ne 0 ]
}

@test "the selection log says why each disk was rejected" {
    make_diskutil "disk0 64424509440 0" "disk1 6686769152 1" "disk2 201326592 1"
    run_selection
    run cat "$BATS_TEST_TMPDIR/auto.log"
    [[ "$output" == *"disk1: 6686769152 bytes, 1 partitions -- skipped"* ]]
    [[ "$output" == *"disk0: 64424509440 bytes, unpartitioned -- CANDIDATE"* ]]
}

@test "minstallconfig.xml is a valid plist that asks for an automated install" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
for k in ('InstallType','Package','Target','TargetName'):
    print(k, '=', d[k])
" "$REPO/image/autoinstall/minstallconfig.xml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"InstallType = automated"* ]]
    [[ "$output" == *"OSInstall.collection"* ]]
}

@test "OSInstall.collection is a valid plist listing OSInstall.mpkg" {
    run python3 -c "
import plistlib,sys
a=plistlib.load(open(sys.argv[1],'rb'))
assert isinstance(a, list), a
print('\n'.join(a))
" "$REPO/image/autoinstall/OSInstall.collection"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/System/Installation/Packages/OSInstall.mpkg"* ]]
}

@test "the volume autoinstall.sh creates is the volume the installer targets" {
    # Two files name it independently. If they drift, the install runs
    # against a volume that does not exist and reboots in a loop.
    want=$(python3 -c "
import plistlib
print(plistlib.load(open('$REPO/image/autoinstall/minstallconfig.xml','rb'))['TargetName'])
")
    [ -n "$want" ]
    run grep -c "VOLNAME=\${MQG_TARGET_VOLUME:-$want}" "$AUTO"
    [ "$output" = "1" ]
    run python3 -c "
import plistlib
d=plistlib.load(open('$REPO/image/autoinstall/minstallconfig.xml','rb'))
print(d['Target'] == '/Volumes/' + d['TargetName'])
"
    [ "$output" = "True" ]
}

@test "build-installer-img.sh --autoinstall says what it will inject and where" {
    run "$REPO/media/build-installer-img.sh" --describe --autoinstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"private/etc/rc.cdrom.local"* ]]
    [[ "$output" == *"Extras/minstallconfig.xml"* ]]
    [[ "$output" == *"OSInstall.collection"* ]]
}

@test "build-installer-img.sh injects nothing unless asked" {
    run "$REPO/media/build-installer-img.sh" --describe
    [ "$status" -eq 0 ]
    [[ "$output" != *"rc.cdrom.local"* ]]
}

# ---------------------------------------------------------------------------
# Task 6: the first-boot payload.
#
# It ships as a flat .pkg listed in OSInstall.collection, so the installer
# installs it as part of the install -- upstream (timsutton/osx-vm-templates)
# does the same with its create_firstboot_pkg. Building one on Linux means
# writing the xar container ourselves; image/payload/mkflatpkg.py is that,
# and these tests check the container it produces as well as what the
# scripts inside it say.

@test "firstboot.sh skips Setup Assistant" {
    run grep -c 'AppleSetupDone' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
}

@test "firstboot.sh creates the account the click-log recorded" {
    run grep -cE 'mavsuser' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
    run grep -cE 'dscl' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
}

@test "firstboot.sh never contains an embedded private key or password" {
    run grep -ciE 'BEGIN (RSA|OPENSSH|DSA|EC) PRIVATE KEY' "$REPO/image/payload/firstboot.sh"
    [ "$output" = "0" ]
    run grep -ciE '^[^#]*password=[^$"]' "$REPO/image/payload/firstboot.sh"
    [ "$output" = "0" ]
}

@test "no file under image/payload/ carries a public key either" {
    # The key is a build-time parameter. One committed by accident would
    # grant its holder every image this pipeline ever builds.
    #
    # Matches an actual key BLOB -- a type word followed by base64 starting
    # AAAA -- not merely the words. The first version matched the words, and
    # went red the moment build-firstboot-pkg.sh learned to name key types
    # in order to reject Ed25519. A test that cannot tell a key from a
    # mention of one is a test that will be deleted the first time it cries
    # wolf.
    run bash -c "grep -rlE '(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+) +AAAA' '$REPO/image/payload/' | grep -c ."
    [ "$output" = "0" ]
    # And the guard itself works: plant one and watch it fire.
    printf 'ssh-rsa AAAAB3NzaC1yc2EAAAA notarealkey\n' \
        > "$BATS_TEST_TMPDIR/planted.pub"
    run bash -c "grep -rlE '(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+) +AAAA' '$BATS_TEST_TMPDIR/' | grep -c ."
    [ "$output" = "1" ]
}

@test "every network-touching step has a timeout" {
    # softwareupdate against Apple's 2026 servers can hang on a 2013 OS,
    # and 10.9 has no timeout(1), so firstboot.sh carries its own.
    run bash -c "grep -n 'softwareupdate' '$REPO/image/payload/firstboot.sh' | grep -vc 'timeout'"
    [ "$output" = "0" ]
}

@test "firstboot.sh removes its own LaunchDaemon so it runs exactly once" {
    run grep -cE 'rm .*com\.mqg\.firstboot|launchctl (unload|bootout)' \
        "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
}

@test "the firstboot LaunchDaemon plist is valid and runs at load" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
print(d['Label'], d.get('RunAtLoad'), ' '.join(d['ProgramArguments']))
" "$REPO/image/payload/com.mqg.firstboot.plist"
    [ "$status" -eq 0 ]
    [[ "$output" == *"firstboot.sh"* ]]
    [[ "$output" == *"True"* ]]
}

@test "the postinstall script installs the daemon and the script on the target" {
    run grep -c 'LaunchDaemons' "$REPO/image/payload/postinstall"
    [ "$output" -ge 1 ]
    # $3 is the target volume when the installer runs a postinstall script.
    run grep -c '\$3' "$REPO/image/payload/postinstall"
    [ "$output" -ge 1 ]
}

# --- the package builder -------------------------------------------------

@test "build-firstboot-pkg.sh --describe explains itself without building" {
    run "$REPO/image/payload/build-firstboot-pkg.sh" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"PackageInfo"* ]]
    [[ "$output" == *"Scripts"* ]]
}

@test "build-firstboot-pkg.sh refuses to build without an SSH key" {
    run env HOME="$BATS_TEST_TMPDIR/nohome" \
        "$REPO/image/payload/build-firstboot-pkg.sh" \
        --out "$BATS_TEST_TMPDIR/x.pkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ssh"* || "$output" == *"SSH"* ]]
}

@test "build-firstboot-pkg.sh builds a package that 7z reads as a xar pkg" {
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/k" </dev/null
    run "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/k.pub" \
        --out "$BATS_TEST_TMPDIR/fb.pkg"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/fb.pkg" ]
    run head -c 4 "$BATS_TEST_TMPDIR/fb.pkg"
    [ "$output" = "xar!" ]
    if command -v 7z >/dev/null 2>&1; then
        run 7z l "$BATS_TEST_TMPDIR/fb.pkg"
        [ "$status" -eq 0 ]
        [[ "$output" == *"PackageInfo"* ]]
        [[ "$output" == *"Scripts"* ]]
    fi
}

@test "the package contains exactly one file, with everything in it" {
    # PackageKit materialises only the file PackageInfo's <scripts> element
    # names. The first version shipped five files and copied four siblings;
    # the install then said "not in this package: firstboot.sh" while
    # running the fifth. One file, no siblings to be missing.
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/k" </dev/null
    "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/k.pub" \
        --out "$BATS_TEST_TMPDIR/fb.pkg" >/dev/null
    run python3 "$REPO/image/payload/mkflatpkg.py" --list-scripts \
        "$BATS_TEST_TMPDIR/fb.pkg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"./postinstall"* ]]
    # No scaffolding: the builder assembles postinstall in a second
    # directory, because everything in the staging directory is packaged.
    [ "$(printf '%s\n' "$output" | grep -c '^')" = "2" ]
}

@test "the postinstall script installs the payload on a target, offline" {
    # The whole first-boot payload, exercised against a directory instead of
    # a volume. This is the check that used to cost a 20-minute VM boot.
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/k" </dev/null
    "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/k.pub" \
        --out "$BATS_TEST_TMPDIR/fb.pkg" >/dev/null
    python3 "$REPO/image/payload/mkflatpkg.py" --cat-script \
        "$BATS_TEST_TMPDIR/fb.pkg" ./postinstall \
        > "$BATS_TEST_TMPDIR/postinstall"

    target="$BATS_TEST_TMPDIR/target"
    mkdir -p "$target"
    run sh "$BATS_TEST_TMPDIR/postinstall" /pkg /dest "$target" /
    [ "$status" -eq 0 ]

    # Setup Assistant is skipped at INSTALL time, not at first boot: a
    # LaunchDaemon with RunAtLoad has no guarantee of beating loginwindow
    # to it.
    [ -f "$target/private/var/db/.AppleSetupDone" ]

    conf="$target/private/var/db/.mqg-firstboot"
    [ -x "$conf/firstboot.sh" ]
    [ -f "$conf/firstboot.conf" ]
    [ -f "$conf/authorized_keys" ]
    [ -f "$target/Library/LaunchDaemons/com.mqg.firstboot.plist" ]

    # The script in the image is the script in the repository.
    run diff "$conf/firstboot.sh" "$REPO/image/payload/firstboot.sh"
    [ "$status" -eq 0 ]
    # The key in the image is the key that was asked for.
    run diff "$conf/authorized_keys" "$BATS_TEST_TMPDIR/k.pub"
    [ "$status" -eq 0 ]
    # The LaunchDaemon survives the round trip as a valid plist.
    run python3 -c "
import plistlib, sys
print(plistlib.load(open(sys.argv[1], 'rb'))['Label'])
" "$target/Library/LaunchDaemons/com.mqg.firstboot.plist"
    [ "$status" -eq 0 ]
    [ "$output" = "com.mqg.firstboot" ]
    # And the conf carries the parameters, with no secret unless asked.
    run cat "$conf/firstboot.conf"
    [[ "$output" == *"MQG_FB_USER=mavsuser"* ]]
    [[ "$output" != *"MQG_FB_PASSWORD"* ]]
}

@test "the same inputs produce a byte-identical package" {
    # The manifest records the payload's checksum, so the package has to be
    # a function of its inputs and nothing else -- no build timestamp, no
    # temp-directory name, no filesystem ordering.
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/k" </dev/null
    for n in 1 2; do
        "$REPO/image/payload/build-firstboot-pkg.sh" \
            --ssh-key "$BATS_TEST_TMPDIR/k.pub" \
            --out "$BATS_TEST_TMPDIR/fb$n.pkg" >/dev/null
    done
    run cmp "$BATS_TEST_TMPDIR/fb1.pkg" "$BATS_TEST_TMPDIR/fb2.pkg"
    [ "$status" -eq 0 ]
}

@test "build-installer-img.sh --describe names the firstboot package" {
    run "$REPO/media/build-installer-img.sh" --describe --autoinstall \
        --firstboot-pkg /nonexistent/fb.pkg
    [ "$status" -eq 0 ]
    [[ "$output" == *"OSInstall.collection"* ]]
    [[ "$output" == *"fb.pkg"* || "$output" == *"firstboot"* ]]
}

@test "the package's cpio entries carry file-type bits" {
    # The mistake that cost a full 20-minute install. The xar container was
    # read, PackageInfo was parsed, the identifier was recognised, and then:
    #
    #   PackageKit: Got copier error 21 ... cpio read error: bad file format
    #
    # A mode of 000755 tells BOM's cpio reader the entry has no type, so it
    # does not skip past the entry's data and everything after it is
    # garbage. Apple's own packages write 040755 for a directory and 100644
    # for a file. See the P4 Task 6 entry in NOTES.md.
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/k" </dev/null
    "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/k.pub" \
        --out "$BATS_TEST_TMPDIR/fb.pkg" >/dev/null
    run python3 - "$REPO/image/payload/mkflatpkg.py" "$BATS_TEST_TMPDIR/fb.pkg" <<'PY'
import gzip
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("mkflatpkg", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
raw = gzip.decompress(mod.read_xar_member(sys.argv[2], "Scripts"))
pos = 0
seen = []
while pos + 76 <= len(raw):
    mode_field = raw[pos + 18:pos + 24].decode("ascii")
    namesize = int(raw[pos + 59:pos + 65].decode("ascii"), 8)
    filesize = int(raw[pos + 65:pos + 76].decode("ascii"), 8)
    name = raw[pos + 76:pos + 76 + namesize - 1].decode()
    seen.append((name, mode_field))
    pos += 76 + namesize + filesize
    if name == "TRAILER!!!":
        break
for name, mode_field in seen:
    print(name, mode_field)
    assert mode_field[0] in "01", "%s has no file-type bits: %s" % (name, mode_field)
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *". 040755"* ]]
    [[ "$output" == *"./postinstall 100755"* ]]
    [[ "$output" == *"TRAILER!!!"* ]]
}

@test "an Ed25519 key is accepted, because the guest gets a modern OpenSSH" {
    # THIS TEST USED TO ASSERT THE OPPOSITE, AND THAT IS THE POINT.
    #
    # OS X 10.9 ships OpenSSH 6.2. Ed25519 arrived in 6.5, three months
    # after Mavericks shipped, so the guest's sshd could not parse such a
    # line in authorized_keys -- and the only symptom was "Permission
    # denied (publickey)" from a server that was otherwise working
    # perfectly: sshd running, account created, Remote Login on. That cost
    # a full 20-minute install to diagnose, and the workaround was to
    # refuse the key at build time.
    #
    # The guest now installs ModernMavericks/openssh (image/fetch-openssh.sh,
    # default on), so the defect is gone rather than worked around. The
    # test stays; what it asserts is inverted.
    ssh-keygen -q -t ed25519 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/ed" </dev/null
    printf 'xar!stand-in for a package\n' > "$BATS_TEST_TMPDIR/o.pkg"
    printf 'xar!stand-in for a package\n' > "$BATS_TEST_TMPDIR/o-System-Replace.pkg"
    run "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/ed.pub" \
        --openssh-tag 0.0p0-mavericks.0 \
        --openssh-pkg "$BATS_TEST_TMPDIR/o.pkg" \
        --openssh-pkg "$BATS_TEST_TMPDIR/o-System-Replace.pkg" \
        --out "$BATS_TEST_TMPDIR/fb.pkg"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/fb.pkg" ]
    run python3 "$REPO/image/payload/mkflatpkg.py" --cat-script \
        "$BATS_TEST_TMPDIR/fb.pkg" ./postinstall
    [[ "$output" == *"$(cut -d' ' -f2 < "$BATS_TEST_TMPDIR/ed.pub")"* ]]
}

@test "an Ed25519 key is still refused for a --no-openssh stock image" {
    # The refusal is not deleted, it is SCOPED: an image built without the
    # family's OpenSSH really is running 6.2, and silently authorizing a
    # key it cannot parse is the 20-minute failure above, restored.
    ssh-keygen -q -t ed25519 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/ed" </dev/null
    run "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/ed.pub" \
        --out "$BATS_TEST_TMPDIR/fb.pkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"6.2"* ]]
    [[ "$output" == *"6.5"* ]]
    [[ "$output" == *"--openssh"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/fb.pkg" ]
}

@test "an RSA key is accepted" {
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/r" </dev/null
    run "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/r.pub" \
        --out "$BATS_TEST_TMPDIR/fb.pkg"
    [ "$status" -eq 0 ]
    run python3 "$REPO/image/payload/mkflatpkg.py" --cat-script \
        "$BATS_TEST_TMPDIR/fb.pkg" ./postinstall
    [[ "$output" == *"$(cut -d' ' -f2 < "$BATS_TEST_TMPDIR/r.pub")"* ]]
}
