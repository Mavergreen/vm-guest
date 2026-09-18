# shellcheck shell=bash
# Privileged filesystem operations, performed without host privilege.
#
# THE PROBLEM
#
# Building macOS installer media needs files owned by root: launchd refuses
# to load any daemon from a directory it does not trust, and says so --
# "Dubious ownership on file (skipping): /System/Library/LaunchDaemons",
# followed by "nothing found to load". The guest then boots to a stall.
#
# On Linux, an unprivileged user cannot produce that. udisks2 mounts HFS+
# with uid=/gid= options that override on-disk ownership, so even chown
# through such a mount cannot help, and hfsprogs offers no way to populate
# a filesystem image offline -- there is no HFS+ equivalent of NetBSD's
# makefs, mke2fs -d, or mksquashfs -pf.
#
# THE APPROACH
#
# Do the privileged work inside a VM, where we are genuinely root, and give
# that VM the image as a block device. This is the same trick libguestfs,
# anylinuxfs and smolBSD each wrap; we implement it directly because this
# project already depends on QEMU and already pins it, so it costs no new
# dependency and works anywhere QEMU does.
#
# THE SEAM
#
# MQG_PRIVOPS_BACKEND selects the technique. Each backend must provide
# privops_run_<backend> <image> <script>, running <script> as root with
# <image> attached, and leaving the image cleanly unmounted.
#
#   qemu-linux  (default)  A busybox initramfs booted under QEMU with the
#                          host's own kernel. Needs: a readable kernel,
#                          static busybox, cpio, and hfsplus/nls_utf8
#                          modules. Verified on Linux.
#
# Backends that would suit other image-build hosts, none implemented:
#
#   macos-native   On a Mac there is no problem to solve: hdiutil and the
#                  native HFS+ driver honour ownership, and `get.sh` already
#                  builds media this way. A backend here would simply shell
#                  out to hdiutil. This is why P4 exists only for the no-Mac
#                  case.
#   linux-sudo     mount -o loop as root, honouring on-disk ownership.
#                  Simplest, but a standing privilege requirement on every
#                  build host.
#   libguestfs     guestfish/virt-make-fs. Same VM trick, packaged. Linux
#                  only, so it cannot serve a macOS or NetBSD build host.
#   netbsd-makefs  NetBSD builds whole releases unprivileged by recording
#                  intent in a METALOG and having makefs write the
#                  filesystem directly. The right shape, but makefs has no
#                  HFS+ writer.
#
# Requires lib/common.sh.

MQG_PRIVOPS_BACKEND=${MQG_PRIVOPS_BACKEND:-qemu-linux}

# privops_backend_available <backend> -- true if this host can run it.
privops_backend_available() {
    case $1 in
        qemu-linux)
            command -v qemu-system-x86_64 >/dev/null 2>&1 &&
            command -v busybox >/dev/null 2>&1 &&
            command -v cpio >/dev/null 2>&1 &&
            [ -r "/boot/vmlinuz-$(uname -r)" ]
            ;;
        *) return 1 ;;
    esac
}

privops_describe() {
    printf 'backend: %s\n' "$MQG_PRIVOPS_BACKEND"
    if privops_backend_available "$MQG_PRIVOPS_BACKEND"; then
        printf 'available: yes\n'
    else
        printf 'available: no\n'
    fi
}

# privops_run <image> <script-file>
# Runs <script-file> as root with <image> attached, via the selected backend.
privops_run() {
    local img=$1 script=$2
    [ -f "$img" ] || die "no such image: $img"
    [ -f "$script" ] || die "no such script: $script"
    privops_backend_available "$MQG_PRIVOPS_BACKEND" \
        || die "privops backend '$MQG_PRIVOPS_BACKEND' is not available on this host"
    # Backend names are hyphenated for readability; shell function names
    # cannot be, so translate on dispatch.
    "privops_run_${MQG_PRIVOPS_BACKEND//-/_}" "$img" "$script"
}
