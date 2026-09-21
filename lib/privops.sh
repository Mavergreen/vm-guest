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
# two functions:
#
#   privops_run_<backend> <image> <script>   run <script> as root with
#       <image> attached, leaving the image cleanly unmounted.
#   privops_<backend>_missing                print one line per unmet
#       requirement on this host, and nothing at all when there is none.
#
# The second exists because "not available" is not a useful thing to tell
# somebody: on 2026-09-20 an EndeavourOS host finished a six-gigabyte media
# build and then stopped on a four-way && that reported one bit, and each
# guess at which of the four had failed cost a round trip to a machine
# nobody here can log in to. Requirements are now reported by name -- all
# of them, not just the first.
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

# privops_backend_missing <backend> -- what this host lacks, one
# requirement per line. Empty output means the backend can run here.
#
# THE REPORTING PATH IS SEPARATE FROM THE PREDICATE ON PURPOSE. A predicate
# that printed would print from every caller that only wanted to ask --
# privops_describe, a test, a future `--check` -- and a predicate with side
# effects is its own bug. So the knowledge lives here, callers decide
# whether to show it, and privops_backend_available stays silent.
privops_backend_missing() {
    local fn
    # Backend names are hyphenated for readability; function names cannot
    # be. Same translation as the dispatch below.
    fn="privops_${1//-/_}_missing"
    if declare -f "$fn" >/dev/null 2>&1; then
        "$fn"
    else
        printf "a backend named '%s' (no such backend is loaded)\n" "$1"
    fi
}

# privops_backend_available <backend> -- true if this host can run it.
# Silent: it answers, it does not report. Use privops_backend_missing for
# the reason.
privops_backend_available() {
    [ -z "$(privops_backend_missing "$1")" ]
}

privops_describe() {
    local missing
    printf 'backend: %s\n' "$MQG_PRIVOPS_BACKEND"
    missing=$(privops_backend_missing "$MQG_PRIVOPS_BACKEND")
    if [ -z "$missing" ]; then
        printf 'available: yes\n'
    else
        printf 'available: no\n'
        printf '%s\n' "$missing" | sed 's/^/missing: /'
    fi
}

# privops_run <image> <script-file> [ro:<image> | raw:<image>]...
#
# Runs <script-file> as root with <image> attached read-write, via the
# selected backend. Any further images are attached after it: `ro:` ones
# are mounted read-only and handed to the script as $MQG_SRC1, $MQG_SRC2,
# ...; `raw:` ones are handed over as block devices ($MQG_RAW1, ...) and
# not mounted, which is how a payload hands a file back to the host.
#
# That is what lets the WHOLE of the HFS+ assembly happen in here rather
# than only the ownership pass: see the G26 row in docs/host-profile.md,
# and media/build-installer-img.sh, which no longer attaches a loop device
# or mounts anything on the host.
privops_run() {
    local img=$1 script=$2
    shift 2
    local missing m n
    [ -f "$img" ] || die "no such image: $img"
    [ -f "$script" ] || die "no such script: $script"
    # Report every unmet requirement before dying, so that one run of the
    # build tells the whole story. A message naming one of four missing
    # things costs a round trip per guess.
    missing=$(privops_backend_missing "$MQG_PRIVOPS_BACKEND")
    if [ -n "$missing" ]; then
        printf '%s\n' "$missing" | while IFS= read -r m; do
            warn "  missing: $m"
        done
        n=$(printf '%s\n' "$missing" | wc -l | tr -d ' ')
        die "privops backend '$MQG_PRIVOPS_BACKEND' is not available on" \
            "this host: $n requirement(s) above are unmet. Nothing here" \
            "installs anything -- see boot/prereqs.sh and docs/host-profile.md"
    fi
    # Backend names are hyphenated for readability; shell function names
    # cannot be, so translate on dispatch.
    "privops_run_${MQG_PRIVOPS_BACKEND//-/_}" "$img" "$script" ${@+"$@"}
}
