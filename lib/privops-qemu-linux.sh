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
# Requires lib/common.sh.

MQG_PRIVOPS_MODULES=${MQG_PRIVOPS_MODULES:-nls_base nls_utf8 hfsplus}

privops_qemu_linux_build_initramfs() {
    local out=$1 kver staged root
    kver=$(uname -r)
    root=$(mktemp -d)
    mkdir -p "$root"/{bin,dev,proc,sys,mnt,lib/modules}
    cp "$(command -v busybox)" "$root/bin/busybox" || die "cannot stage busybox"

    for m in $MQG_PRIVOPS_MODULES; do
        staged=$(find "/lib/modules/$kver" -name "$m.ko" -print -quit 2>/dev/null)
        [ -n "$staged" ] && cp "$staged" "$root/lib/modules/$m.ko"
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
MQG_DEV=
for d in /dev/vda1 /dev/vda2 /dev/vda; do
    [ -b "$d" ] || continue
    if $B mount -t hfsplus "$d" /mnt 2>/dev/null; then MQG_DEV=$d; break; fi
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
    local img=$1 script=$2 initramfs out mods
    initramfs=$(mktemp -u)".cpio.gz"
    MQG_PRIVOPS_PAYLOAD=$script
    privops_qemu_linux_build_initramfs "$initramfs"
    mods=$(printf '%s' "$MQG_PRIVOPS_MODULES" | tr ' ' ',')

    log "running privileged operations in a QEMU microVM (no host root)"
    out=$(timeout 300 qemu-system-x86_64 -enable-kvm -m 512 -nographic -no-reboot \
        -kernel "/boot/vmlinuz-$(uname -r)" -initrd "$initramfs" \
        -append "console=ttyS0 loglevel=3 panic=1 mqg_modules=$mods" \
        -drive file="$img",format=raw,if=virtio 2>&1)
    rm -f "$initramfs"

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
