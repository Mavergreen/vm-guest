#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # A PATH containing only our stubs, so a missing stub really is missing
    # rather than falling through to the real tool elsewhere on this host.
    # prereqs.sh itself is `#!/usr/bin/env bash` (env needs to find bash in
    # that same restricted PATH) and uses external `dirname` to locate its
    # own repo root before it ever gets to checking REQUIRED. Symlink just
    # those two in, rather than widening the PATH to their real directory
    # (/usr/bin), which would also expose every real tool living next to
    # them -- nasm, gcc, iasl, ... -- and defeat the "missing tool" tests.
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    ln -s "$(command -v bash)" "$STUB_BIN/bash"
    ln -s "$(command -v dirname)" "$STUB_BIN/dirname"
}

@test "prereqs.sh reports success when everything it needs is present" {
    # The stub list is DERIVED from prereqs.sh's own table, not typed out
    # beside it. Hand-copying it here is how the lists drifted in the
    # first place -- twice, and the second time a third list nobody was
    # reading stopped a build on another machine.
    for t in $(sed -n 's/^\([a-z0-9._-]*\)|.*/\1/p' "$REPO/boot/prereqs.sh"); do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    run env PATH="$STUB_BIN" "$REPO/boot/prereqs.sh"
    [ "$status" -eq 0 ]
}

@test "prereqs.sh names every missing tool, not just the first" {
    for t in gcc make git python3 mtools sgdisk mcopy mformat; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    run env PATH="$STUB_BIN" "$REPO/boot/prereqs.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nasm"* ]]
    [[ "$output" == *"iasl"* ]]
}

@test "prereqs.sh names the packages to install, not just the binaries" {
    for t in gcc make git python3 mtools sgdisk mcopy mformat \
             dmg2img kpartx mkfs.hfsplus; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    run env PATH="$STUB_BIN" MQG_PKG_MANAGER=apt "$REPO/boot/prereqs.sh"
    [[ "$output" == *"acpica-tools"* ]]
}

@test "prereqs.sh names Arch packages on an Arch host, not Debian ones" {
    # Confirmed on squirrel-zapper 2026-09-20: the Debian name for iasl is
    # acpica-tools and the Arch name is acpica, and sgdisk comes from gdisk
    # on Debian and gptfdisk on Arch. Printing an apt line on an Arch host
    # is not merely unhelpful, it is wrong advice.
    for t in gcc make git python3 mtools mcopy mformat \
             dmg2img kpartx mkfs.hfsplus; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    run env PATH="$STUB_BIN" MQG_PKG_MANAGER=pacman "$REPO/boot/prereqs.sh"
    [[ "$output" == *"acpica"* ]]
    [[ "$output" == *"gptfdisk"* ]]
    [[ "$output" != *"acpica-tools"* ]]
    [[ "$output" == *"pacman"* ]]
    [[ "$output" != *"apt install"* ]]
}

@test "prereqs.sh admits when it has no package name for a platform" {
    # An unconfirmed name is printed as unknown rather than guessed. A
    # guess that is wrong costs more than a blank, because the reader
    # cannot tell which one they are looking at.
    for t in gcc make git python3 mtools sgdisk mcopy mformat \
             dmg2img kpartx mkfs.hfsplus; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    run env PATH="$STUB_BIN" MQG_PKG_MANAGER=nonesuch "$REPO/boot/prereqs.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no package name confirmed"* ]]
    [[ "$output" != *"install"*"acpica"* ]]
}

@test "prereqs.sh does not attempt to install anything" {
    # A stub apt-get that fails loudly if called at all.
    for t in gcc make git python3 nasm iasl mtools sgdisk mcopy mformat; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$t"
        chmod +x "$STUB_BIN/$t"
    done
    printf '#!/bin/sh\necho CALLED-APT >&2\nexit 42\n' > "$STUB_BIN/apt-get"
    printf '#!/bin/sh\necho CALLED-SUDO >&2\nexit 42\n' > "$STUB_BIN/sudo"
    chmod +x "$STUB_BIN/apt-get" "$STUB_BIN/sudo"
    run env PATH="$STUB_BIN" "$REPO/boot/prereqs.sh"
    [[ "$output" != *"CALLED-APT"* ]]
    [[ "$output" != *"CALLED-SUDO"* ]]
}

@test "fetch-opencorepkg.sh refuses an unpinned checksum" {
    # The name here must match what fetch-opencorepkg.sh looks up
    # (opencorepkg-src, per vendor/sources.tsv) -- a mismatched name would
    # die with "no such source" instead, which is a different failure than
    # the one this test means to exercise.
    printf '%s\n' \
        '# name	url	sha256' \
        'opencorepkg-src	https://example.invalid/oc.tar.gz	TOFU' \
        > "$BATS_TEST_TMPDIR/sources.tsv"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        MQG_REQUIRE_PINNED=1 \
        "$REPO/boot/fetch-opencorepkg.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not pinned"* ]]
}

@test "fetch-opencorepkg.sh reports the tag it is pinned to" {
    run "$REPO/boot/fetch-opencorepkg.sh" --show-version
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0.7"* ]]
}

@test "build-opencore.sh fails clearly when the source tree is absent" {
    run env MQG_BUILD_DIR="$BATS_TEST_TMPDIR/nonexistent" \
        "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"source tree"* ]]
}

@test "build-opencore.sh lists the artifacts it intends to produce" {
    run "$REPO/boot/build-opencore.sh" --list-artifacts
    [ "$status" -eq 0 ]
    [[ "$output" == *"OpenCore.efi"* ]]
    [[ "$output" == *"BOOTx64.efi"* ]]
    [[ "$output" == *"OpenHfsPlus.efi"* ]]
    [[ "$output" == *"OpenRuntime.efi"* ]]
}

# --- pinned, offline OpenCore build -----------------------------------
#
# build_oc.tool's last act used to be
#   src=$(curl -LfsS https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh) && eval "$src"
# and the script that came back cloned acidanthera/audk at master. Two of
# three build inputs floated and fetched shell ran at build time. These
# tests are the guard rail on the fix.

@test "build-opencore.sh pins every EDK II input to a commit, not a branch" {
    run "$REPO/boot/build-opencore.sh" --show-pins
    [ "$status" -eq 0 ]
    # ocbuild, for efibuild.sh...
    [[ "$output" == *"ocbuild-efibuild"$'\t'"e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a"* ]]
    # ...and acidanthera/audk, the EDK II base.
    [[ "$output" == *"audk-src"$'\t'"0672a009e9ca85753d240324d761341adf0291b3"* ]]
    # No pin may be a branch name: every one is a full 40-hex commit.
    local lines=0
    while IFS=$'\t' read -r name commit; do
        [ -n "$name" ]
        [[ "$commit" =~ ^[0-9a-f]{40}$ ]]
        lines=$(( lines + 1 ))
    done <<< "$output"
    [ "$lines" -ge 2 ]
}

@test "every input build-opencore.sh pins has a real checksum in sources.tsv" {
    run "$REPO/boot/build-opencore.sh" --show-pins
    [ "$status" -eq 0 ]
    while IFS=$'\t' read -r name _commit; do
        sha=$(awk -F'\t' -v n="$name" \
            '$0 !~ /^#/ && $1 == n { print $3; exit }' "$REPO/vendor/sources.tsv")
        # A name with no row at all is as broken as an unpinned one.
        [ -n "$sha" ]
        [ "$sha" != "TOFU" ]
        [[ "$sha" =~ ^[0-9a-f]{64}$ ]]
    done <<< "$output"
}

@test "sources.tsv points every pinned input at its pinned commit" {
    run "$REPO/boot/build-opencore.sh" --show-pins
    [ "$status" -eq 0 ]
    while IFS=$'\t' read -r name commit; do
        url=$(awk -F'\t' -v n="$name" \
            '$0 !~ /^#/ && $1 == n { print $2; exit }' "$REPO/vendor/sources.tsv")
        [[ "$url" == *"$commit"* ]]
    done <<< "$output"
}

@test "nothing in the build path fetches from a mutable branch" {
    # The regression guard. Shell scripts are checked whole; patches are
    # checked on their added lines only, since a *removed* line naming
    # ocbuild's master branch is precisely the fix.
    hits=$(
        {
            find "$REPO/boot" "$REPO/lib" "$REPO/bin" -name '*.sh' -print0 \
                | xargs -0 grep -HnE \
                    'raw\.githubusercontent\.com/[^/]+/[^/]+/(master|main)/' || true
            for p in "$REPO"/boot/patches/*.patch; do
                [ -e "$p" ] || continue
                grep -n '^+' "$p" \
                    | grep -E 'raw\.githubusercontent\.com/[^/]+/[^/]+/(master|main)/' \
                    | sed "s|^|$p:|" || true
            done
        }
    )
    [ -z "$hits" ]
}

@test "build-opencore.sh refuses a source whose URL names a different commit" {
    mkdir -p "$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7"
    printf '%s\n' \
        '# name	url	sha256' \
        'ocbuild-efibuild	https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh	'"$(printf '%064d' 0)" \
        > "$BATS_TEST_TMPDIR/sources.tsv"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not name commit"* ]]
}

@test "build-opencore.sh refuses an unpinned checksum" {
    mkdir -p "$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7"
    printf '%s\n' \
        '# name	url	sha256' \
        'ocbuild-efibuild	https://raw.githubusercontent.com/acidanthera/ocbuild/e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a/efibuild.sh	TOFU' \
        > "$BATS_TEST_TMPDIR/sources.tsv"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not pinned"* ]]
}

@test "build-opencore.sh says which fetch script to run when an input is absent" {
    mkdir -p "$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7"
    run env MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-opencore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"fetch-edk2.sh"* ]]
}

@test "fetch-edk2.sh takes its list from the build script's pins" {
    run "$REPO/boot/fetch-edk2.sh" --list-sources
    [ "$status" -eq 0 ]
    run "$REPO/boot/build-opencore.sh" --show-pins
    pins=$(printf '%s\n' "$output" | cut -f1)
    run "$REPO/boot/fetch-edk2.sh" --list-sources
    [ "$output" = "$pins" ]
}

@test "fetch-edk2.sh refuses an unpinned checksum" {
    printf '%s\n' \
        '# name	url	sha256' \
        'ocbuild-efibuild	https://example.invalid/efibuild.sh	TOFU' \
        > "$BATS_TEST_TMPDIR/sources.tsv"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        MQG_REQUIRE_PINNED=1 \
        "$REPO/boot/fetch-edk2.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not pinned"* ]]
}

@test "the build_oc.tool patch removes the fetch and adds no new one" {
    p="$REPO/boot/patches/0001-build_oc-source-pinned-efibuild.patch"
    [ -f "$p" ]
    # The curl line goes away...
    grep -q '^-src=\$(curl .*ocbuild/master/efibuild.sh' "$p"
    # ...and what replaces it reads a local file.
    grep -q '^+src=\$(cat "\${EFIBUILD_SH}")' "$p"
}

# --- the C dialect, which used to be whatever the host felt like ------
#
# EDK II sets no -std, so before this the dialect was the host compiler's
# default. GCC 15 changed that default to gnu23, where `bool` is a keyword,
# and OpenCorePkg 1.0.7's vendored libDER does `typedef BOOLEAN bool;`.
# See the 2026-09-20 entry in NOTES.md and docs/host-profile.md G22.

@test "the OpenCore build states the C dialect it wants" {
    grep -q 'OC_STD=gnu17' "$REPO/boot/build-opencore.sh"
    # Through upstream's own hook, carried by efibuild.sh's BUILD_ARGUMENTS,
    # so build_oc.tool needs no patch for this.
    grep -q 'BUILD_ARGUMENTS="-D OCPKG_BUILD_OPTIONS=\$OC_BUILD_OPTIONS"' \
        "$REPO/boot/build-opencore.sh"
    grep -q 'OC_BUILD_OPTIONS=.*-std=%s' "$REPO/boot/build-opencore.sh"
}

# --- upstream's -Werror, which is upstream's discipline and not ours ---
#
# EDK II compiles with -Werror. We pin a commit of audk and a release of
# OpenCorePkg and cannot fix their warnings, so every diagnostic a newer
# compiler invents is a build failure in code we do not own: GCC 15's C23
# default (fixed properly by stating the dialect, above) and then GCC 16's
# -Werror=unused-but-set-variable= in MdeModulePkg, on squirrel-zapper.
# Firmware only -- our own shell and tests keep every gate they have.
# See the 2026-09-20 entries in NOTES.md and docs/decisions/0004.

@test "the OpenCore build stops treating upstream's warnings as errors" {
    grep -q '^OC_NO_WERROR=-Wno-error$' "$REPO/boot/build-opencore.sh"
}

@test "the two firmware flags travel as one tab-separated argument" {
    # efibuild.sh splits BUILD_ARGUMENTS with `IFS=', ' read -r -a`, i.e.
    # on spaces AND commas. A space here would arrive at `build` as two
    # arguments and quietly lose -Wno-error. Evaluate the real line rather
    # than describing it, so a reformat that ate the tab fails here.
    line=$(grep '^OC_BUILD_OPTIONS=' "$REPO/boot/build-opencore.sh")
    OC_STD=gnu17
    OC_NO_WERROR=-Wno-error
    eval "$line"
    [ "$OC_BUILD_OPTIONS" = "$(printf -- '-std=gnu17\t-Wno-error')" ]
    case "$OC_BUILD_OPTIONS" in *" "*) return 1 ;; esac
}

@test "the build asserts that both flags reached the compiler" {
    # A hook that silently stopped expanding would otherwise pass for
    # success -- the same reason the .dsc patches are asserted after.
    grep -q 'name GNUmakefile' "$REPO/boot/build-opencore.sh"
    grep -q 'for flag in "-std=\$OC_STD" "\$OC_NO_WERROR"' \
        "$REPO/boot/build-opencore.sh"
}

@test "the OVMF -Werror patch adds the flag and nothing else" {
    p="$REPO/boot/patches/0003-firmware-drop-werror.patch"
    [ -f "$p" ]
    grep -q '^+  GCC:\*_\*_\*_CC_FLAGS = -Wno-error' "$p"
    # It only ever adds, like 0002: a .dsc patch that removes a line is a
    # different and much larger claim.
    [ -z "$(grep -E '^-[^-]' "$p" || true)" ]
}

@test "build-ovmf.sh applies the -Werror patch and checks that it took" {
    grep -q '0003-firmware-drop-werror.patch' "$REPO/boot/build-ovmf.sh"
    # Guarded before, asserted after -- the build_oc.tool pattern.
    [ "$(grep -c "grep -q 'Wno-error'" "$REPO/boot/build-ovmf.sh")" -eq 2 ]
}

@test "the fix is the class, not the diagnostic of the day" {
    # -Wno-unused-but-set-variable would have fixed squirrel-zapper's GCC
    # 16 failure and taught nothing; GCC 17 will bring a third one. Nothing
    # under boot/ may name an individual warning.
    ! grep -rq -- '-Wno-error=' "$REPO/boot"
}

@test "dropping -Werror does not hide the warnings" {
    # The point is that upstream's warnings stop being fatal, not that they
    # stop existing. The patch adds exactly one compiler flag, and it is
    # -Wno-error -- not -w, not -Wno-<something>, nothing that would stop a
    # diagnostic being printed.
    p="$REPO/boot/patches/0003-firmware-drop-werror.patch"
    [ "$(grep -c '^+.*CC_FLAGS' "$p")" -eq 1 ]
    grep -q '^+  GCC:\*_\*_\*_CC_FLAGS = -Wno-error' "$p"
    # And the compiler's output still lands in a log the failure path names.
    grep -q 'ovmf-build.log' "$REPO/boot/build-ovmf.sh"
}

@test "our own shell and tests keep every gate they have" {
    # Scope: the -Werror change is for upstream C we did not write. If
    # anyone reaches for the same argument to quiet shellcheck, tier-check
    # or the bash 3.2 check, this is where it stops.
    grep -q 'shellcheck' "$REPO/bin/run-tests.sh"
    grep -q 'tier-check.sh" --strict' "$REPO/bin/run-tests.sh"
    grep -q 'bash32-check.sh' "$REPO/bin/run-tests.sh"
}

@test "the OVMF dialect patch adds the flag and nothing else" {
    p="$REPO/boot/patches/0002-ovmf-pin-the-c-dialect.patch"
    [ -f "$p" ]
    grep -q '^+  GCC:\*_\*_\*_CC_FLAGS = -std=gnu17' "$p"
    # It only ever adds; a patch to a .dsc that removes a line is a
    # different and much larger claim.
    [ -z "$(grep -E '^-[^-]' "$p" || true)" ]
}

@test "build-ovmf.sh applies the dialect patch and checks that it took" {
    grep -q '0002-ovmf-pin-the-c-dialect.patch' "$REPO/boot/build-ovmf.sh"
    # Guarded before, asserted after -- the build_oc.tool pattern.
    [ "$(grep -c "grep -q 'std=gnu17'" "$REPO/boot/build-ovmf.sh")" -eq 2 ]
}

# --- the SMC kexts ----------------------------------------------------
#
# These are the only non-Tier-0 things in the assembled EFI image, and the
# image build consumes an exact layout -- Contents/Info.plist and
# Contents/MacOS/<name> -- so an archive that does not contain it has to
# fail here, naming the piece, rather than as an mcopy error two scripts
# later.

# Write a zip at $1 whose members are the remaining arguments, each an
# empty file at that path. Enough to exercise the layout checks without
# downloading 2 MB of real kexts.
_fake_zip() {
    local out=$1; shift
    python3 - "$out" "$@" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for name in sys.argv[2:]:
        z.writestr(name, b"")
PY
}

# A sources.tsv naming both kexts, so the script's own pinned-ness check
# (which runs over the whole list before fetching anything) gets a row for
# each rather than dying with "no such source".
_kext_sources() {
    printf '%s\n' \
        '# name	url	sha256' \
        "lilu-release	$1	TOFU" \
        "virtualsmc-release	$2	TOFU" \
        > "$BATS_TEST_TMPDIR/sources.tsv"
}

@test "fetch-kexts.sh unpacks each kext with its binary" {
    run "$REPO/boot/fetch-kexts.sh" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Lilu"* ]]
    [[ "$output" == *"VirtualSMC"* ]]
}

@test "fetch-kexts.sh refuses an unpinned checksum" {
    _kext_sources "https://example.invalid/Lilu.zip" \
                  "https://example.invalid/VirtualSMC.zip"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        MQG_REQUIRE_PINNED=1 \
        "$REPO/boot/fetch-kexts.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not pinned"* ]]
}

@test "fetch-kexts.sh names the missing binary, not just 'no such file'" {
    _fake_zip "$BATS_TEST_TMPDIR/Lilu.zip" "Lilu.kext/Contents/Info.plist"
    _fake_zip "$BATS_TEST_TMPDIR/VirtualSMC.zip" \
        "Kexts/VirtualSMC.kext/Contents/Info.plist"
    _kext_sources "file://$BATS_TEST_TMPDIR/Lilu.zip" \
                  "file://$BATS_TEST_TMPDIR/VirtualSMC.zip"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/fetch-kexts.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Contents/MacOS/Lilu"* ]]
}

@test "fetch-kexts.sh says so when the archive has no kext bundle at all" {
    _fake_zip "$BATS_TEST_TMPDIR/Lilu.zip" "README.md"
    _fake_zip "$BATS_TEST_TMPDIR/VirtualSMC.zip" "README.md"
    _kext_sources "file://$BATS_TEST_TMPDIR/Lilu.zip" \
                  "file://$BATS_TEST_TMPDIR/VirtualSMC.zip"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/fetch-kexts.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no Lilu.kext"* ]]
}

@test "fetch-kexts.sh produces the layout build-efi-image.sh consumes" {
    _fake_zip "$BATS_TEST_TMPDIR/Lilu.zip" \
        "Lilu.kext/Contents/Info.plist" "Lilu.kext/Contents/MacOS/Lilu"
    _fake_zip "$BATS_TEST_TMPDIR/VirtualSMC.zip" \
        "Kexts/VirtualSMC.kext/Contents/Info.plist" \
        "Kexts/VirtualSMC.kext/Contents/MacOS/VirtualSMC" \
        "Tools/smcread" "Drivers/VirtualSmc.efi"
    _kext_sources "file://$BATS_TEST_TMPDIR/Lilu.zip" \
                  "file://$BATS_TEST_TMPDIR/VirtualSMC.zip"
    run env MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/fetch-kexts.sh"
    [ "$status" -eq 0 ]
    for k in Lilu VirtualSMC; do
        [ -f "$BATS_TEST_TMPDIR/build/kexts/$k.kext/Contents/Info.plist" ]
        [ -f "$BATS_TEST_TMPDIR/build/kexts/$k.kext/Contents/MacOS/$k" ]
    done
}

# --- assembling the EFI image -----------------------------------------

# A build area with plausible artifacts and their SHA256SUMS, so the image
# build gets past its provenance check and we can test what comes after.
_fake_artifacts() {
    local art="$BATS_TEST_TMPDIR/build/artifacts" a
    mkdir -p "$art"
    for a in BOOTx64.efi OpenCore.efi OpenRuntime.efi OpenPartitionDxe.efi \
             OpenHfsPlus.efi; do
        printf 'not really %s\n' "$a" > "$art/$a"
    done
    ( cd "$art" && sha256sum ./*.efi | sed 's| \./| |' > SHA256SUMS )
}

@test "build-efi-image.sh lists what it puts in the image" {
    run "$REPO/boot/build-efi-image.sh" --list-contents
    [ "$status" -eq 0 ]
    [[ "$output" == *"OpenHfsPlus.efi"* ]]
    [[ "$output" == *"Lilu.kext"* ]]
    [[ "$output" == *"config.plist"* ]]
}

@test "build-efi-image.sh says which script to run when artifacts are absent" {
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-efi-image.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"build-opencore.sh"* ]]
}

@test "build-efi-image.sh refuses artifacts that do not match SHA256SUMS" {
    _fake_artifacts
    printf 'tampered\n' > "$BATS_TEST_TMPDIR/build/artifacts/OpenCore.efi"
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-efi-image.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHA256SUMS"* ]]
}

@test "build-efi-image.sh names the missing kext piece, not just the kext" {
    _fake_artifacts
    # A bundle with its Info.plist but no Mach-O: the shape that would
    # otherwise fail later as a confusing mcopy error.
    mkdir -p "$BATS_TEST_TMPDIR/build/kexts/Lilu.kext/Contents"
    printf 'plist\n' > "$BATS_TEST_TMPDIR/build/kexts/Lilu.kext/Contents/Info.plist"
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-efi-image.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Contents/MacOS/Lilu"* ]]
    [[ "$output" == *"fetch-kexts.sh"* ]]
}

@test "build-efi-image.sh builds an image whose EFI/OC is laid out for OpenCore" {
    _fake_artifacts
    for k in Lilu VirtualSMC; do
        mkdir -p "$BATS_TEST_TMPDIR/build/kexts/$k.kext/Contents/MacOS"
        printf 'plist\n' > "$BATS_TEST_TMPDIR/build/kexts/$k.kext/Contents/Info.plist"
        printf 'macho\n' > "$BATS_TEST_TMPDIR/build/kexts/$k.kext/Contents/MacOS/$k"
    done
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR" \
        MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-efi-image.sh" "$BATS_TEST_TMPDIR/oc.img"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/oc.img" ]
    [ -f "$BATS_TEST_TMPDIR/oc.img.sha256" ]

    # Read the layout back out of the image rather than trusting the build.
    run mdir -b -i "$BATS_TEST_TMPDIR/oc.img@@1048576" -/ ::
    [ "$status" -eq 0 ]
    [[ "$output" == *"::/EFI/BOOT/BOOTx64.efi"* ]]
    [[ "$output" == *"::/EFI/OC/OpenCore.efi"* ]]
    [[ "$output" == *"::/EFI/OC/config.plist"* ]]
    [[ "$output" == *"::/EFI/OC/Drivers/OpenHfsPlus.efi"* ]]
    # The kext must arrive as a bundle, not as a flattened pair of files.
    [[ "$output" == *"::/EFI/OC/Kexts/Lilu.kext/Contents/Info.plist"* ]]
    [[ "$output" == *"::/EFI/OC/Kexts/Lilu.kext/Contents/MacOS/Lilu"* ]]
    [[ "$output" == *"::/EFI/OC/Kexts/VirtualSMC.kext/Contents/MacOS/VirtualSMC"* ]]
    # Apple's HFS+ driver must never appear in the shipped image.
    [[ "$output" != *"HfsPlusLegacy.efi"* ]]
}

# --- OVMF, built from the same pinned EDK II tree ----------------------
#
# P3's gate is that nothing in the boot path is a binary we cannot rebuild.
# The firmware was the last holdout: Debian's stock OVMF 2024.02 does not
# work with OpenCore on this host (proved with khronokernel's reference
# OpenCore as a control), so the fix and the gate are the same thing --
# build it ourselves, out of the acidanthera/audk tree boot/build-opencore.sh
# already pins.

@test "build-ovmf.sh lists the firmware images it intends to produce" {
    run "$REPO/boot/build-ovmf.sh" --list-artifacts
    [ "$status" -eq 0 ]
    # The split pflash pair, which is what restores EFI variable persistence...
    [[ "$output" == *"OVMF_CODE.fd"* ]]
    [[ "$output" == *"OVMF_VARS.fd"* ]]
    # ...and the combined image, for -bios, which is how the reference
    # firmware was wired.
    [[ "$output" == *"OVMF.fd"* ]]
}

@test "build-ovmf.sh builds X64 RELEASE with GCC, like the OpenCore build" {
    run "$REPO/boot/build-ovmf.sh" --show-build
    [ "$status" -eq 0 ]
    [[ "$output" == *"OvmfPkg/OvmfPkgX64.dsc"* ]]
    [[ "$output" == *"X64"* ]]
    [[ "$output" == *"GCC"* ]]
    [[ "$output" == *"RELEASE"* ]]
}

@test "build-ovmf.sh takes the EDK II tree and its commit from the OpenCore build" {
    run "$REPO/boot/build-opencore.sh" --udk-commit
    [ "$status" -eq 0 ]
    commit="$output"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]]
    # The same commit the pins declare -- one source of truth, not two.
    run "$REPO/boot/build-opencore.sh" --show-pins
    [[ "$output" == *"audk-src"$'\t'"$commit"* ]]
    run env MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" \
        "$REPO/boot/build-opencore.sh" --udk-dir
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7/UDK" ]
}

@test "build-ovmf.sh says which script to run when the EDK II tree is absent" {
    run env MQG_BUILD_DIR="$BATS_TEST_TMPDIR/nonexistent" \
        "$REPO/boot/build-ovmf.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"build-opencore.sh"* ]]
}

@test "build-ovmf.sh refuses an EDK II tree at a different audk commit" {
    # A tree that exists, with BaseTools apparently built, but holding some
    # other commit. Rebuilding OVMF from an unpinned tree would produce
    # firmware nobody could reproduce, which is the whole point of the gate.
    udk="$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7/UDK"
    mkdir -p "$udk/BaseTools/Source/C/bin"
    printf '#!/bin/sh\nexit 0\n' > "$udk/BaseTools/Source/C/bin/GenFv"
    chmod +x "$udk/BaseTools/Source/C/bin/GenFv"
    printf '%s\n' "$(printf '%040d' 0)" > "$udk/.mqg-prepared"
    run env MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" "$REPO/boot/build-ovmf.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not the pinned"* ]]
}

@test "build-ovmf.sh says so when BaseTools are not built" {
    udk="$BATS_TEST_TMPDIR/build/OpenCorePkg-1.0.7/UDK"
    mkdir -p "$udk"
    "$REPO/boot/build-opencore.sh" --udk-commit > "$udk/.mqg-prepared"
    run env MQG_BUILD_DIR="$BATS_TEST_TMPDIR/build" "$REPO/boot/build-ovmf.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"BaseTools"* ]]
}

@test "nothing in the OVMF build reaches the network" {
    # The same claim boot/build-opencore.sh makes, and the same guard: no
    # fetch tool is named anywhere in the script.
    run grep -nE '\b(curl|wget|git clone|git fetch|git pull)\b' \
        "$REPO/boot/build-ovmf.sh"
    [ "$status" -ne 0 ]
}

# --- per-VM EFI variable stores ---------------------------------------
#
# The VARS image the build produces is a template. A VM that booted from it
# directly would scribble its boot order into a build artifact and silently
# invalidate its checksum; two VMs sharing one would trample each other.

_nvram_env() {
    printf '%s\n' \
        "MQG_BUILD_DIR=$BATS_TEST_TMPDIR/build" \
        "MQG_FIRMWARE_DIR=$BATS_TEST_TMPDIR/build/firmware" \
        "WORK_DIR=$BATS_TEST_TMPDIR/work"
}

# The same settings as an array, in `e`, ready for `env "${e[@]}"`.
#
# `while read` rather than `mapfile`, which is bash 4 -- see
# bin/bash32-check.sh. A function cannot return an array, so this sets `e`
# in the caller's scope rather than printing it; every caller wanted it
# under that name anyway. `< <(...)` rather than a pipe, so the loop runs
# in the caller's shell and the assignment survives.
_nvram_env_array() {
    local line
    e=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        e+=("$line")
    done < <(_nvram_env)
}

# A firmware directory holding a plausible VARS template and its SHA256SUMS.
_fake_firmware() {
    mkdir -p "$BATS_TEST_TMPDIR/build/firmware"
    printf 'pristine variable store\n' \
        > "$BATS_TEST_TMPDIR/build/firmware/OVMF_VARS.fd"
    ( cd "$BATS_TEST_TMPDIR/build/firmware" \
      && sha256sum OVMF_VARS.fd > SHA256SUMS )
}

@test "make-nvram.sh copies the template to a per-VM path" {
    _fake_firmware
    _nvram_env_array
    run env "${e[@]}" "$REPO/boot/make-nvram.sh" p3-full
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/work/p3-full-VARS.fd" ]
    # ...and the copy is byte-identical to the template it came from.
    cmp "$BATS_TEST_TMPDIR/work/p3-full-VARS.fd" \
        "$BATS_TEST_TMPDIR/build/firmware/OVMF_VARS.fd"
    # ...and prints where it put it, so a profile author can see the path.
    [[ "$output" == *"p3-full-VARS.fd"* ]]
}

@test "make-nvram.sh refuses to clobber an existing NVRAM file" {
    _fake_firmware
    _nvram_env_array
    mkdir -p "$BATS_TEST_TMPDIR/work"
    printf 'boot order lives here\n' > "$BATS_TEST_TMPDIR/work/p3-full-VARS.fd"
    run env "${e[@]}" "$REPO/boot/make-nvram.sh" p3-full
    [ "$status" -ne 0 ]
    [[ "$output" == *"--force"* ]]
    # The existing file is untouched: this is accumulated guest state.
    grep -q 'boot order lives here' "$BATS_TEST_TMPDIR/work/p3-full-VARS.fd"
}

@test "make-nvram.sh --force resets an existing NVRAM file" {
    _fake_firmware
    _nvram_env_array
    mkdir -p "$BATS_TEST_TMPDIR/work"
    printf 'boot order lives here\n' > "$BATS_TEST_TMPDIR/work/p3-full-VARS.fd"
    run env "${e[@]}" "$REPO/boot/make-nvram.sh" --force p3-full
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/work/p3-full-VARS.fd" \
        "$BATS_TEST_TMPDIR/build/firmware/OVMF_VARS.fd"
}

@test "make-nvram.sh never writes into the build output" {
    _fake_firmware
    _nvram_env_array
    run env "${e[@]}" WORK_DIR="$BATS_TEST_TMPDIR/build/firmware" \
        "$REPO/boot/make-nvram.sh" p3-full
    [ "$status" -ne 0 ]
    [[ "$output" == *"build output"* ]]
}

@test "make-nvram.sh rejects a name that is a path" {
    _fake_firmware
    _nvram_env_array
    run env "${e[@]}" "$REPO/boot/make-nvram.sh" ../../escape
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a usable VM name"* ]]
}

@test "make-nvram.sh refuses a template that does not match SHA256SUMS" {
    _fake_firmware
    _nvram_env_array
    printf 'somebody booted from the template\n' \
        > "$BATS_TEST_TMPDIR/build/firmware/OVMF_VARS.fd"
    run env "${e[@]}" "$REPO/boot/make-nvram.sh" p3-full
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
}

@test "make-nvram.sh says which script to run when there is no template" {
    _nvram_env_array
    run env "${e[@]}" "$REPO/boot/make-nvram.sh" p3-full
    [ "$status" -ne 0 ]
    [[ "$output" == *"build-ovmf.sh"* ]]
}

@test "prereqs.sh and triangulate.sh check the same tools" {
    # ap-juicer 2026-09-21: triangulate reported xxd and bats missing;
    # prereqs.sh had never heard of either, so it would have printed a
    # shorter list than the truth. Two lists drifting is how a
    # prerequisites script comes to answer wrongly rather than not answer.
    tri=$(sed -n 's/^RUNTIME_TOOLS="\(.*\)"$/\1/p;s/^BUILD_TOOLS="\(.*\)"$/\1/p' \
          "$REPO/bin/triangulate.sh" | tr ' ' '\n' | grep -v '^$' | sort -u)
    [ -n "$tri" ] || { echo "could not find triangulate's tool lists"; false; }
    # qemu-system-x86_64 and qemu-img are runtime, not build prerequisites,
    # and prereqs.sh is about building. Everything else must be named.
    tri=$(printf '%s\n' "$tri" | grep -vE '^qemu-(system-x86_64|img)$')
    for t in $tri; do
        run grep -q "^$t|" "$REPO/boot/prereqs.sh"
        [ "$status" -eq 0 ] || { echo "triangulate checks '$t'; prereqs.sh does not"; false; }
    done
}

@test "prereqs.sh knows every tool the scripts actually require" {
    # ap-juicer 2026-09-21 stopped at "missing required command: zip",
    # which neither prereqs.sh nor triangulate.sh checked. The build
    # scripts declare their needs with require_cmd; that declaration is
    # the authority, and this table is the lookup. An earlier fix
    # reconciled two lists while a third went unread.
    missing=""
    for t in $(grep -rhoE 'require_cmd [a-z0-9. _-]+' --include='*.sh' "$REPO" \
               | sed 's/require_cmd //' | tr ' ' '\n' | grep -v '^$' | sort -u); do
        grep -q "^$t|" "$REPO/boot/prereqs.sh" || missing="$missing $t"
    done
    [ -z "$missing" ] || { echo "require_cmd names these; prereqs.sh does not:$missing"; false; }
}
