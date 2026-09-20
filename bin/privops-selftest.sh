#!/usr/bin/env bash
# Boot the privops microVM on a trivial image and print everything.
#
# This exists because diagnosing the backend through a full pipeline run
# costs twenty minutes and a 6.4 GB media build to reach a step that takes
# seconds. On squirrel-zapper it cost five of them. The backend is the one
# part of this project that depends on the host's kernel, the host's
# busybox and the host's QEMU all at once, so it is the part most likely to
# fail on a machine nobody has tried yet -- and it should be possible to
# ask it directly.
#
# Prints, in order: what the backend thinks it is missing, which kernel it
# chose and why, the exact QEMU command line, and the microVM's console
# output UNFILTERED. The normal path strips kernel noise and escape
# sequences; here that is exactly what you want to see, because "no output
# at all" and "output we filtered away" look identical downstream and have
# nothing to do with each other.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/privops.sh
. "$MQG_REPO_ROOT/lib/privops.sh"
# shellcheck source=../lib/privops-qemu-linux.sh
. "$MQG_REPO_ROOT/lib/privops-qemu-linux.sh"

timeout_s=${MQG_PRIVOPS_TIMEOUT:-120}

printf '== host ==\n'
printf 'uname     %s\n' "$(uname -srm)"
printf 'qemu      %s\n' "$(qemu-system-x86_64 --version 2>/dev/null | head -1)"
printf 'busybox   %s\n' "$(command -v busybox || echo MISSING)"
if command -v busybox >/dev/null 2>&1; then
    printf 'linkage   %s\n' "$(privops_qemu_linux_busybox_linkage "$(command -v busybox)")"
fi
printf 'cpio      %s\n' "$(command -v cpio || echo MISSING)"
printf 'kvm       %s\n' "$([ -w /dev/kvm ] && echo writable || echo 'NOT writable')"

printf '\n== requirements the backend reports missing ==\n'
missing=$(privops_qemu_linux_missing || true)
if [ -n "$missing" ]; then
    printf '%s\n' "$missing"
else
    printf '(none)\n'
fi

printf '\n== kernel ==\n'
kernel=$(privops_qemu_linux_kernel 2>&1) || {
    printf 'no kernel found:\n%s\n' "$kernel"
    exit 1
}
printf 'chosen    %s\n' "$kernel"
printf 'size      %s bytes\n' "$(wc -c < "$kernel" 2>/dev/null || echo '?')"
printf 'readable  %s\n' "$([ -r "$kernel" ] && echo yes || echo NO)"
# A kernel QEMU can boot starts with an MZ or an HdrS magic further in.
# Reported rather than enforced: the point is to see what we handed QEMU,
# not to decide for it.
printf 'magic     %s\n' "$(head -c 2 "$kernel" 2>/dev/null | od -c | head -1)"

printf '\n== initramfs ==\n'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/payload.sh" <<'PAYLOAD'
echo "PAYLOAD RAN"
PAYLOAD
# Read by privops_qemu_linux_build_initramfs, which sources this from the
# environment rather than taking it as an argument.
export MQG_PRIVOPS_PAYLOAD="$work/payload.sh"
privops_qemu_linux_build_initramfs "$work/initramfs.cpio.gz"
printf 'built     %s (%s bytes)\n' "$work/initramfs.cpio.gz" \
    "$(wc -c < "$work/initramfs.cpio.gz")"

# A 16 MB scratch image. Big enough to be a real block device, small enough
# to cost nothing -- this is testing whether the microVM boots, not what it
# does once it has.
truncate -s 16M "$work/scratch.img"

mods=$(printf '%s' "$MQG_PRIVOPS_MODULES" | tr ' ' ',')

printf '\n== command ==\n'
printf 'timeout %s qemu-system-x86_64 -enable-kvm -m 512 -nographic -no-reboot \\\n' "$timeout_s"
printf '  -kernel %s \\\n  -initrd %s \\\n' "$kernel" "$work/initramfs.cpio.gz"
printf '  -append "console=ttyS0 loglevel=3 panic=1 mqg_modules=%s" \\\n' "$mods"
printf '  -drive file=%s,format=raw,if=virtio\n' "$work/scratch.img"

printf '\n== console (unfiltered, %ss limit) ==\n' "$timeout_s"
out=$(timeout "$timeout_s" qemu-system-x86_64 -enable-kvm -m 512 -nographic -no-reboot \
    -kernel "$kernel" -initrd "$work/initramfs.cpio.gz" \
    -append "console=ttyS0 loglevel=3 panic=1 mqg_modules=$mods" \
    -drive file="$work/scratch.img",format=raw,if=virtio 2>&1) && rc=0 || rc=$?

printf '%s\n' "$out"

printf '\n== verdict ==\n'
if [ "$rc" -eq 124 ]; then
    printf 'exit      %s (timeout killed it)\n' "$rc"
else
    printf 'exit      %s\n' "$rc"
fi
printf 'bytes     %s of console output\n' "$(printf '%s' "$out" | wc -c)"
if [ "$rc" -eq 124 ] && [ -z "$out" ]; then
    printf '\nZERO output and a timeout means the guest never reached the\n'
    printf 'serial console: not a slow host, which would still print. Suspect\n'
    printf 'the kernel image, -enable-kvm, or the console= argument -- in that\n'
    printf 'order. Try: re-run with MQG_PRIVOPS_TIMEOUT=30 and add\n'
    printf '"earlyprintk=serial,ttyS0" to see whether the kernel starts at all.\n'
fi
exit "$rc"
