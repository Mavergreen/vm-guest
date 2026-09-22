#!/usr/bin/env bats
#
# Apple's post-10.9.5 updates: the pins, the selections, and the two things
# that must stay true whatever else changes.
#
#   1. NOTHING here ever runs `softwareupdate`. It would reach Apple's
#      servers during the build, make the build non-reproducible and
#      network-dependent, and a 2013 OS talking to 2026 servers may hang.
#   2. `--updates none` is P5's performance baseline. Every measurement
#      compares against it, so adding a second value to this switch must
#      not have perturbed it -- not the media geometry, not the conf file
#      the guest reads, not the stage stamps that decide what reruns.
#
# docs/open-questions.md Q1 and docs/decisions/0011.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    FETCH="$REPO/image/fetch-updates.sh"
    BUILD="$REPO/image/build-image.sh"
    PAYLOAD="$REPO/image/payload/build-firstboot-pkg.sh"
    MEDIA="$REPO/media/build-installer-img.sh"
    TSV="$REPO/vendor/sources.tsv"
}

# --- the rule that has no exceptions ---------------------------------------

@test "nothing anywhere asks softwareupdate to list, download or install" {
    # The whole tree, not just the files that would obviously be tempted:
    # the point is that there is no corner of this project where fetching
    # an update from Apple at build time is allowed.
    #
    # There IS one legitimate invocation. firstboot.sh runs
    # `softwareupdate --schedule off` in the guest, which is the opposite
    # act -- it stops the installed system phoning home on a timer. So this
    # forbids the verbs, not the word.
    run bash -c "grep -rn --include='*.sh' --include='postinstall' \
        -E 'softwareupdate +(-[ildar]|--install|--list|--download|--all)' \
        '$REPO/image' '$REPO/media' '$REPO/boot' '$REPO/bin' '$REPO/lib' \
        '$REPO/vm' || true"
    [ -z "$output" ]
}

# --- the pins ---------------------------------------------------------------

@test "every update package is pinned in vendor/sources.tsv with a real checksum" {
    run "$FETCH" --names --updates all
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    while read -r name; do
        [ -n "$name" ] || continue
        line=$(awk -F'\t' -v n="$name" '$0 !~ /^#/ && $1 == n' "$TSV")
        [ -n "$line" ] || { echo "not in the registry: $name"; return 1; }
        sha=$(printf '%s' "$line" | cut -f3)
        [ "$sha" != TOFU ] || { echo "$name is still TOFU"; return 1; }
        [ "${#sha}" -eq 64 ] || { echo "$name has no sha256: $sha"; return 1; }
        url=$(printf '%s' "$line" | cut -f2)
        # Apple's own CDN, and nowhere else. These are never republished.
        [[ "$url" == http://swcdn.apple.com/* ]] \
            || { echo "$name does not come from Apple: $url"; return 1; }
    done <<< "$output"
}

@test "the selections nest: none is empty, security is one, all contains security" {
    run "$FETCH" --names --updates none
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run "$FETCH" --names --updates security
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    security=$output

    run "$FETCH" --names --updates all
    [ "$status" -eq 0 ]
    [[ "$output" == *"$security"* ]]
    # ...and security comes first, because 2016-004 must be on before the
    # applications and before the family's OpenSSH.
    [ "$(printf '%s\n' "$output" | head -1)" = "$security" ]
}

@test "an unknown selection is refused by name" {
    run "$FETCH" --names --updates nonsense
    [ "$status" -ne 0 ]
    [[ "$output" == *"none security all"* ]]
}

@test "--describe and --names touch nothing and need no network" {
    tmp=$(mktemp -d)
    run "$FETCH" --describe --updates all --out "$tmp"
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$tmp")" ]
    rm -rf "$tmp"
}

# --- the switch -------------------------------------------------------------

@test "security is the default and none is still reachable" {
    run "$BUILD" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"--updates           security"* ]]
    run "$BUILD" --updates none --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"--updates           none"* ]]
}

@test "an unlisted --updates value is refused, not warned about" {
    run "$BUILD" --updates nonsense --describe
    [ "$status" -ne 0 ]
}

@test "the manifest records which updates the image carries" {
    run "$BUILD" --manifest-fields
    [ "$status" -eq 0 ]
    [[ "$output" == *"updates"* ]]
}

# --- the baseline must not have moved ---------------------------------------

@test "--updates none adds nothing to any stage's input stamp" {
    # The stamp decides what reruns. If `none` contributed a line, every
    # image built before this switch grew a second value would reinstall
    # itself for a feature it does not use.
    run bash -c "grep -n 'updates_stamp' '$BUILD'"
    [ "$status" -eq 0 ]
    run bash -c "sed -n '/^updates_stamp() {/,/^}/p' '$BUILD'"
    [[ "$output" == *'[ "$updates" != none ] || return 0'* ]]
}

@test "--updates security and all DO reach the stamp, and differ from each other" {
    # Same machinery as --smbios (task #36). Three selections, three
    # different stamps, or changing the switch ships the previous image.
    none=$("$FETCH" --names --updates none | wc -l)
    sec=$("$FETCH" --names --updates security | wc -l)
    all=$("$FETCH" --names --updates all | wc -l)
    [ "$none" -lt "$sec" ]
    [ "$sec" -lt "$all" ]
}

@test "the media's partition geometry is unchanged when nothing extra is carried" {
    # 6759 MiB is what every media built before --extra-space-mib existed
    # is, measured off the GPT of the one on disk. The default must
    # reproduce it exactly.
    run bash -c "'$MEDIA' --describe | grep 'partition 1 size'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"7087325184 bytes"* ]]
}

@test "the media grows by exactly what it is asked for" {
    run bash -c "'$MEDIA' --describe --extra-space-mib 100 | grep 'partition 1 size'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(( (6759 + 100) * 1048576 )) bytes"* ]]
}

@test "--extra-space-mib refuses a value that is not a number of MiB" {
    run "$MEDIA" --describe --extra-space-mib 12MB
    [ "$status" -ne 0 ]
}

# The generated postinstall, out of a built package. `strings` will not do:
# the Scripts archive is a gzipped cpio inside a xar, so a test that grepped
# the .pkg for a conf line would pass by never finding anything -- including
# when it is there. python3 is already a build-host requirement.
pkg_postinstall() {
    python3 - "$1" <<'PYEOF'
import bz2, struct, sys, zlib, xml.etree.ElementTree as ET
f = open(sys.argv[1], 'rb')
_, size, _, toc_c, _, _ = struct.unpack('>IHHQQI', f.read(28))
f.seek(size)
toc = zlib.decompress(f.read(toc_c))
heap = size + toc_c
for fe in ET.fromstring(toc).iter('file'):
    d = fe.find('data')
    if d is None or fe.findtext('name') != 'Scripts':
        continue
    f.seek(heap + int(d.findtext('offset')))
    raw = f.read(int(d.findtext('length')))
    # By magic, not by the declared encoding style: mkflatpkg.py writes
    # this member as application/octet-stream and gzips it anyway, and a
    # reader that trusted the label would hand back 11 KB of compressed
    # bytes and a test that passes by finding nothing.
    if raw[:2] == b'\x1f\x8b':
        raw = zlib.decompress(raw, 47)
    elif raw[:3] == b'BZh':
        raw = bz2.decompress(raw)
    # The Scripts member is a cpio archive: ASCII headers, NUL padding.
    # Only the text is wanted, and a NUL would be dropped by the command
    # substitution that reads this anyway.
    sys.stdout.write(raw.replace(b'\x00', b'\n').decode('utf-8', 'replace'))
PYEOF
}

# --- the payload ------------------------------------------------------------

@test "a none payload's conf file says nothing about updates" {
    # Byte-identical to a conf built before this existed. firstboot.sh
    # defaults MQG_FB_UPDATES to none for exactly this reason.
    tmp=$(mktemp -d)
    key=$tmp/k.pub
    printf 'ssh-rsa AAAAtest test@example\n' > "$key"
    run "$PAYLOAD" --ssh-key "$key" --updates none --out "$tmp/p.pkg"
    [ "$status" -eq 0 ]
    run pkg_postinstall "$tmp/p.pkg"
    [ "$status" -eq 0 ]
    # The generated conf is the block after the "Do not edit" banner. The
    # repository's own firstboot.sh mentions both names in its defaults, so
    # the assertion has to be about what was GENERATED, not about the file.
    conf=$(printf '%s\n' "$output" \
        | sed -n '/Generated by image.payload.build-firstboot-pkg.sh/,$p' \
        | grep '^MQG_FB_')
    [ -n "$conf" ]
    [[ "$conf" != *"MQG_FB_UPDATE_PKGS="* ]]
    [[ "$conf" != *"MQG_FB_UPDATES="* ]]
    [[ "$conf" == *"MQG_FB_USER="* ]]
    rm -rf "$tmp"
}

@test "the payload refuses to carry packages it does not admit to, and vice versa" {
    tmp=$(mktemp -d)
    key=$tmp/k.pub
    printf 'ssh-rsa AAAAtest test@example\n' > "$key"
    printf 'xar!not really a package\n' > "$tmp/u.pkg"

    # Packages with --updates none: the manifest would lie.
    run "$PAYLOAD" --ssh-key "$key" --updates none \
        --update-pkg "$tmp/u.pkg" --out "$tmp/p.pkg"
    [ "$status" -ne 0 ]

    # A selection with no packages: fetch-updates.sh failed silently.
    run "$PAYLOAD" --ssh-key "$key" --updates security --out "$tmp/p.pkg"
    [ "$status" -ne 0 ]

    rm -rf "$tmp"
}

@test "the payload records the update packages in install order" {
    tmp=$(mktemp -d)
    key=$tmp/k.pub
    printf 'ssh-rsa AAAAtest test@example\n' > "$key"
    printf 'xar!one\n' > "$tmp/mqg-update-01-a.pkg"
    printf 'xar!two\n' > "$tmp/mqg-update-02-b.pkg"
    run "$PAYLOAD" --ssh-key "$key" --updates all \
        --update-pkg "$tmp/mqg-update-01-a.pkg" \
        --update-pkg "$tmp/mqg-update-02-b.pkg" \
        --out "$tmp/p.pkg"
    [ "$status" -eq 0 ]
    run bash -c "'$BATS_TEST_DIRNAME'/../image/payload/build-firstboot-pkg.sh --help >/dev/null; true"
    run pkg_postinstall "$tmp/p.pkg"
    [ "$status" -eq 0 ]
    line=$(printf '%s\n' "$output" \
        | grep '^MQG_FB_UPDATE_PKGS=' | tail -1)
    rm -rf "$tmp"
    [ -n "$line" ]
    [[ "$line" == *"mqg-update-01-a.pkg"*"mqg-update-02-b.pkg"* ]]
}

# --- the guest side ---------------------------------------------------------

@test "firstboot.sh installs the updates BEFORE the family's OpenSSH" {
    # Security Update 2016-004's payload contains ./usr/bin/ssh and
    # ./usr/sbin/sshd. Installed after the OpenSSH System-Replace package
    # it would overwrite the symlinks that package leaves at those paths.
    fb="$REPO/image/payload/firstboot.sh"
    upd=$(grep -n 'CONF_DIR/updates/\$_u' "$fb" | head -1 | cut -d: -f1)
    ssh=$(grep -n 'installer -verbose -pkg "\$fb_base"' "$fb" | head -1 | cut -d: -f1)
    [ -n "$upd" ] && [ -n "$ssh" ]
    [ "$upd" -lt "$ssh" ]
}

@test "the update packages land in their own directory, not among the OpenSSH ones" {
    # firstboot.sh finds the OpenSSH pair by globbing pkgs/*.pkg and
    # classifying by name. An update package in that directory would be
    # handed to installer as "the base OpenSSH package".
    run grep -n 'CONF_DIR/updates' "$REPO/image/payload/postinstall"
    [ "$status" -eq 0 ]
    run grep -c 'carry_pkgs "$CONF_DIR/pkgs"' "$REPO/image/payload/postinstall"
    [ "$output" = "1" ]
}

@test "firstboot.sh records a receipt and a build number, not an installer exit code" {
    # sw_vers still says 10.9.5 after 2016-004, and a zero exit from
    # installer is not evidence of anything. The two witnesses that do move
    # are pkgutil's receipt list and ProductBuildVersion.
    fb="$REPO/image/payload/firstboot.sh"
    run grep -c 'pkgutil --pkgs' "$fb"
    [ "$output" -ge 1 ]
    run grep -c 'sw_vers -buildVersion' "$fb"
    [ "$output" -ge 2 ]
}
