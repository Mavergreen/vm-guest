#!/usr/bin/env bats
#
# The guest's own OpenSSH: the pin, the fetch, and the wiring that carries
# it to the guest.
#
# The tests that matter most here are the two that encode a mistake the
# family has already made once. The pin lives in a FILE so Renovate can
# move it, and the asset names are READ from the release's SHA256SUMS
# rather than built from a hardcoded prefix -- golang's cross package was
# renamed go126- -> golang- mid-line and every consumer that constructed
# its URL started 404ing across the bump.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PIN="$REPO/components/openssh/version"
    TAG="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PIN" | grep -v '^$' | head -1)"
}

# Build a fake release directory that curl can fetch over file://.
#   make_release <base-dir> <base-pkg-name> <replace-pkg-name>
make_release() {
    local dir=$1 base=$2 replace=$3 rel
    rel="$dir/$TAG"
    mkdir -p "$rel"
    printf 'xar!not really a package, but it starts right\n' > "$rel/$base"
    printf 'xar!nor is this one\n' > "$rel/$replace"
    (
        cd "$rel" || exit 1
        sha256sum "$base" "$replace" > SHA256SUMS
        printf '%s  appcast.xml\n' \
            0000000000000000000000000000000000000000000000000000000000000000 \
            >> SHA256SUMS
    )
}

fetch() {
    MQG_OPENSSH_BASE_URL="file://$1" \
        "$REPO/image/fetch-openssh.sh" --out "$2"
}

@test "the OpenSSH version is pinned in a file, not in a workflow" {
    [ -f "$PIN" ]
    # A release tag of ModernMavericks/openssh: <upstream>-mavericks.N.
    # Renovate's manager captures exactly this shape (see renovate.json),
    # and the family gate requires a versioning that preserves the N --
    # default versioning coerces it away, every repackage then compares
    # equal, and the pin silently never moves again.
    [[ "$TAG" =~ ^[0-9]+\.[0-9]+p[0-9]+-mavericks\.[0-9]+$ ]]
}

@test "renovate tracks the OpenSSH pin with a versioning that keeps -mavericks.N" {
    run grep -c 'components/openssh/version' "$REPO/.github/renovate.json"
    [ "$status" -eq 0 ]
    [ "$output" -gt 0 ]
    run grep -c 'mavericks' "$REPO/.github/renovate.json"
    [ "$output" -gt 0 ]
    run python3 -c "
import json, sys
cfg = json.load(open('$REPO/.github/renovate.json'))
mgrs = [m for m in cfg['customManagers']
        if any('components/openssh' in p for p in m['managerFilePatterns'])]
assert len(mgrs) == 1, mgrs
m = mgrs[0]
assert m['datasourceTemplate'] == 'github-releases', m
assert m['depNameTemplate'] == 'ModernMavericks/openssh', m
# The gate: a manager whose pin ends in -mavericks.N needs a regex:
# versioning that captures N, or the pin never moves.
assert m['versioningTemplate'].startswith('regex:'), m
assert 'mavericks' in m['versioningTemplate'], m
print('ok')
"
    [ "$status" -eq 0 ]
}

@test "--describe names the pinned release and touches nothing" {
    run "$REPO/image/fetch-openssh.sh" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"$TAG"* ]]
    [[ "$output" == *"components/openssh/version"* ]]
}

@test "the packages are fetched by the names SHA256SUMS gives and verified" {
    make_release "$BATS_TEST_TMPDIR/rel" \
        "OpenSSH-$TAG.pkg" "OpenSSH-System-Replace-$TAG.pkg"
    run fetch "$BATS_TEST_TMPDIR/rel" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ]
    # Base package first, replacement second: the order they must be
    # installed in, because the replacement symlinks the system paths at
    # files the base package lays down.
    [ "${lines[-2]}" = "$BATS_TEST_TMPDIR/out/OpenSSH-$TAG.pkg" ]
    [ "${lines[-1]}" = "$BATS_TEST_TMPDIR/out/OpenSSH-System-Replace-$TAG.pkg" ]
}

@test "a renamed asset prefix does not break the fetch" {
    # The golang incident, as a test. Every name here has moved, and
    # nothing about the release says "OpenSSH-" any more. A fetcher that
    # built its URL from a prefix would 404; one that reads SHA256SUMS
    # does not notice.
    make_release "$BATS_TEST_TMPDIR/rel" \
        "ssh10-$TAG.pkg" "ssh10-System-Replace-$TAG.pkg"
    run fetch "$BATS_TEST_TMPDIR/rel" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ]
    [[ "${lines[-2]}" == *"/ssh10-$TAG.pkg" ]]
    [[ "${lines[-1]}" == *"/ssh10-System-Replace-$TAG.pkg" ]]
}

@test "a package whose bytes do not match SHA256SUMS is refused" {
    make_release "$BATS_TEST_TMPDIR/rel" \
        "OpenSSH-$TAG.pkg" "OpenSSH-System-Replace-$TAG.pkg"
    printf 'xar!tampered\n' > "$BATS_TEST_TMPDIR/rel/$TAG/OpenSSH-$TAG.pkg"
    run fetch "$BATS_TEST_TMPDIR/rel" "$BATS_TEST_TMPDIR/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
}

@test "a release naming no replacement package is refused, not half-used" {
    mkdir -p "$BATS_TEST_TMPDIR/rel/$TAG"
    printf 'xar!only one\n' > "$BATS_TEST_TMPDIR/rel/$TAG/OpenSSH-$TAG.pkg"
    ( cd "$BATS_TEST_TMPDIR/rel/$TAG" && sha256sum "OpenSSH-$TAG.pkg" > SHA256SUMS )
    run fetch "$BATS_TEST_TMPDIR/rel" "$BATS_TEST_TMPDIR/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"System-Replace"* ]]
}

@test "a missing release fails with a message naming the tag" {
    run fetch "$BATS_TEST_TMPDIR/nothing-here" "$BATS_TEST_TMPDIR/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$TAG"* ]]
}

# --- what reaches the guest ------------------------------------------------

@test "the payload records the OpenSSH tag and package names for the guest" {
    make_release "$BATS_TEST_TMPDIR/rel" \
        "OpenSSH-$TAG.pkg" "OpenSSH-System-Replace-$TAG.pkg"
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/r" </dev/null
    run "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/r.pub" \
        --openssh-tag "$TAG" \
        --openssh-pkg "$BATS_TEST_TMPDIR/rel/$TAG/OpenSSH-$TAG.pkg" \
        --openssh-pkg "$BATS_TEST_TMPDIR/rel/$TAG/OpenSSH-System-Replace-$TAG.pkg" \
        --out "$BATS_TEST_TMPDIR/fb.pkg"
    [ "$status" -eq 0 ]
    run python3 "$REPO/image/payload/mkflatpkg.py" --cat-script \
        "$BATS_TEST_TMPDIR/fb.pkg" ./postinstall
    [[ "$output" == *"MQG_FB_OPENSSH=1"* ]]
    [[ "$output" == *"$TAG"* ]]
    [[ "$output" == *"OpenSSH-System-Replace-$TAG.pkg"* ]]
}

@test "packages are NAMED in the payload, never carried inside it" {
    # The payload is a payload-free package -- PackageInfo and Scripts, no
    # Bom, no Payload -- which is the only flat-package shape this project
    # can build on Linux. Twelve megabytes of product archive base64'd into
    # a shell script is not that shape, and would make the one file the
    # installer extracts enormous. They travel on the media instead.
    make_release "$BATS_TEST_TMPDIR/rel" \
        "OpenSSH-$TAG.pkg" "OpenSSH-System-Replace-$TAG.pkg"
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/r" </dev/null
    "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/r.pub" \
        --openssh-tag "$TAG" \
        --openssh-pkg "$BATS_TEST_TMPDIR/rel/$TAG/OpenSSH-$TAG.pkg" \
        --openssh-pkg "$BATS_TEST_TMPDIR/rel/$TAG/OpenSSH-System-Replace-$TAG.pkg" \
        --out "$BATS_TEST_TMPDIR/fb.pkg" >/dev/null
    [ "$(stat -c %s "$BATS_TEST_TMPDIR/fb.pkg")" -lt 200000 ]
}

@test "--openssh-pkg without --openssh-tag is refused" {
    # An image that cannot say which OpenSSH it has is an image whose
    # manifest lies by omission.
    make_release "$BATS_TEST_TMPDIR/rel" \
        "OpenSSH-$TAG.pkg" "OpenSSH-System-Replace-$TAG.pkg"
    ssh-keygen -q -t rsa -b 2048 -N '' -C mqg-test \
        -f "$BATS_TEST_TMPDIR/r" </dev/null
    run "$REPO/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$BATS_TEST_TMPDIR/r.pub" \
        --openssh-pkg "$BATS_TEST_TMPDIR/rel/$TAG/OpenSSH-$TAG.pkg" \
        --out "$BATS_TEST_TMPDIR/fb.pkg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--openssh-tag"* ]]
}

@test "extra packages are carried on the media but NOT in OSInstall.collection" {
    # A package in the collection is installed by the OS installer itself,
    # which is proven only for our own payload-free script package. The
    # OpenSSH packages are product archives whose Distribution declares
    # <allowed-os-versions min="10.9.5"/>; they are installed from
    # firstboot.sh on the booted system instead.
    run grep -n 'inject_extra_pkgs' "$REPO/media/build-installer-img.sh"
    [ "$status" -eq 0 ]
    # The function that edits the collection is a different one, and the
    # extra-package path must not touch the collection file.
    run bash -c "sed -n '/^inject_extra_pkgs()/,/^}/p' '$REPO/media/build-installer-img.sh' | grep -c 'OSInstall.collection'"
    [ "$output" = "0" ]
}

@test "firstboot installs the base package before the replacement" {
    run bash -c "grep -n 'installer -verbose -pkg' '$REPO/image/payload/firstboot.sh'"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *'"$fb_base"'* ]]
    [[ "${lines[1]}" == *'"$fb_replace"'* ]]
}

@test "firstboot writes the sshd-keygen-wrapper the replacement package lacks" {
    # 10.9's ssh.plist names /usr/libexec/sshd-keygen-wrapper as its
    # Program. The replacement package symlinks that path into /usr/local
    # but ships no such file there, so without this the symlink dangles,
    # launchd cannot exec it, and the guest has no sshd at all.
    run grep -c 'write_sshd_keygen_wrapper' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 2 ]
    # And it is written BEFORE the replacement package runs, so the
    # symlink lands on a real file rather than being repaired afterwards.
    run bash -c "grep -n 'write_sshd_keygen_wrapper$\|installer -verbose -pkg \"\$fb_replace\"' '$REPO/image/payload/firstboot.sh' | tail -2"
    [[ "${lines[0]}" == *"write_sshd_keygen_wrapper"* ]]
    [[ "${lines[1]}" == *'$fb_replace'* ]]
}

@test "firstboot generates a modern host key set, not just Apple's three" {
    # Apple's wrapper only ever makes rsa1/rsa/dsa in /etc. A 2026 client
    # refuses every one of those, which was the second defect P4 found.
    run grep -c 'ed25519' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
    run bash -c "grep -c 'ssh_host_\${_t}_key' '$REPO/image/payload/firstboot.sh'"
    [ "$output" -ge 2 ]
}

@test "a broken OpenSSH replacement rolls back instead of stranding the guest" {
    # The one failure mode that cannot be debugged after the fact: a guest
    # whose only interface is SSH, with no working sshd. The replacement
    # package's preinstall backs the vanilla binaries up before it touches
    # anything, so the rollback is a copy.
    run grep -c 'restore_vanilla_openssh' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 2 ]
    run grep -c '/var/backups/vanilla-openssh' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
}

@test "the build records which OpenSSH an image got" {
    run "$REPO/image/build-image.sh" --manifest-fields
    [ "$status" -eq 0 ]
    [[ "$output" == *"openssh"* ]]
}

@test "--no-openssh is still a buildable image, and says so" {
    run "$REPO/image/build-image.sh" --no-openssh --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"none (stock OpenSSH 6.2)"* ]]
}

@test "the default image carries the family's OpenSSH" {
    run "$REPO/image/build-image.sh" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"openssh"*"$TAG"* ]]
}

@test "the install stage waits for the first boot to finish, not just for sshd" {
    # firstboot.sh turns Remote Login on part-way through; the hostname,
    # auto-login and the .done marker all come after it. That window used
    # to be masked by Apple's sshd-keygen-wrapper generating three host
    # keys on the first connection. The guest's own OpenSSH makes the first
    # connection instant, so the race became visible -- and real.
    run grep -c 'wait_for_firstboot' "$REPO/image/build-image.sh"
    [ "$output" -ge 2 ]
    run bash -c "sed -n '/^wait_for_firstboot()/,/^}/p' '$REPO/image/build-image.sh'"
    [[ "$output" == *".mqg-firstboot/.done"* ]]
    # Non-fatal: an image whose payload never finishes is for the verify
    # stage to report with the log in hand, not something to hang on.
    [[ "$output" == *"return 0"* ]]
}

@test "the legacy ssh-rsa options are used only for a stock image" {
    # The workaround is not kept beside its fix: the default path connects
    # with no algorithm overrides at all. --no-openssh really is running
    # OpenSSH 6.2, so that path still needs them.
    run bash -c "sed -n '/^ssh_opts()/,/^}/p' '$REPO/image/build-image.sh'"
    [[ "$output" == *"HostKeyAlgorithms"* ]]
    run bash -c "sed -n '/^ssh_opts()/,/^}/p' '$REPO/image/build-image.sh' | grep -n 'HostKeyAlgorithms\|openssh. -eq 0'"
    # The guard comes first; every legacy option is inside it.
    [[ "${lines[0]}" == *"-eq 0"* ]]
}
