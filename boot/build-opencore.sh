#!/usr/bin/env bash
# Build OpenCore from pinned source and collect what we ship.
#
# This script makes no network requests. Every input it uses was fetched
# and checksummed earlier, by boot/fetch-opencorepkg.sh and
# boot/fetch-edk2.sh; here they are only verified, unpacked and compiled.
# The test for that claim is `unshare -rn ./boot/build-opencore.sh`, which
# runs it in a network namespace with no connectivity.
#
# Upstream does not build this way. OpenCorePkg's build_oc.tool ends by
# curl-ing ocbuild's efibuild.sh off the master branch and eval-ing it, and
# that script in turn clones acidanthera/audk at master and git-pulls it on
# re-runs. Two of the three inputs floated and arbitrary fetched shell ran
# at build time. All three are pinned now:
#
#   OpenCorePkg  release tarball, vendor/sources.tsv (opencorepkg-src)
#   efibuild.sh  ocbuild at OCBUILD_COMMIT, read from disk instead of curl'd
#   EDK II       acidanthera/audk at AUDK_COMMIT, plus its submodules,
#                which a GitHub archive tarball leaves out
#
# build_oc.tool itself is patched, not edited: the one-line change lives in
# boot/patches/ and is applied here, so what we do to upstream's script is
# a diff anyone can read.
#
# Three environment choices are ours, not build_oc.tool's defaults, and each
# one exists for a reason:
#
#   ARCHS=X64       build_oc.tool defaults to (X64 IA32). We boot a 64-bit
#                   guest, and IA32 doubles the build for nothing.
#   TOOLCHAINS=GCC  efibuild.sh's Linux default is (CLANGPDB GCC), i.e. two
#                   full builds, and CLANGPDB needs clang, which this host
#                   does not have. GCC is the one that works here.
#   TARGETS=RELEASE default is (DEBUG RELEASE NOOPT). A DEBUG build writes a
#                   log on every boot and is substantially slower.
#
# and two more are what make it offline:
#
#   OFFLINE_MODE=1  efibuild.sh's own switch: skip the audk clone and the
#                   `git pull --rebase`, use the UDK tree already present.
#   EFIBUILD_SH     added by our patch: where to read efibuild.sh from.
set -euo pipefail

OC_VERSION=1.0.7
OC_ARCH=X64
OC_TOOLCHAIN=GCC
OC_TARGET=RELEASE

# The pinned commits. These are what "reproducible" means for this build,
# and this is the one place they are written down: boot/fetch-edk2.sh asks
# this script (--show-pins) what to download. vendor/sources.tsv holds the
# URLs; pinned_file below refuses a URL that does not name the commit
# expected here, rather than trusting two files to stay in step.
OCBUILD_COMMIT=e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a
AUDK_COMMIT=0672a009e9ca85753d240324d761341adf0291b3

# audk's submodules: "<source name>:<commit>:<path under UDK>".
#
# A GitHub archive tarball carries no submodule content -- it leaves an
# empty directory at each submodule path -- so each one is pinned and
# unpacked separately. This is the whole set audk's gitlinks name, not just
# the ones that get compiled, because build.py validates every [Includes]
# path in every .dec it parses: MdePkg.dec alone names
# MipiSysTLib/mipisyst/library/include, and the build dies at meta-data
# processing if that directory is absent. `git submodule update --init` is
# what upstream does here; this is the same thing with checksums.
#
# Two entries share one tarball: audk has brotli twice, at the same commit.
AUDK_SUBMODULES=(
    "audk-openssl:aea7aaf2abb04789f5868cbabec406ea43aa84bf:CryptoPkg/Library/OpensslLib/openssl"
    "audk-brotli:e230f474b87134e8c6c85b630084c612057f253e:BaseTools/Source/C/BrotliCompress/brotli"
    "audk-brotli:e230f474b87134e8c6c85b630084c612057f253e:MdeModulePkg/Library/BrotliCustomDecompressLib/brotli"
    "audk-mbedtls:8c89224991adff88d53cd380f42a2baa36f91454:CryptoPkg/Library/MbedTlsLib/mbedtls"
    "audk-oniguruma:4ef89209a239c1aea328cf13c05a2807e5c146d1:MdeModulePkg/Universal/RegularExpressionDxe/oniguruma"
    "audk-libfdt:cfff805481bdea27f900c32698171286542b8d3c:MdePkg/Library/BaseFdtLib/libfdt"
    "audk-mipisyst:370b5944c046bab043dd8b133727b2135af7747a:MdePkg/Library/MipiSysTLib/mipisyst"
    "audk-jansson:e9ebfa7e77a6bee77df44e096b100e7131044059:RedfishPkg/Library/JsonLib/jansson"
    "audk-libspdm:98ef964e1e9a0c39c7efb67143d3a13a819432e0:SecurityPkg/DeviceSecurity/SpdmLib/libspdm"
    "audk-cmocka:1cc9cde3448cdd2e000886a26acf1caac2db7cf1:UnitTestFrameworkPkg/Library/CmockaLib/cmocka"
    "audk-googletest:86add13493e5c881d7e4ba77fb91c1f57752b3a4:UnitTestFrameworkPkg/Library/GoogleTestLib/googletest"
    "audk-subhook:83d4e1ebef3588fae48b69a7352cc21801cb70bc:UnitTestFrameworkPkg/Library/SubhookLib/subhook"
)

# What we ship: "<name build_oc.tool produces>:<name we ship it as>".
#
# Bootstrap.efi is renamed rather than found: OpenCore's bootstrap driver is
# what becomes the fallback boot path EFI/BOOT/BOOTx64.efi, and nothing in
# the build tree is ever called BOOTx64.efi. build_oc.tool's own package()
# does this same rename, but then deletes the staged tree once it has zipped
# it, so we do the rename ourselves rather than unpacking its archive.
#
# OpenHfsPlus is in Staging/, but 1.0.7's OpenCorePkg.dsc lists
# Staging/OpenHfsPlus/OpenHfsPlus.inf in [Components] alongside everything
# else, so the default target does build it. Nothing extra is needed.
ARTIFACT_MAP=(
    "OpenCore.efi:OpenCore.efi"
    "Bootstrap.efi:BOOTx64.efi"
    "OpenRuntime.efi:OpenRuntime.efi"
    "OpenPartitionDxe.efi:OpenPartitionDxe.efi"
    "OpenHfsPlus.efi:OpenHfsPlus.efi"
)

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/vendor.sh
. "$MQG_REPO_ROOT/lib/vendor.sh"

artifact_names() {
    local entry
    for entry in "${ARTIFACT_MAP[@]}"; do
        printf '%s\n' "${entry#*:}"
    done
}

if [ "${1:-}" = "--list-artifacts" ]; then
    artifact_names
    exit 0
fi

# Every pinned input, as "<source name in vendor/sources.tsv>\t<commit>",
# each name once. boot/fetch-edk2.sh downloads exactly this list, so the
# build declares what it needs and the fetch script has no pins of its own
# to drift out of date.
show_pins() {
    local entry name seen=""
    printf 'ocbuild-efibuild\t%s\n' "$OCBUILD_COMMIT"
    printf 'audk-src\t%s\n' "$AUDK_COMMIT"
    for entry in "${AUDK_SUBMODULES[@]}"; do
        name=${entry%%:*}
        case " $seen " in
            *" $name "*) continue ;;
        esac
        seen="$seen $name"
        printf '%s\t%s\n' "$name" "$(sub_commit "$entry")"
    done
}

# The commit and destination halves of an AUDK_SUBMODULES entry.
sub_commit() { local rest=${1#*:}; printf '%s\n' "${rest%%:*}"; }
sub_path()   { printf '%s\n' "${1##*:}"; }

if [ "${1:-}" = "--show-pins" ]; then
    show_pins
    exit 0
fi

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
SOURCES=${MQG_SOURCES:-$MQG_REPO_ROOT/vendor/sources.tsv}
SRC="$MQG_BUILD_DIR/OpenCorePkg-$OC_VERSION"
UDK="$SRC/UDK"
OUT="$MQG_BUILD_DIR/artifacts"
PATCH_DIR="$MQG_REPO_ROOT/boot/patches"

# Where this script assembles the EDK II tree, and which commit it holds.
#
# boot/build-ovmf.sh builds OvmfPkg out of that same tree rather than
# unpacking a second copy of a 19 MB tarball and eleven submodules. It asks
# here rather than recomputing the path, so OC_VERSION and the layout stay
# in one place. --udk-commit is the pin the tree is expected to hold; the
# marker file inside it says what it actually holds, and the two disagreeing
# is what tells a caller the tree is stale.
if [ "${1:-}" = "--udk-dir" ]; then
    printf '%s\n' "$UDK"
    exit 0
fi
if [ "${1:-}" = "--udk-commit" ]; then
    printf '%s\n' "$AUDK_COMMIT"
    exit 0
fi

[ -d "$SRC" ] || die "no OpenCorePkg source tree at $SRC -- run boot/fetch-opencorepkg.sh first"

# pinned_file <source-name> <commit>
#
# The local path of an input boot/fetch-edk2.sh already downloaded, after
# checking it three ways: that the URL in sources.tsv names the commit this
# script expects, that the checksum is pinned rather than TOFU, and that the
# bytes on disk still match it. All three are offline checks.
pinned_file() {
    local name=$1 commit=$2 url sha file
    url=$(source_field "$SOURCES" "$name" url) || exit 1
    case $url in
        *"$commit"*) : ;;
        *) die "$name in $SOURCES does not name commit $commit: $url" ;;
    esac
    sha=$(source_field "$SOURCES" "$name" sha256) || exit 1
    [ "$sha" != "TOFU" ] \
        || die "$name is not pinned -- run boot/fetch-edk2.sh, review the checksum, and commit it"
    file="$MQG_BUILD_DIR/${url##*/}"
    [ -f "$file" ] \
        || die "$name is not present at $file -- run boot/fetch-edk2.sh first;" \
               "this script never touches the network"
    verify_sha256 "$file" "$sha"
    printf '%s\n' "$file"
}

# unpack_submodule <tarball> <destdir>
# A GitHub archive unpacks into one top-level directory; --strip-components
# puts its contents where a `git submodule update` would have put them.
unpack_submodule() {
    local tarball=$1 dest=$2
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -C "$dest" --strip-components=1 -xzf "$tarball" \
        || die "cannot unpack $tarball into $dest"
}

# Resolve and verify every input before touching anything, so a missing or
# corrupt tarball fails while the tree on disk is still whatever it was.
efibuild=$(pinned_file ocbuild-efibuild "$OCBUILD_COMMIT")
audk_tar=$(pinned_file audk-src "$AUDK_COMMIT")
declare -A SUB_TARBALL=()
for entry in "${AUDK_SUBMODULES[@]}"; do
    sub_name=${entry%%:*}
    if [ -z "${SUB_TARBALL[$sub_name]:-}" ]; then
        sub_file=$(pinned_file "$sub_name" "$(sub_commit "$entry")")
        SUB_TARBALL[$sub_name]=$sub_file
    fi
done

# git: efibuild.sh insists on it, and we apply patches with it.
# zip: efibuild.sh refuses to start without it.
# Note what is *not* here any more: curl. Nothing this script runs is
# allowed to want it.
require_cmd git tar zip

"$MQG_REPO_ROOT/boot/prereqs.sh" >/dev/null || die "build prerequisites are missing -- run boot/prereqs.sh"

# Replace build_oc.tool's curl-and-eval with a read of $efibuild. Guarded
# by the grep so a warm tree is not patched twice; asserted afterwards so a
# patch that silently did nothing cannot pass for success.
if grep -q 'raw\.githubusercontent\.com' "$SRC/build_oc.tool"; then
    log "patching build_oc.tool to source the pinned efibuild.sh"
    git -C "$SRC" apply -p1 "$PATCH_DIR/0001-build_oc-source-pinned-efibuild.patch" \
        || die "cannot patch build_oc.tool -- did OpenCorePkg $OC_VERSION change?"
fi
if grep -q 'raw\.githubusercontent\.com' "$SRC/build_oc.tool"; then
    die "build_oc.tool still fetches shell from the network"
fi

# Assemble the EDK II tree efibuild.sh would otherwise have cloned.
#
# The marker records which audk commit the tree holds, so bumping the pin
# rebuilds it and a re-run over the same pin does not. UDK.ready matters to
# efibuild.sh for a reason that is easy to miss: if it is absent, efibuild
# does `rm -rf UDK` before anything else. Ours has to exist up front or the
# tree we just unpacked is deleted. patches.ready and submodules.ready keep
# efibuild from trying to redo, with git, work we have already done here.
#
# boot/build-ovmf.sh reads this marker too, to refuse to build OvmfPkg out
# of a tree that is absent or holds a different audk commit than it pinned.
PREPARED="$UDK/.mqg-prepared"
if [ ! -f "$PREPARED" ] || [ "$(cat "$PREPARED")" != "$AUDK_COMMIT" ]; then
    log "assembling EDK II tree: audk $AUDK_COMMIT"
    rm -rf "$UDK"
    mkdir -p "$UDK"
    tar -C "$UDK" --strip-components=1 -xzf "$audk_tar" \
        || die "cannot unpack $audk_tar into $UDK"

    # A GitHub archive leaves an *empty directory* at every submodule path,
    # and audk has a submodule of its own called OpenCorePkg. efibuild.sh
    # wants to put a symlink there, pointing at the OpenCorePkg tree we are
    # building -- but its symlink() quietly does nothing when the target
    # already exists as a directory, and then BaseTools fails compiling
    # ImageTool because OpenCorePkg/User/Include/UserFile.h is not there.
    # Upstream avoids this by `git rm`-ing the submodule (DISCARD_SUBMODULES)
    # inside the clone step we are skipping, so we do the equivalent here.
    rm -rf "$UDK/OpenCorePkg"

    for entry in "${AUDK_SUBMODULES[@]}"; do
        sub_name=${entry%%:*}
        sub_sha=$(sub_commit "$entry")
        sub_dest=$(sub_path "$entry")
        log "  + $sub_dest @ $sub_sha"
        unpack_submodule "${SUB_TARBALL[$sub_name]}" "$UDK/$sub_dest"
    done

    # The same five patches, in the same order, that efibuild.sh applies.
    # It commits each one; we do not, because the tree is no longer a git
    # repository and nothing downstream reads its history.
    for patch in "$SRC"/Patches/*; do
        [ -f "$patch" ] || continue
        log "  + patch $(basename "$patch")"
        git -C "$UDK" apply --ignore-whitespace "$patch" \
            || die "cannot apply $patch to the EDK II tree"
    done

    touch "$UDK/patches.ready" "$UDK/submodules.ready" "$UDK/UDK.ready"
    printf '%s\n' "$AUDK_COMMIT" > "$PREPARED"
else
    log "EDK II tree already assembled at audk $AUDK_COMMIT"
fi

log "building OpenCore $OC_VERSION in $SRC"
log "arch $OC_ARCH, toolchain $OC_TOOLCHAIN, target $OC_TARGET (this takes a while and is noisy)"
start=$(date +%s)
(
    cd "$SRC"
    ARCHS=$OC_ARCH TOOLCHAINS=$OC_TOOLCHAIN TARGETS=$OC_TARGET \
        OFFLINE_MODE=1 EFIBUILD_SH="$efibuild" \
        ./build_oc.tool
) || die "build_oc.tool failed -- see $UDK/build.log, and report the error rather than working around it"
elapsed=$(( $(date +%s) - start ))
log "build_oc.tool finished in $((elapsed / 60))m$((elapsed % 60))s"

BUILT="$UDK/Build/OpenCorePkg/${OC_TARGET}_${OC_TOOLCHAIN}/$OC_ARCH"
[ -d "$BUILT" ] || die "build reported success but $BUILT does not exist"

mkdir -p "$OUT"
missing=()
for entry in "${ARTIFACT_MAP[@]}"; do
    built_name=${entry%%:*}
    ship_name=${entry#*:}
    if [ -f "$BUILT/$built_name" ]; then
        cp "$BUILT/$built_name" "$OUT/$ship_name"
    else
        missing+=("$built_name")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    warn "not produced by the build: ${missing[*]}"
    warn "looked in $BUILT"
    die "missing ${#missing[@]} of ${#ARTIFACT_MAP[@]} artifacts"
fi

# ocvalidate is a host tool, not firmware: Task 4 runs it against our
# config.plist so the config is checked by the schema of the exact OpenCore
# we built, not by whatever ocvalidate happens to be lying around.
ocvalidate="$SRC/Utilities/ocvalidate/ocvalidate"
if [ -x "$ocvalidate" ]; then
    log "ocvalidate: $ocvalidate"
else
    warn "ocvalidate not built at $ocvalidate -- Task 4 needs it"
fi

mapfile -t ship_names < <(artifact_names)
( cd "$OUT" && sha256sum "${ship_names[@]}" > SHA256SUMS )
log "built ${#ship_names[@]} artifacts into $OUT"
cat "$OUT/SHA256SUMS"
