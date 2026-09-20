# shellcheck shell=bash
# privops backend: a busybox initramfs booted under QEMU, on Linux.
#
# Builds a ~1.2 MB initramfs around the host's static busybox, boots it with
# the host's own kernel, attaches the target image as /dev/vda, and runs the
# caller's script as uid 0.
#
# Four things here are load-bearing and each cost a failed attempt to find:
#
#   1. Applets are invoked as `busybox <applet>`, never through the symlinks
#      `busybox --install` creates. Those symlinks did not resolve inside
#      the initramfs, so EVERY command returned rc=127 -- which looks
#      exactly like a missing device rather than a missing shell.
#   2. devtmpfs must be mounted or /dev/vda does not exist.
#   3. nls_utf8.ko must be loaded or the mount fails with
#      "hfsplus: unable to load nls for utf8".
#   4. virtio_blk and virtio_pci happen to be built into this kernel. A
#      kernel with them as modules would need them staged too, so the
#      module list is a variable rather than a constant.
#
# A fifth, found on 2026-09-20 on an EndeavourOS host: the kernel image is
# NOT at /boot/vmlinuz-$(uname -r) everywhere. Arch installs it as
# /boot/vmlinuz-linux. See privops_qemu_linux_kernel below.
#
# Requires lib/common.sh.

MQG_PRIVOPS_MODULES=${MQG_PRIVOPS_MODULES:-nls_base nls_utf8 hfsplus}

# Where to look for a kernel and its modules, and which kernel release to
# look for. All three are variables so the search can be pointed at a
# fixture directory: reading /boot directly would make kernel discovery
# testable only on a host that already names its kernel the way the test
# expects -- which is the assumption that broke here in the first place.
# Same reasoning as MQG_PKG_MANAGER in boot/prereqs.sh.
MQG_PRIVOPS_BOOT_DIR=${MQG_PRIVOPS_BOOT_DIR:-/boot}
MQG_PRIVOPS_MODULES_DIR=${MQG_PRIVOPS_MODULES_DIR:-/lib/modules}
MQG_PRIVOPS_KVER=${MQG_PRIVOPS_KVER:-$(uname -r)}

# Every path a kernel image might be at, most specific first.
#
# THE FIRST THREE ARE KEYED TO THE RUNNING KERNEL AND THE REST ARE NOT, and
# that ordering is the point, not cosmetics. The initramfs stages modules
# out of $MQG_PRIVOPS_MODULES_DIR/$MQG_PRIVOPS_KVER. Boot a kernel of a
# different version with them and insmod rejects every one on version
# magic, so hfsplus never loads, the mount fails, and the console says
# "MQG-PRIVOPS-MOUNT-FAILED" without a word about why. That is a far worse
# failure than the clean "not available" this backend used to give, so a
# version-keyed path wins over a generic one even when both exist.
#
#   vmlinuz-<release>             Debian, Ubuntu, Mint, Fedora, openSUSE
#   <modules>/<release>/vmlinuz   Arch's linux package puts a copy here,
#                                 and the path carries the version, so it
#                                 cannot be the wrong kernel
#   kernel-<release>              Gentoo
#   vmlinuz-linux                 Arch's /boot name -- generic
#   vmlinuz                       Alpine, and a common symlink elsewhere
#   kernel-*                      Gentoo, when the release does not match
#
# Only the first path has ever been exercised here: this project's hosts
# are Debian-family. The rest are what those distributions document. See
# NOTES.md for which are still untested.
privops_qemu_linux_kernel_candidates() {
    printf '%s\n' \
        "$MQG_PRIVOPS_BOOT_DIR/vmlinuz-$MQG_PRIVOPS_KVER" \
        "$MQG_PRIVOPS_MODULES_DIR/$MQG_PRIVOPS_KVER/vmlinuz" \
        "$MQG_PRIVOPS_BOOT_DIR/kernel-$MQG_PRIVOPS_KVER" \
        "$MQG_PRIVOPS_BOOT_DIR/vmlinuz-linux" \
        "$MQG_PRIVOPS_BOOT_DIR/vmlinuz" \
        "$MQG_PRIVOPS_BOOT_DIR"/kernel-*
}

# privops_qemu_linux_kernel -- print the kernel image to boot; fail (and
# print nothing) if there is none. Silent, so it can be used as a test.
privops_qemu_linux_kernel() {
    local c found=
    # Fed by a here-document rather than a pipe, so the assignment happens
    # in this shell and not in a subshell of it.
    while IFS= read -r c; do
        [ -n "$found" ] && continue
        [ -f "$c" ] && [ -r "$c" ] && found=$c
    done <<EOF
$(privops_qemu_linux_kernel_candidates)
EOF
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

# True when the path found is one the running kernel's modules will load
# into. A generic name may well be the running kernel -- on a host with one
# kernel installed it always is -- so this decides whether to WARN, not
# whether to proceed.
privops_qemu_linux_kernel_is_keyed() {
    case $1 in
        "$MQG_PRIVOPS_BOOT_DIR/vmlinuz-$MQG_PRIVOPS_KVER") return 0 ;;
        "$MQG_PRIVOPS_MODULES_DIR/$MQG_PRIVOPS_KVER/vmlinuz") return 0 ;;
        "$MQG_PRIVOPS_BOOT_DIR/kernel-$MQG_PRIVOPS_KVER") return 0 ;;
    esac
    return 1
}

# Is a busybox safe to drop into an initramfs? The one this backend builds
# holds a single binary and nothing else: no shared libraries, no dynamic
# loader, no /lib at all. A DYNAMICALLY LINKED BUSYBOX PASSES EVERY CHECK
# WE HAD -- it is on PATH, it copies fine, the cpio archive is well formed
# -- and then the kernel cannot exec /init inside the microVM, which
# surfaces as a panic with no mention of busybox. Debian ships the two
# variants as separate packages (`busybox` dynamic, `busybox-static`
# static), so this is luck-of-packaging until something checks.
#
# WHY ldd AND NOT file. Both can answer. `file` is a separate package that
# a host need not have and that this project does not require; ldd is
# installed by the C library itself -- glibc and musl both ship one -- so
# on any host that has a dynamic loader to worry about, ldd is there. The
# answer is read from ldd's OUTPUT, not its exit status, because glibc's
# ldd exits non-zero both for a static binary and for a file it cannot
# make sense of, and those two must not be confused.
#
# Prints static, dynamic, or unknown. Unknown is reported as nothing
# missing: refusing to build on a guess would be a worse failure than the
# one this catches.
privops_qemu_linux_busybox_linkage() {
    local out
    command -v ldd >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
    out=$(ldd "$1" 2>&1)
    case $out in
        *'not a dynamic executable'*|*'Not a valid dynamic program'*|*'statically linked'*)
            printf 'static\n' ;;
        *'=>'*|*ld-linux*|*ld-musl*)
            printf 'dynamic\n' ;;
        *)  printf 'unknown\n' ;;
    esac
}

# privops_qemu_linux_missing -- one line per unmet requirement, and no
# output at all when this host can run the backend. lib/privops.sh turns
# this into both the silent predicate and the report; see the seam comment
# there for why the predicate does not print.
privops_qemu_linux_missing() {
    local t bb
    for t in qemu-system-x86_64 cpio; do
        command -v "$t" >/dev/null 2>&1 \
            || printf '%s (not on PATH)\n' "$t"
    done
    bb=$(command -v busybox 2>/dev/null) || bb=
    if [ -z "$bb" ]; then
        printf 'busybox (not on PATH)\n'
    elif [ "$(privops_qemu_linux_busybox_linkage "$bb")" = dynamic ]; then
        # Named as a different requirement from a missing busybox, because
        # "install busybox" is the wrong advice to a reader who has one.
        printf 'a statically linked busybox: %s is dynamically linked, and the initramfs has no loader or libraries for it (Debian: busybox-static)\n' "$bb"
    fi
    privops_qemu_linux_kernel >/dev/null 2>&1 \
        || printf 'a readable kernel image for %s (looked for: %s)\n' \
            "$MQG_PRIVOPS_KVER" \
            "$(privops_qemu_linux_kernel_candidates | tr '\n' ' ' | sed 's/ $//')"
}

privops_qemu_linux_build_initramfs() {
    local out=$1 kver staged root
    kver=$MQG_PRIVOPS_KVER
    root=$(mktemp -d)
    mkdir -p "$root"/{bin,dev,proc,sys,mnt,lib/modules}
    cp "$(command -v busybox)" "$root/bin/busybox" || die "cannot stage busybox"

    # Modules are matched as $m.ko* and DECOMPRESSED while staging, because
    # busybox insmod reads none of the compressed formats.
    #
    # Arch ships hfsplus.ko.zst; Debian ships hfsplus.ko. The old glob was
    # `-name "$m.ko"` exactly, so on Arch find matched nothing, the `&&`
    # skipped the copy without a word, insmod found no file, and the HFS+
    # mount failed with MQG-PRIVOPS-MOUNT-FAILED and no hint as to why.
    # Third Debian-shaped assumption in this file, after the kernel path
    # and the busybox linkage.
    #
    # A module we cannot stage is now FATAL rather than skipped. The whole
    # purpose of this microVM is mounting HFS+; proceeding without hfsplus
    # guarantees a failure several steps later that says nothing about the
    # cause.
    for m in $MQG_PRIVOPS_MODULES; do
        staged=$(find "$MQG_PRIVOPS_MODULES_DIR/$kver" \
            \( -name "$m.ko" -o -name "$m.ko.zst" -o -name "$m.ko.xz" \
               -o -name "$m.ko.gz" \) -print -quit 2>/dev/null)
        if [ -z "$staged" ]; then
            # Built into the kernel rather than a module is legitimate and
            # common; there is nothing to stage and insmod is not needed.
            # Distinguished from "we could not read it", which is not.
            warn "no $m module under $MQG_PRIVOPS_MODULES_DIR/$kver" \
                 "-- assuming it is built into the kernel"
            continue
        fi
        case $staged in
            *.zst)
                command -v zstd >/dev/null 2>&1 \
                    || die "$staged is zstd-compressed and zstd is not installed"
                zstd -dqf "$staged" -o "$root/lib/modules/$m.ko" \
                    || die "cannot decompress $staged" ;;
            *.xz)
                command -v xz >/dev/null 2>&1 \
                    || die "$staged is xz-compressed and xz is not installed"
                xz -dc "$staged" > "$root/lib/modules/$m.ko" \
                    || die "cannot decompress $staged" ;;
            *.gz)
                gzip -dc "$staged" > "$root/lib/modules/$m.ko" \
                    || die "cannot decompress $staged" ;;
            *)
                cp "$staged" "$root/lib/modules/$m.ko" \
                    || die "cannot stage $staged" ;;
        esac
    done

    cat > "$root/init" <<'INIT'
#!/bin/busybox sh
B=/bin/busybox
$B mount -t proc none /proc
$B mount -t sysfs none /sys
$B mount -t devtmpfs none /dev
for m in $($B cat /proc/cmdline | $B tr ' ' '\n' | $B sed -n 's/^mqg_modules=//p' | $B tr ',' ' '); do
    [ -f "/lib/modules/$m.ko" ] && $B insmod "/lib/modules/$m.ko" 2>/dev/null
done
# Try partitions before the whole disk. A bare filesystem image lives at
# /dev/vda, but a GPT-partitioned disk -- which is what real installer
# media is -- puts it on /dev/vda1. Trying only the whole disk fails with
# a bare "mount failed" that says nothing about why.
#
# And check that the mount is WRITABLE, which is not the same as the mount
# succeeding. Linux's hfsplus driver silently falls back to read-only for a
# volume whose header does not say it was cleanly unmounted -- the normal
# state of any media a QEMU guest has booted, because powering a VM off is
# not a clean unmount. The symptom is a successful mount followed by
# "Read-only file system" from every chown, which reads like a permissions
# problem and is not one.
#
# -o force is tried, and for this particular cause it does NOT help:
# hfsplus_fill_super applies force only to the SOFTLOCK and JOURNALED
# branches, and takes the "was not cleanly unmounted" branch first. The
# repair is to mark the volume clean in its two volume headers, which
# hfs_mark_clean in lib/hfs.sh does from the host without privilege. Say so
# here rather than leave a reader to find that out from kernel source.
MQG_DEV=
for d in /dev/vda1 /dev/vda2 /dev/vda; do
    [ -b "$d" ] || continue
    $B mount -t hfsplus "$d" /mnt 2>/dev/null || continue
    if $B touch /mnt/.mqg-writable 2>/dev/null; then
        $B rm -f /mnt/.mqg-writable
        MQG_DEV=$d
        break
    fi
    echo "MQG-PRIVOPS-READONLY $d (volume not marked cleanly unmounted;"
    echo "  see hfs_mark_clean in lib/hfs.sh) -- trying -o force anyway"
    $B umount /mnt 2>/dev/null
    if $B mount -t hfsplus -o force "$d" /mnt 2>/dev/null &&
       $B touch /mnt/.mqg-writable 2>/dev/null; then
        $B rm -f /mnt/.mqg-writable
        MQG_DEV=$d
        break
    fi
    $B umount /mnt 2>/dev/null
done
if [ -n "$MQG_DEV" ]; then
    echo "MQG-PRIVOPS-MOUNTED $MQG_DEV"
    MQG_MNT=/mnt; export MQG_MNT B
    $B sh /payload.sh
    rc=$?
    $B sync
    $B umount /mnt && echo "MQG-PRIVOPS-OK rc=$rc" || echo "MQG-PRIVOPS-UNMOUNT-FAILED"
else
    echo "MQG-PRIVOPS-MOUNT-FAILED"
fi
$B poweroff -f
INIT
    chmod +x "$root/init"
    cp "$MQG_PRIVOPS_PAYLOAD" "$root/payload.sh"
    ( cd "$root" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$out"
    rm -rf "$root"
}

privops_run_qemu_linux() {
    local img=$1 script=$2 initramfs out mods kernel rc console
    kernel=$(privops_qemu_linux_kernel) || die \
        "no readable kernel image for $MQG_PRIVOPS_KVER (looked for: $(
            privops_qemu_linux_kernel_candidates | tr '\n' ' '))"
    privops_qemu_linux_kernel_is_keyed "$kernel" || warn \
        "$kernel is not keyed to the running kernel ($MQG_PRIVOPS_KVER):" \
        "if it is a different build, none of the modules staged from" \
        "$MQG_PRIVOPS_MODULES_DIR/$MQG_PRIVOPS_KVER will load"
    initramfs=$(mktemp -u)".cpio.gz"
    MQG_PRIVOPS_PAYLOAD=$script
    privops_qemu_linux_build_initramfs "$initramfs"
    mods=$(printf '%s' "$MQG_PRIVOPS_MODULES" | tr ' ' ',')

    # The timeout is generous and overridable, because it is a wall-clock
    # bound on someone else's hardware. 300s was fine on a 6-core Coffee
    # Lake and expired on a 2-core Broadwell doing the same work, which is
    # the kind of thing a fixed number cannot know.
    : "${MQG_PRIVOPS_TIMEOUT:=900}"

    log "running privileged operations in a QEMU microVM (no host root)"
    # rc is captured, NOT left to `set -e`. A command substitution that
    # fails in an ASSIGNMENT is fatal immediately under `set -e`, so
    # `out=$(timeout ... )` killed this script the instant the timeout
    # expired -- before reaching either of the die messages below that
    # exist to say what went wrong. On squirrel-zapper 2026-09-20 that
    # produced a 369-second media stage whose last line was "running
    # privileged operations in a QEMU microVM" and nothing else, on a
    # machine belonging to someone else, twice.
    #
    # NOTES.md already records this exact pattern from `screenshot.sh |
    # head -1`: the lesson was written down and did not travel. It is the
    # same class as the `${arr[@]+...}` guard that prereqs.sh had and three
    # other sites did not.
    #
    # SECOND, and this is what actually went wrong: the console is
    # STREAMED TO A FILE, not captured with `out=$(...)`. On that host the
    # capturing form produced ZERO bytes, while the identical QEMU command
    # run by hand with its output going to a pipe printed SeaBIOS and iPXE
    # normally. `-nographic` hands QEMU both stdin and stdout, and a
    # command substitution changes what those are. The symptom -- "the
    # microVM produced no output" -- is indistinguishable from the microVM
    # genuinely hanging, which is why it survived five runs and two wrong
    # diagnoses: a 300s timeout raised to 900s (it was never slowness) and
    # a hunt through kernel images (the kernel was fine all along).
    #
    # </dev/null for the same reason: -nographic takes stdin, and a step
    # that competes with its caller for the terminal is its own bug.
    console=$(mktemp)
    timeout "$MQG_PRIVOPS_TIMEOUT" qemu-system-x86_64 \
        -enable-kvm -m 512 -nographic -no-reboot \
        -kernel "$kernel" -initrd "$initramfs" \
        -append "console=ttyS0 loglevel=3 panic=1 mqg_modules=$mods" \
        -drive file="$img",format=raw,if=virtio \
        </dev/null > "$console" 2>&1 && rc=0 || rc=$?
    out=$(cat "$console")
    rm -f "$console" "$initramfs"

    # 124 is timeout(1)'s own "I killed it". Distinguished from a guest
    # that ran and failed, because the remedies are unrelated: one is a
    # slower machine or a hung microVM, the other is a broken payload.
    if [ "$rc" -eq 124 ]; then
        printf '%s\n' "$out" | tail -20 >&2
        die "the microVM did not finish within ${MQG_PRIVOPS_TIMEOUT}s" \
            "-- raise MQG_PRIVOPS_TIMEOUT if this host is slower, or see" \
            "the console output above if it hung"
    fi

    # Surface whatever the payload printed. The microVM's console also
    # carries kernel noise and terminal escapes, so strip those rather than
    # dumping raw output -- but never hide the payload's own lines, which
    # are the only diagnostic available when a build goes wrong.
    printf '%s\n' "$out" \
        | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\r//g' \
        | grep -vE '^\[[ 0-9.]+\]|^MQG-PRIVOPS-|^$' \
        | sed 's/^/    /'

    printf '%s\n' "$out" | grep -q 'MQG-PRIVOPS-OK' \
        || { printf '%s\n' "$out" | tail -20 >&2
             die "privileged operations failed inside the microVM"; }
    printf '%s\n' "$out" | grep -q 'MQG-PRIVOPS-OK rc=0' \
        || die "the payload script reported a failure inside the microVM"
    log "privileged operations completed and the image unmounted cleanly"
}
