#!/usr/bin/env bash
# Build bootable Mavericks installer media on Linux, from Apple's own
# InstallESD.dmg, with no Mac and no root.
#
# The recipe is eprigorodov/mkosxinstallusb's, with two changes: it targets
# an image file rather than /dev/sdX, and every privileged step has an
# unprivileged equivalent (see lib/hfs.sh and the P4 entries in NOTES.md).
# What comes out is what the Mac-produced reference ISO contains --
# media/verify-installer-img.sh is how we find out whether that is true,
# and a finished copy on its own proves nothing.
#
#   1. dmg2img InstallESD.dmg.
#   2. Create a GPT image with one AF00 partition holding an "OS X Base
#      System" volume, sized from the reference.
#   3. In a microVM: copy the ESD's BaseSystem.dmg onto a raw disk, since
#      dmg2img runs here and cannot read an HFS+ volume. dmg2img it.
#   4. In a microVM: copy BaseSystem onto the target volume, replace
#      System/Installation/Packages -- a symlink into the ESD volume,
#      dangling on media that has no ESD volume -- with the ESD's real
#      Packages directory, add BaseSystem.chunklist and BaseSystem.dmg,
#      which the installer verifies the packages against, and untar
#      whatever --autoinstall staged.
#   5. In a microVM: restore root ownership (media/privops/fix-ownership.sh).
#   6. In a microVM of its own: read the finished Packages back and check
#      them against media/apple-packages.sha256.
#
# NOTHING HERE MOUNTS ANYTHING, and that is the point of the shape.
#
# It used to: udisks2 attached a loop device and mounted the volumes under
# /run/media/$USER. That needs a desktop seat -- polkit refuses loop-setup
# to an SSH session with `NotAuthorizedCanObtain` -- so the build could not
# run on a headless host at all, which is every CI runner and was the
# machine this project actually wanted to build on. See G26 in
# docs/host-profile.md. It also put file-browser windows and notification
# popups on the screen of anyone who did have a seat, because
# /run/media/$USER is exactly where desktop handlers look.
#
# Ownership: the copy now runs as uid 0 against volumes mounted without
# uid=/gid= overrides, so on-disk ownership and setuid bits survive it --
# neither of which was on offer through a udisks mount whatever flags rsync
# was given. fix-ownership.sh still runs, still records the six setuid and
# setgid files before the chown that would strip them, and still restores
# them afterwards.
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
# 512 RATHER THAN 128, AND THIS IS NOT WHY THE CORRUPTION STOPPED.
#
# Raised from 128 on 2026-09-18, on the theory that the file which arrived
# corrupt was always the largest and was being written into a volume that
# 128 MiB of margin left 99% full. **That reason is false.** rsync copies
# Packages in sorted order, so Essentials.pkg is the seventh of sixteen: it
# starts at 33.4% of the volume and its last byte lands at 83.6%, with 1.05
# GiB still free even at 128 MiB of margin. The volume reaches 99% about a
# gigabyte of copying later, by which time the file is long written. And
# the corruption was never in one place -- two failing builds broke 110 MB
# and 1.99 GB into the same file. See the Task 34 entry in NOTES.md, which
# concludes the cause was concurrent access to the image file.
#
# So the margin is UNPROVEN as a mitigation and known to be irrelevant to
# the mechanism the evidence supports. It stays because it costs nothing --
# the image is sparse and this is a QEMU disk, not a USB stick someone has
# to buy -- and because shrinking it would be a change made for no reason
# in the other direction. Do not cite it as a fix for anything.
#
# Overridable so the margin can be varied without editing this file.
MARGIN_MIB=${MQG_MEDIA_MARGIN_MIB:-512}
BASE_PART_MIB=$(( (REFERENCE_PARTITION_BYTES + 1048575) / 1048576 + MARGIN_MIB ))

# ...and --extra-space-mib on top, for cargo nobody had measured when the
# margin above was chosen.
#
# THE MARGIN IS NOT SPARE ROOM. It was measured against this media as it is
# built today, ESD contents and OpenSSH included, and what it leaves is
# 483.8 MiB free -- read out of the HFS+ volume header of the media sitting
# on disk on 2026-09-22, not estimated. Security Update 2016-004 alone is
# 353.8 MiB and `--updates all` is 685 MiB, so carrying updates inside the
# existing margin would mean eating it whole and then overflowing.
#
# So the caller says how much room its extra cargo needs, and this stays
# EXACTLY the old number when nothing extra is carried. `--updates none` has
# to be bit-for-bit what it was -- P5 measures against it -- and a formula
# that quietly grew the partition on every build would have changed the one
# thing that must not change.
extra_space_mib=0
PART_MIB=$BASE_PART_MIB

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
  --extra-space-mib N
                 Enlarge the HFS+ partition by N MiB beyond the measured
                 reference-plus-margin size, for extra packages the margin
                 was never sized for. Default 0, which reproduces today's
                 partition geometry exactly. image/build-image.sh passes
                 the size of the --updates packages plus slack.
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
        --extra-space-mib) extra_space_mib=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

case $extra_space_mib in
    ''|*[!0-9]*) die "--extra-space-mib wants a whole number of MiB," \
                     "not '$extra_space_mib'" ;;
esac
PART_MIB=$(( BASE_PART_MIB + extra_space_mib ))

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
media_dir=$MQG_IMAGE_DIR/media
esd_dmg=$media_dir/InstallESD.dmg
out=$media_dir/installer-linux.img
work=${MQG_MEDIA_WORK_DIR:-$media_dir/work}
esd_img=$work/esd.img
bs_img=$work/basesystem.img
# The raw disk the microVM writes the ESD's BaseSystem.dmg onto, and the
# tar of files to inject that goes the other way. Both are plain files
# here and block devices in the guest: that is the only channel between
# the two now that this host mounts nothing.
bs_dmg=$work/basesystem.dmg
inject_tar=$work/inject.tar
inject_list=$work/inject.list

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
                      for the larger catalog a Linux-built copy needs,
                      plus $extra_space_mib MiB of --extra-space-mib)
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

require_cmd dmg2img sgdisk truncate dd mkfs.hfsplus tar sha256sum awk

# NOT udisksctl, losetup, findmnt, lsblk or rsync any more. This script
# attaches no loop device and mounts nothing: every read and write of an
# HFS+ volume happens inside the privops microVM. See the G26 row in
# docs/host-profile.md for why that had to change -- udisks2's polkit
# policy grants loop-setup to a user AT A SEAT, so the old path could not
# run over SSH on any headless host, including a CI runner.
#
# Asked here, before five gigabytes of dmg2img, rather than at the moment
# the microVM is first needed. A host that cannot boot it should find that
# out in a second and by name, not after twenty minutes of work it will
# have to throw away -- which is exactly what happened on squirrel-zapper
# when the backend was only checked at the end.
media_missing=$(privops_backend_missing "$MQG_PRIVOPS_BACKEND")
if [ -n "$media_missing" ]; then
    printf '%s\n' "$media_missing" | while IFS= read -r m; do
        warn "  missing: $m"
    done
    die "the privops backend '$MQG_PRIVOPS_BACKEND' is not available on" \
        "this host, and it is now how the media is built at all -- not" \
        "merely how ownership is fixed at the end. Nothing here installs" \
        "anything: see boot/prereqs.sh and docs/host-profile.md"
fi

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

# ONE BUILDER PER IMAGE FILE.
#
# The media corruption in P4 has exactly one mechanism that was ever caught
# in the act: an orphaned media/build-installer-img.sh, left running when
# image/build-image.sh was killed (its cleanup trap kills QEMU and nothing
# else), still rsyncing into the image a newer build had started writing.
#
# Two builders is not "the file gets whichever bytes arrive last". Each one
# attaches its OWN loop device to the same backing file, so each has its own
# block-device page cache over the same bytes. Every builder then reads back
# exactly what it wrote -- its own cache -- while the file on disk ends up a
# mix of both. That is also why a verification done through the writing
# mount passed on media that was corrupt.
#
# So: refuse, loudly, rather than produce media nobody can trust. The lock
# is a directory and a pid rather than flock(1), which OS X does not have
# and this project's host-side scripts are meant to run there (see the bash
# 3.2 entry in NOTES.md). A lock whose holder is gone is stale, and is taken
# over rather than left to block the next build forever.
media_lock=$out.lock
acquire_media_lock() {
    local holder
    if ! mkdir "$media_lock" 2>/dev/null; then
        holder=$(cat "$media_lock/pid" 2>/dev/null || true)
        if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
            die "pid $holder is already building $out." \
                "Two builders sharing one image file corrupt it, and each" \
                "of them verifies its own page cache and sees nothing" \
                "wrong. Wait for it, or kill it and remove $media_lock."
        fi
        warn "taking over a stale lock left by pid ${holder:-unknown}"
        rm -rf "$media_lock" || die "cannot remove the stale lock $media_lock"
        mkdir "$media_lock" 2>/dev/null \
            || die "cannot create the lock directory $media_lock"
    fi
    printf '%s\n' "$$" > "$media_lock/pid"
    trap 'rm -rf "$media_lock"' EXIT INT TERM
}
acquire_media_lock

if [ -e "$out" ]; then
    [ "$force" -eq 1 ] || die "$out exists; pass --force to replace it"
    log "--force: removing the existing $out"
    rm -f "$out" "$out.sha256"
fi

mkdir -p "$work" || die "cannot create $work"

# Intermediates are regenerated every run rather than reused. They are
# cheap (seconds) next to a stale or half-written one silently becoming the
# media we then spend an hour booting.
rm -f "$esd_img" "$bs_img" "$bs_dmg" "$inject_tar" "$inject_list" \
   "$out.hfs-tmp"

# The microVM passes. Each of these boots the privops backend, does one
# job as uid 0, and leaves the image cleanly unmounted; the host attaches
# no loop device and mounts nothing at any point.
#
#   1. extract   the ESD's BaseSystem.dmg onto a raw disk, because dmg2img
#                runs here and cannot read an HFS+ volume
#   2. assemble  the whole media: BaseSystem, Packages, the injectables
#   3. ownership  media/privops/fix-ownership.sh, unchanged
#   4. verify    read the finished media back in a microVM of its own
#
# Four boots rather than one. Each costs about four seconds, which is the
# price of the host not needing a desktop seat.

# The console is the only channel out of the guest. privops_run copies it
# to MQG_PRIVOPS_CONSOLE when asked, and the markers this build reads are
# MQG-BASESYSTEM-BYTES, MQG-BASESYSTEM-SHA256, MQG-SUM-ESD and
# MQG-SUM-MEDIA. `tr -d` strips the carriage returns a serial console
# leaves on every line.
privops_console=$work/privops-console.txt
console_marker() {
    sed -n "s/^$1 //p" "$privops_console" | tr -d '\r'
}

# Pass 1. The media's root filesystem is the contents of BaseSystem.dmg,
# which lives inside the ESD volume and is UDIF-compressed -- only dmg2img
# can decode it, dmg2img runs here, and here cannot read the ESD.
#
# So the guest writes that one file to a raw disk, which on this side is a
# plain file. The target image is attached because the backend always
# mounts its first disk; this pass does not write to it.
extract_basesystem() {
    local bytes want got
    log "bringing BaseSystem.dmg out of the ESD (microVM pass 1 of 4)"
    # Sparse, and as large as the whole ESD image: the real file is about
    # 470 MB and this costs nothing until it is written to.
    rm -f "$bs_dmg"
    truncate -s "$(stat -c %s "$esd_img")" "$bs_dmg" \
        || die "cannot create $bs_dmg"
    MQG_PRIVOPS_CONSOLE=$privops_console \
        privops_run "$out" "$MQG_REPO_ROOT/media/privops/extract-basesystem.sh" \
            "ro:$esd_img" "raw:$bs_dmg"
    bytes=$(console_marker MQG-BASESYSTEM-BYTES)
    want=$(console_marker MQG-BASESYSTEM-SHA256)
    case $bytes in
        ''|*[!0-9]*) die "the microVM did not report a BaseSystem.dmg size" ;;
    esac
    truncate -s "$bytes" "$bs_dmg" || die "cannot truncate $bs_dmg"
    # The host's own read of the file, against the digest the guest sent.
    # A short or torn write through the raw disk would otherwise surface
    # as a dmg2img failure that says nothing about where the bytes went.
    got=$(sha256_file "$bs_dmg")
    [ "$got" = "$want" ] \
        || die "BaseSystem.dmg did not survive the trip out of the microVM:" \
               "the guest read $want and this host reads $got"
    log "BaseSystem.dmg: $bytes bytes, sha256 $got"
}

# Pass 2. Everything the media is made of, copied volume to volume by a
# process that is genuinely root.
assemble_media() {
    local -a disks=( "ro:$bs_img" "ro:$esd_img" )
    [ ! -f "$inject_tar" ] || disks+=( "raw:$inject_tar" )
    log "assembling the media inside the microVM (pass 2 of 4)"
    MQG_PRIVOPS_CONSOLE=$privops_console \
        privops_run "$out" "$MQG_REPO_ROOT/media/privops/assemble.sh" \
            "${disks[@]}"
    check_esd_packages
}

# WHY THESE CHECKS EXIST: A FINISHED COPY PROVES NOTHING, AND NEITHER DOES
# READING BACK WHAT YOU JUST WROTE.
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
# So the media is read back in A MICROVM OF ITS OWN, booted after the one
# that did the writing has exited: a fresh kernel with no page cache at
# all, pulling every byte through virtio off this host's file. That is
# more than the old fresh-mount check promised, not less, which matters
# because the mount it used to be fresh *of* is gone.
#
# AND IT IS CHECKED AGAINST A CONSTANT, NOT AGAINST THE SOURCE. Recording
# the source's checksums during the copy still cannot catch a source that
# was already wrong: a bad byte out of dmg2img would be copied faithfully,
# recorded as expected, and verified as correct. media/apple-packages.sha256
# is what Apple shipped, read from two images that share no code path, so
# the same check now names the conversion when the conversion is at fault
# and the copy when the copy is.
check_apple_sums() {
    local what=$2
    log "checking $what against Apple's pinned checksums"
    # One implementation, in the script whose job is "is this what it
    # should be", so that the same comparison can be run by hand.
    console_marker "$1" > "$work/sums.txt"
    "$MQG_REPO_ROOT/media/verify-installer-img.sh" --check-sums "$work/sums.txt"
}

check_esd_packages() {
    check_apple_sums MQG-SUM-ESD "the ESD's Packages, as converted and read" \
        || die "the ESD does not contain what Apple shipped." \
               "The suspects are dmg2img and the Linux hfsplus read of" \
               "its output, in that order -- not the media, whose copy of" \
               "them has not been checked yet, and not" \
               "media/apple-packages.sha256, whose values were read from" \
               "two images that share no code."
}

verify_media_packages() {
    log "reading the finished media back in a microVM of its own (pass 4 of 4)"
    MQG_PRIVOPS_CONSOLE=$privops_console \
        privops_run "$1" "$MQG_REPO_ROOT/media/privops/verify-packages.sh"
    check_apple_sums MQG-SUM-MEDIA "the finished media, read by a fresh guest" \
        || die "the media does not contain what Apple shipped." \
               "This is the fault that a finished copy, and a read-back" \
               "through the same cache, both fail to report. Re-run with" \
               "--force. See the Task 34 entry in NOTES.md."
}

# The unattended-install hooks and any packages this build carries.
#
# They are assembled into a staging DIRECTORY here, named for where they go
# on the media, and handed to the microVM as a tar on a raw disk -- the
# same channel BaseSystem.dmg comes back out on, run the other way. The
# guest untars it straight onto the volume, so nothing but the tar is ever
# held in the initramfs, which is RAM: the OpenSSH packages alone are
# twelve megabytes.
#
# The guest does this BEFORE the ownership pass, deliberately. The chown is
# what makes these root-owned, and anything injected after it would be the
# one uid-1000 file on otherwise root-owned media -- exactly the state that
# made launchd say "Dubious ownership on file (skipping)" and load nothing
# at all.
#
# The functions below take a directory and write files into it, which is
# what they did when that directory was a mountpoint. Only the caller
# changed.
stage_injectables() {
    local stage=$1
    [ "$autoinstall" -eq 1 ] || return 0
    rm -rf "$stage" || die "cannot clear $stage"
    mkdir -p "$stage" || die "cannot create $stage"
    inject_autoinstall "$stage"
    # FILES ONLY, NO DIRECTORY ENTRIES, and that is not a tidiness
    # preference. A directory entry in a tar sets the mode of the
    # directory it lands on, and these paths land on directories that
    # already exist: System, System/Installation, private, private/etc.
    # Archiving them carried this host's umask onto Apple's media and made
    # five of its directories group-writable -- caught by
    # verify-installer-img.sh against the Mac-produced reference, which is
    # exactly the drift that comparison exists to find. Without them, tar
    # creates only what is genuinely missing and leaves the rest alone.
    #
    # No --owner/--group either: they are spelled differently by GNU tar
    # and by the bsdtar an OS X host has, and they would buy nothing. The
    # ownership pass chowns the whole volume afterwards.
    ( cd "$stage" && find . ! -type d | sed 's|^\./||' ) > "$inject_list" \
        || die "cannot list $stage"
    tar cf "$inject_tar" -C "$stage" -T "$inject_list" \
        || die "cannot build $inject_tar"
    log "staged $(stat -c %s "$inject_tar") bytes of files to inject"
}

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
    log "restoring root ownership (microVM pass 3 of 4)"
    privops_run "$img" "$MQG_REPO_ROOT/media/privops/fix-ownership.sh"
}

started=$SECONDS
log "converting InstallESD.dmg to raw (about 5 GB)"
dmg2img -s -i "$esd_dmg" -o "$esd_img" >/dev/null \
    || die "dmg2img failed on $esd_dmg"
log "ESD raw image: $(stat -c %s "$esd_img") bytes"

# Created before anything is copied, because pass 1 needs a target to
# attach: the backend always mounts its first disk, and an empty volume is
# a perfectly good thing for it to mount while the guest reads the ESD.
log "creating $out: GPT, one AF00 partition, $PART_MIB MiB, \"$VOLUME_NAME\""
hfs_create_gpt "$out" "$PART_MIB" "$VOLUME_NAME"

extract_basesystem

log "converting BaseSystem.dmg to raw"
dmg2img -s -i "$bs_dmg" -o "$bs_img" >/dev/null \
    || die "dmg2img failed on BaseSystem.dmg"
log "BaseSystem raw image: $(stat -c %s "$bs_img") bytes"

stage_injectables "$work/inject"
assemble_media

sync
fix_media_ownership "$out"

# In a microVM of its own, booted after the writing one exited, so the
# bytes come off the disk rather than out of the cache that wrote them.
# See the comment above check_apple_sums.
verify_media_packages "$out"

log "checksumming $out"
# Ownership must be fixed BEFORE the checksum is taken: the microVM mounts
# the image, and mounting an HFS+ volume rewrites its header. Checksumming
# first would record a value that the very next step invalidates.
sum=$(sha256_file "$out")
# Recorded with its expiry date attached. The kernel updates the volume
# header's modify time and last-mounted version on the way into a
# read-write mount, so the first mount after this -- by a microVM, a guest
# booting the media, anything -- changes the file and the checksum stops
# matching. That is a property of the media, not a
# corruption, and someone running `sha256sum -c` at the wrong moment should
# find that written down rather than have to work it out. (sha256sum
# ignores lines beginning with #.)
{
    printf '# sha256 of %s as built at %s\n' \
        "$(basename "$out")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Mounting the image invalidates this: HFS+ records the mount\n'
    printf '# in its volume header, and a read-write mount rewrites it.\n'
    printf '%s  %s\n' "$sum" "$(basename "$out")"
} > "$out.sha256"

if [ "$keep_work" -eq 0 ]; then
    log "removing the raw conversions (--keep-work keeps them)"
    rm -f "$esd_img" "$bs_img" "$bs_dmg" "$inject_tar" "$inject_list" \
        "$work/sums.txt" "$privops_console"
    rm -rf "$work/inject"
    rmdir "$work" 2>/dev/null || true
fi

log "built $out in $((SECONDS - started))s"
log "size $(stat -c %s "$out") bytes, sha256 $sum"
run_log "build-installer-img: $out $(stat -c %s "$out") bytes sha256=$sum" \
    "in $((SECONDS - started))s"
printf '%s\n' "$out"
