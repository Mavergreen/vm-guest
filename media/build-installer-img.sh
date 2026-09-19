#!/usr/bin/env bash
# Build bootable Mavericks installer media on Linux, from Apple's own
# InstallESD.dmg, with no Mac and no root.
#
# The recipe is eprigorodov/mkosxinstallusb's, with two changes: it targets
# an image file rather than /dev/sdX, and every privileged step has an
# unprivileged equivalent (see lib/hfs.sh and the P4 entries in NOTES.md).
# What comes out is what the Mac-produced reference ISO contains --
# media/verify-installer-img.sh is how we find out whether that is true,
# and a finished rsync on its own proves nothing.
#
#   1. dmg2img InstallESD.dmg, mount it.
#   2. dmg2img the BaseSystem.dmg inside it, mount that too.
#   3. Create a GPT image with one AF00 partition holding an "OS X Base
#      System" volume, sized from the reference.
#   4. rsync BaseSystem onto it.
#   5. Replace System/Installation/Packages -- a symlink into the ESD
#      volume, dangling on media that has no ESD volume -- with the ESD's
#      real Packages directory, plus BaseSystem.chunklist and
#      BaseSystem.dmg, which the installer verifies the packages against.
#   6. With --autoinstall, add the three files Apple's own /etc/rc.install
#      looks for, which turn a boot of this media into an install that
#      needs nobody watching. See image/autoinstall/.
#
# Ownership: udisks mounts hfsplus with uid=<you>,gid=<you>,umask=22, so
# nothing written here can be owned by root or carry a setuid bit, whatever
# flags rsync is given. Whether the installer cares is the open question a
# boot answers; it runs as root and may rebuild what it needs. Not worked
# around here on purpose -- see NOTES.md.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/hfs.sh
. "$MQG_REPO_ROOT/lib/hfs.sh"
# shellcheck source=../lib/privops.sh
. "$MQG_REPO_ROOT/lib/privops.sh"
# shellcheck source=../lib/privops-qemu-linux.sh
. "$MQG_REPO_ROOT/lib/privops-qemu-linux.sh"

# The size the Mac-produced reference's HFS+ partition actually is, which
# is the number get.sh's `hdiutil resize` asks for. Measured, not guessed:
# `7z l InstallMavericks.iso` reports Physical Size = 6550020096 for the
# "disk image.hfs" it contains. HFS+ has to fill its partition exactly (the
# kernel reads the alternate volume header from the end of the device), and
# mkfs works in whole MiB, so we round up -- 925,696 bytes of slack over
# the reference, which is the smallest amount we can have.
REFERENCE_PARTITION_BYTES=6550020096

# ...plus a margin, because the reference size does not fit a Linux-built
# copy of the same files. Measured, on the build that ran out of space 17
# MB into BaseSystem.dmg: the same content costs about 153 MB of HFS+
# metadata and per-file slack here against about 105 MB on the Mac, and
# hdiutil had packed the reference down to 30 MB of free space. The extra
# is in the catalog: same files, different B-tree. 128 MiB is the next
# round number that leaves real room rather than another cliff edge.
#
# The reference is still what the size is *derived* from. Nothing about
# the media requires the two to be the same size -- a QEMU disk is not a
# USB stick someone has to buy -- but a number picked out of the air would
# have been a guess at whether the packages fit, which is the one thing
# this must not be.
# Raised from 128 to 512 MiB on 2026-09-18. The file that arrives corrupt
# is always the largest one, Essentials.pkg at 1.3 GB, written into a
# volume that 128 MiB of margin leaves 99% full. That is a guess at the
# cause and it is labelled as one: the Linux hfsplus driver is the only
# thing in the chain that could be writing the wrong bytes, and low free
# space with heavy fragmentation is the condition it is most likely to
# get wrong. The margin costs nothing -- the image is sparse and this is a
# QEMU disk, not a USB stick someone has to buy -- and the verification
# added beside it is what actually catches the fault either way.
# Overridable so that the margin can be varied experimentally without
# editing this file -- the 128-vs-512 comparison is how the guess above
# gets tested rather than believed.
MARGIN_MIB=${MQG_MEDIA_MARGIN_MIB:-512}
PART_MIB=$(( (REFERENCE_PARTITION_BYTES + 1048575) / 1048576 + MARGIN_MIB ))

VOLUME_NAME="OS X Base System"

# The unattended-install hooks, as "<source under image/autoinstall/>
# <destination on the media> <mode>". All three are Apple's own mechanism,
# not ours: /etc/rc.install sources rc.cdrom.local (line 39), reads
# Extras/minstallconfig.xml (line 104) and prefers OSInstall.collection
# over OSInstall.mpkg (lines 107-108). See image/autoinstall/ and the P4
# Task 5 entry in NOTES.md.
#
# rc.cdrom.local must be executable -- rc.install tests it with `[ -x ]`
# and silently skips it otherwise, which would leave the media booting to
# an automated installer with no target volume prepared.
AUTOINSTALL_FILES="\
autoinstall.sh|private/etc/rc.cdrom.local|755
minstallconfig.xml|System/Installation/Packages/Extras/minstallconfig.xml|644
OSInstall.collection|System/Installation/Packages/OSInstall.collection|644"

usage() {
    cat <<EOF
usage: $(basename "$0") [--describe] [--force] [--keep-work] [--autoinstall]
                             [--firstboot-pkg PATH] [--extra-pkg PATH]...

  --describe     Print the layout this would create and exit. Touches nothing.
  --force        Replace an existing installer image.
  --keep-work    Keep the multi-gigabyte raw conversions afterwards.
  --autoinstall  Inject the unattended-install hooks (image/autoinstall/),
                 so booting this media installs without anyone watching.
  --firstboot-pkg PATH
                 Also carry this package and add it to OSInstall.collection,
                 so the installer installs the first-boot payload as part of
                 the install. Implies --autoinstall. Build one with
                 image/payload/build-firstboot-pkg.sh.
  --extra-pkg PATH
                 Also carry this package on the media, beside the first-boot
                 payload, WITHOUT adding it to OSInstall.collection. The
                 first-boot payload's postinstall copies these onto the
                 target volume and firstboot.sh runs "installer -pkg" on
                 them. Repeatable. Implies --autoinstall.

                 Why not the collection? A package listed there is
                 installed by the OS installer itself, and that is proven
                 only for the payload-free script package we build. The
                 OpenSSH packages are real product archives with a
                 Distribution that declares <allowed-os-versions
                 min="10.9.5"/> -- a check whose answer mid-install is not
                 something to guess at. See image/payload/firstboot.sh.
EOF
}

describe=0
force=0
keep_work=0
autoinstall=0
firstboot_pkg=
extra_pkgs=()
# The name the package gets on the media, and the name OSInstall.collection
# then refers to. Fixed rather than taken from the source filename, so the
# collection entry cannot drift from the file.
FIRSTBOOT_PKG_NAME=mqg-firstboot.pkg
while [ $# -gt 0 ]; do
    case $1 in
        --describe) describe=1 ;;
        --force) force=1 ;;
        --keep-work) keep_work=1 ;;
        --autoinstall) autoinstall=1 ;;
        --firstboot-pkg) firstboot_pkg=$2; autoinstall=1; shift ;;
        --extra-pkg) extra_pkgs+=("$2"); autoinstall=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
media_dir=$MQG_IMAGE_DIR/media
esd_dmg=$media_dir/InstallESD.dmg
out=$media_dir/installer-linux.img
work=${MQG_MEDIA_WORK_DIR:-$media_dir/work}
esd_img=$work/esd.img
bs_img=$work/basesystem.img

if [ "$describe" -eq 1 ]; then
    cat <<EOF
installer media layout
  output              $out
  source              $esd_dmg
  work area           $work

  partition table     GPT, one partition
  partition 1 type    AF00 (Apple HFS+)
  partition 1 start   sector 2048 (1 MiB)
  partition 1 size    $PART_MIB MiB = $((PART_MIB * 1048576)) bytes
                      (the reference's is $REFERENCE_PARTITION_BYTES bytes,
                      rounded up to whole MiB -- HFS+ must fill its
                      partition exactly -- plus a $MARGIN_MIB MiB margin
                      for the larger catalog a Linux-built copy needs)
  disk size           $((PART_MIB + 2)) MiB = $(((PART_MIB + 2) * 1048576)) bytes
  volume name         $VOLUME_NAME

  contents
    everything in the ESD's BaseSystem.dmg, then
    System/Installation/Packages/     <- the ESD's real Packages directory,
                                        replacing a symlink that dangles
                                        once the ESD volume is gone
    System/Installation/BaseSystem.dmg
    System/Installation/BaseSystem.chunklist
EOF
    if [ "$autoinstall" -eq 1 ]; then
        cat <<EOF

  unattended-install hooks (--autoinstall)
EOF
        printf '%s\n' "$AUTOINSTALL_FILES" | while IFS='|' read -r src dst mode; do
            printf '    %-46s mode %s\n' "$dst" "$mode"
            printf '      from image/autoinstall/%s\n' "$src"
        done
        cat <<EOF

    All three are read by Apple's own /etc/rc.install, which is already on
    this media. They land root-owned like everything else, via the privops
    microVM -- launchd and the installer both refuse what they do not
    trust.
EOF
        if [ -n "$firstboot_pkg" ]; then
            cat <<EOF

  first-boot payload (--firstboot-pkg)
    System/Installation/Packages/$FIRSTBOOT_PKG_NAME
      from $firstboot_pkg
    ...and one more entry in OSInstall.collection naming it, so Apple's
    installer installs the payload during the install rather than anything
    being injected into a finished volume afterwards. See image/payload/.
EOF
        fi
        if [ "${#extra_pkgs[@]}" -gt 0 ]; then
            cat <<EOF

  extra packages (--extra-pkg), carried but NOT in OSInstall.collection
EOF
            for extra in ${extra_pkgs[@]+"${extra_pkgs[@]}"}; do
                printf '    System/Installation/Packages/%s\n' \
                    "$(basename "$extra")"
                printf '      from %s\n' "$extra"
            done
            cat <<EOF
    The first-boot payload's postinstall copies these to the target volume;
    firstboot.sh installs them with "installer -pkg ... -target /" on the
    installed system, where a product archive's version checks and scripts
    run against a real booted OS.
EOF
        fi
    fi
    exit 0
fi

require_cmd dmg2img sgdisk rsync truncate dd mkfs.hfsplus udisksctl \
    losetup findmnt lsblk du df sha256sum

[ -f "$esd_dmg" ] || die "no InstallESD.dmg at $esd_dmg --" \
    "run media/fetch-installesd.sh first"

# Checked here, before five gigabytes of dmg2img, rather than at the moment
# it is copied: a missing package should cost a second, not twenty minutes.
if [ -n "$firstboot_pkg" ]; then
    [ -f "$firstboot_pkg" ] \
        || die "no first-boot package at $firstboot_pkg --" \
               "build one with image/payload/build-firstboot-pkg.sh"
    [ "$(head -c 4 "$firstboot_pkg")" = "xar!" ] \
        || die "$firstboot_pkg is not a flat package (no xar magic)"
fi

# Same reasoning: a missing or bogus extra package should cost a second.
# `${arr[@]+...}`: before bash 4.4, expanding an empty array under `set -u`
# is an error rather than nothing. See bin/bash32-check.sh.
for extra in ${extra_pkgs[@]+"${extra_pkgs[@]}"}; do
    [ -f "$extra" ] || die "no such --extra-pkg: $extra"
    [ "$(head -c 4 "$extra")" = "xar!" ] \
        || die "$extra is not a flat package (no xar magic)"
done

if [ -e "$out" ]; then
    [ "$force" -eq 1 ] || die "$out exists; pass --force to replace it"
    log "--force: removing the existing $out"
    rm -f "$out" "$out.sha256"
fi

mkdir -p "$work" || die "cannot create $work"

# Intermediates are regenerated every run rather than reused. They are
# cheap (seconds) next to a stale or half-written one silently becoming the
# media we then spend an hour booting.
rm -f "$esd_img" "$bs_img" "$out.hfs-tmp"

ESD_MNT=
BS_MNT=

# Counted before and after the copy, and logged. An rsync that silently
# copies nothing looks exactly like an rsync that worked, until something
# downstream fails for a reason that makes no sense.
count_tree() {
    local where=$1 what=$2 n bytes
    n=$(find "$where" -mindepth 1 | wc -l)
    bytes=$(du -sb "$where" | cut -f1)
    log "$what: $n entries, $bytes bytes"
}

# BaseSystem has one file we are not allowed to read: /.file, mode 0000,
# the marker OS X looks for to decide a volume has a filesystem on it. Root
# could read it; we cannot, and rsync fails the whole transfer over it.
# It is empty, so there is nothing in it to read -- what matters is that a
# file of that name and mode exists. Copy the metadata by hand and keep the
# transfer itself clean, so a genuine rsync failure still means something.
#
# Any *non-empty* unreadable file would be a different story: that would be
# content we cannot copy without root, and a finding rather than a detail.
# Hence the size check.
unreadable_files() {
    find "$1" -type f ! -readable -printf '%P\0'
}

recreate_unreadable() {
    local src=$1 dst=$2 rel
    while IFS= read -r -d '' rel; do
        log "recreating unreadable (mode $(stat -c %a "$src/$rel")) empty file: $rel"
        : > "$dst/$rel" || die "cannot create $dst/$rel"
        touch -r "$src/$rel" "$dst/$rel"
        chmod "$(stat -c %a "$src/$rel")" "$dst/$rel"
    done < <(unreadable_files "$src")
}

populate_target() {
    local tgt=$1 pkg_link=$1/System/Installation/Packages
    local rel
    local -a excludes=()
    while IFS= read -r -d '' rel; do
        [ "$(stat -c %s "$BS_MNT/$rel")" -eq 0 ] \
            || die "$BS_MNT/$rel is unreadable and not empty:" \
                   "copying it would need root"
        excludes+=( "--exclude=/$rel" )
    done < <(unreadable_files "$BS_MNT")

    log "copying BaseSystem onto the target volume"
    # -a without -o/-g: udisks mounts this filesystem uid=<us>,gid=<us>, so
    # preserving ownership is not on offer and asking for it only produces
    # errors. -H matters -- BaseSystem hardlinks several binaries, and
    # without it each one is copied again, which this volume has no room
    # for. No -X: the Linux hfsplus driver exposes no extended attributes
    # at all (getfattr on the source returns nothing), so there is nothing
    # for rsync to carry.
    # `${excludes[@]+...}`: excludes is empty when every file was readable,
    # and before bash 4.4 expanding an empty array under `set -u` is an
    # "unbound variable" error. See bin/bash32-check.sh.
    rsync -rlptDH --info=stats2 ${excludes[@]+"${excludes[@]}"} \
        "$BS_MNT/" "$tgt/" >&2 \
        || die "rsync of BaseSystem failed"
    recreate_unreadable "$BS_MNT" "$tgt"
    count_tree "$tgt" "after BaseSystem"

    # On the ESD this is a symlink to /System/Installation/PackagesLink,
    # which resolves through the ESD volume. On installer media there is no
    # ESD volume, so the real directory goes here instead.
    [ -L "$pkg_link" ] || die "expected a Packages symlink at $pkg_link"
    log "replacing the Packages symlink with the ESD's real Packages"
    rm -f "$pkg_link"
    rsync -rlptDH --info=stats2 "$ESD_MNT/Packages/" "$pkg_link/" >&2 \
        || die "rsync of Packages failed"

    log "copying BaseSystem.dmg and BaseSystem.chunklist"
    rsync -rlptDH "$ESD_MNT/BaseSystem.dmg" "$ESD_MNT/BaseSystem.chunklist" \
        "$tgt/System/Installation/" \
        || die "could not copy BaseSystem.dmg/chunklist"

    check_esd_packages "$ESD_MNT/Packages"

    [ "$autoinstall" -eq 0 ] || inject_autoinstall "$tgt"

    count_tree "$tgt" "final volume"
    log "free space on the target volume:"
    df -h "$tgt" >&2
}

# WHY THESE TWO FUNCTIONS EXIST: A FINISHED RSYNC PROVES NOTHING, AND
# NEITHER DOES READING BACK WHAT YOU JUST WROTE.
#
# Three media builds in six put a corrupt copy of Apple's Essentials.pkg on
# the media -- 3.2 GB, half of everything there. rsync reported success,
# the entry and byte counts matched, and the install got several minutes in
# before the OS X Installer stopped with
#
#   BOMCopierFatalError ... offset=13899638, sourcePath=.../Essentials.pkg
#
# twice, with two different messages. That offset was read at the time as
# evidence of a structural fault in one particular place. It is not: 13899638
# is where Apple's Payload member begins inside that package (heap at
# 28+809=837, Payload at heap offset 13898801), so the installer reports it
# for any failure anywhere in the payload's 3.2 GB. See the Task 34 entry in
# NOTES.md. Nothing is known about WHERE such media is wrong -- only that it
# is, and that this is how to find out before an install does.
#
# THE FIRST VERSION OF THIS CHECK PASSED WHILE THE MEDIA WAS CORRUPT, and
# that is the more useful half of the finding. It compared source to
# destination through the same mount that had just written the file, so it
# read the page cache, not the disk. `7z t` on the same package, via a
# later mount, failed. Verification that shares a cache with the thing it
# is verifying is not verification.
#
# So the destination is checked AFTER the volume has been unmounted and
# the ownership pass has run, on a fresh mount, where the bytes have to
# come off the disk. That also covers the privops microVM, which the first
# version did not.
#
# AND IT IS CHECKED AGAINST A CONSTANT, NOT AGAINST THE SOURCE. Recording
# the source's checksums during the copy still cannot catch a source that
# was already wrong: a bad byte out of dmg2img would be copied faithfully,
# recorded as expected, and verified as correct. media/apple-packages.sha256
# is what Apple shipped, read from two images that share no code path, so
# the same check now names the conversion when the conversion is at fault
# and the copy when the copy is.
check_apple_packages() {
    local where=$1 what=$2
    log "checking $what against Apple's pinned checksums"
    # One implementation, in the script whose job is "is this what it
    # should be", so that the same check can be run by hand on any
    # Packages directory.
    "$MQG_REPO_ROOT/media/verify-installer-img.sh" --check-packages "$where"
}

check_esd_packages() {
    check_apple_packages "$1" "the ESD's Packages, as converted and read" \
        || die "the ESD does not contain what Apple shipped." \
               "The suspects are dmg2img and the Linux hfsplus read of" \
               "its output, in that order -- not the media, which has not" \
               "been written yet, and not media/apple-packages.sha256," \
               "whose values were read from two images that share no code."
}

verify_media_packages() {
    check_apple_packages "$1/System/Installation/Packages" \
        "the finished media, from a fresh mount" \
        || die "the media does not contain what Apple shipped." \
               "This is the fault that a finished rsync, and a read-back" \
               "through the same mount, both fail to report. Re-run with" \
               "--force. See the Task 34 entry in NOTES.md."
}

# The unattended-install hooks go on while the volume is already mounted
# here, rather than in a pass of their own. That is not only cheaper: the
# chown that follows (fix_media_ownership) is what makes them root-owned,
# and anything injected after it would be the one uid-1000 file on
# otherwise root-owned media -- exactly the state that made launchd say
# "Dubious ownership on file (skipping)" and load nothing at all.
inject_autoinstall() {
    local tgt=$1 src dst mode
    log "injecting the unattended-install hooks"
    while IFS='|' read -r src dst mode; do
        [ -n "$src" ] || continue
        [ -f "$MQG_REPO_ROOT/image/autoinstall/$src" ] \
            || die "missing image/autoinstall/$src"
        mkdir -p "$(dirname "$tgt/$dst")" || die "cannot create $(dirname "$dst")"
        cp "$MQG_REPO_ROOT/image/autoinstall/$src" "$tgt/$dst" \
            || die "cannot write $dst"
        chmod "$mode" "$tgt/$dst" || die "cannot chmod $mode $dst"
        log "  $dst ($(stat -c %a "$tgt/$dst"), $(stat -c %s "$tgt/$dst") bytes)"
    done <<< "$AUTOINSTALL_FILES"
    [ -z "$firstboot_pkg" ] || inject_firstboot "$tgt"
    [ "${#extra_pkgs[@]}" -eq 0 ] || inject_extra_pkgs "$tgt"
}

# Packages carried beside OSInstall.mpkg but deliberately absent from
# OSInstall.collection. They are installed later, by firstboot.sh, on the
# installed system -- see --extra-pkg in the usage above for why.
#
# They land in the same directory as the first-boot payload because that
# directory is what the payload's postinstall can find: the installer
# passes it the full path to the package it is running, so `dirname "$1"`
# is exactly here.
inject_extra_pkgs() {
    local tgt=$1 extra dst
    log "injecting ${#extra_pkgs[@]} extra package(s), not in the collection"
    for extra in ${extra_pkgs[@]+"${extra_pkgs[@]}"}; do
        dst="$tgt/System/Installation/Packages/$(basename "$extra")"
        cp "$extra" "$dst" || die "cannot write $dst"
        chmod 644 "$dst"
        log "  $(basename "$extra") ($(stat -c %s "$dst") bytes," \
            "sha256 $(sha256_file "$dst"))"
    done
}

# The first-boot payload, and the one extra line in OSInstall.collection
# that makes the installer install it.
#
# The collection is copied from the repository first (it is one of
# AUTOINSTALL_FILES) and then edited in place here, so image/autoinstall/
# stays the single source of truth for what the file says -- including the
# comment explaining why OSInstall.mpkg is listed twice, which is the kind
# of thing that gets deleted by whoever finds it next.
inject_firstboot() {
    local tgt=$1 dst collection entry
    dst="$tgt/System/Installation/Packages/$FIRSTBOOT_PKG_NAME"
    collection="$tgt/System/Installation/Packages/OSInstall.collection"
    entry="/System/Installation/Packages/$FIRSTBOOT_PKG_NAME"

    log "injecting the first-boot payload"
    cp "$firstboot_pkg" "$dst" || die "cannot write $dst"
    chmod 644 "$dst"
    log "  $FIRSTBOOT_PKG_NAME ($(stat -c %s "$dst") bytes," \
        "sha256 $(sha256_file "$dst"))"

    [ -f "$collection" ] || die "no OSInstall.collection to add the payload to"
    python3 - "$collection" "$entry" <<'PYEOF' || die "cannot edit $collection"
import plistlib
import sys

path, entry = sys.argv[1], sys.argv[2]
with open(path) as fh:
    text = fh.read()
# Textual insert, not a plistlib round-trip: rewriting the file would drop
# the comments, and one of them is the note that OSInstall.mpkg is listed
# twice on purpose. That note cost a boot to learn.
line = "\t<string>%s</string>\n" % entry
if line in text:
    sys.exit(0)
if "</array>" not in text:
    sys.exit("no </array> in %s" % path)
text = text.replace("</array>", line + "</array>", 1)
with open(path, "w") as fh:
    fh.write(text)
# And parse the result, because an unparseable collection fails the install
# with a modal dialog and nothing written to the target volume.
with open(path, "rb") as fh:
    packages = plistlib.load(fh)
if entry not in packages:
    sys.exit("%s is not in the collection after editing" % entry)
print("OSInstall.collection now lists %d package(s)" % len(packages))
PYEOF
    log "  collection: $(python3 -c '
import plistlib, sys
print(" ".join(plistlib.load(open(sys.argv[1], "rb"))))' "$collection")"
}

# Everything above ran unprivileged, so the media is owned by the building
# user and launchd would reject it. Fix that in a QEMU microVM, where we are
# genuinely root -- see lib/privops.sh for why that is the mechanism and
# what a different build host would substitute.
fix_media_ownership() {
    local img=$1
    log "restoring root ownership (privops backend: ${MQG_PRIVOPS_BACKEND:-qemu-linux})"
    privops_run "$img" "$MQG_REPO_ROOT/media/privops/fix-ownership.sh"
}


with_basesystem() {
    BS_MNT=$1
    log "BaseSystem volume mounted at $BS_MNT"
    count_tree "$BS_MNT" "BaseSystem source"

    log "creating $out: GPT, one AF00 partition, $PART_MIB MiB, \"$VOLUME_NAME\""
    hfs_create_gpt "$out" "$PART_MIB" "$VOLUME_NAME"
    hfs_with_mounted_part "$out" 1 populate_target
}

with_esd() {
    ESD_MNT=$1
    log "ESD volume mounted at $ESD_MNT"
    [ -f "$ESD_MNT/BaseSystem.dmg" ] \
        || die "no BaseSystem.dmg on the ESD volume at $ESD_MNT"
    log "converting BaseSystem.dmg to raw"
    dmg2img -s -i "$ESD_MNT/BaseSystem.dmg" -o "$bs_img" >/dev/null \
        || die "dmg2img failed on BaseSystem.dmg"
    log "BaseSystem raw image: $(stat -c %s "$bs_img") bytes"
    hfs_with_mounted_part "$bs_img" auto with_basesystem
}

started=$SECONDS
log "converting InstallESD.dmg to raw (about 5 GB)"
dmg2img -s -i "$esd_dmg" -o "$esd_img" >/dev/null \
    || die "dmg2img failed on $esd_dmg"
log "ESD raw image: $(stat -c %s "$esd_img") bytes"

hfs_with_mounted_part "$esd_img" auto with_esd

sync
fix_media_ownership "$out"

# On a fresh mount, after the ownership pass, so the bytes come off the
# disk rather than out of the cache that wrote them. See the comment above
# check_esd_packages.
hfs_with_mounted_part "$out" 1 verify_media_packages

log "checksumming $out"
# Ownership must be fixed BEFORE the checksum is taken: the microVM mounts
# the image, and mounting an HFS+ volume rewrites its header. Checksumming
# first would record a value that the very next step invalidates.
sum=$(sha256_file "$out")
# Recorded with its expiry date attached. udisks mounts HFS+ read-write,
# and the kernel updates the volume header's modify time and last-mounted
# version on the way in, so the first mount after this changes the file and
# the checksum stops matching. That is a property of the media, not a
# corruption, and someone running `sha256sum -c` at the wrong moment should
# find that written down rather than have to work it out. (sha256sum
# ignores lines beginning with #.)
{
    printf '# sha256 of %s as built at %s\n' \
        "$(basename "$out")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Mounting the image invalidates this: HFS+ records the mount\n'
    printf '# in its volume header, and udisks will only mount read-write.\n'
    printf '%s  %s\n' "$sum" "$(basename "$out")"
} > "$out.sha256"

if [ "$keep_work" -eq 0 ]; then
    log "removing the raw conversions (--keep-work keeps them)"
    rm -f "$esd_img" "$bs_img"
    rmdir "$work" 2>/dev/null || true
fi

log "built $out in $((SECONDS - started))s"
log "size $(stat -c %s "$out") bytes, sha256 $sum"
run_log "build-installer-img: $out $(stat -c %s "$out") bytes sha256=$sum" \
    "in $((SECONDS - started))s"
printf '%s\n' "$out"
