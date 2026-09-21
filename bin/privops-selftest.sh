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
    # Stop here rather than boot anyway.
    #
    # ap-juicer 2026-09-21: this script reported "busybox is dynamically
    # linked" and then booted the microVM regardless, which panicked with
    # "No working init found" -- exactly the confusing failure the
    # requirement check exists to prevent, printed twenty lines below the
    # sentence explaining it. A diagnostic that demonstrates the problem it
    # just diagnosed teaches a reader to distrust the diagnosis.
    #
    # privops_run refuses in this situation, so booting here was also not
    # showing what the pipeline would do.
    printf '\nNot booting: the backend would refuse this host, and so does\n'
    printf 'this script. Install what is named above and run it again.\n'
    printf 'Booting anyway produces a kernel panic ("No working init\n'
    printf 'found") that looks like a kernel problem and is not one.\n'
    exit 1
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
# Streamed to a file and then printed, NOT captured with out=$(...).
#
# On squirrel-zapper the capturing form produced zero bytes while the very
# same QEMU, run by hand with its output going to a pipe, printed SeaBIOS
# and iPXE normally. Whatever the cause -- `-nographic` hands QEMU both
# stdin and stdout, and a command substitution changes what those are --
# a diagnostic tool must not have a failure mode that looks exactly like
# the failure it is diagnosing. Five round trips on someone else's laptop
# were spent on "the microVM produced no output" when the truth was "we
# did not collect it".
#
# </dev/null for the same reason: -nographic takes stdin, and a tool that
# competes with its caller for the terminal is its own bug.
console=$work/console.txt
timeout "$timeout_s" qemu-system-x86_64 -enable-kvm -m 512 -nographic -no-reboot \
    -kernel "$kernel" -initrd "$work/initramfs.cpio.gz" \
    -append "console=ttyS0 loglevel=3 panic=1 mqg_modules=$mods" \
    -drive file="$work/scratch.img",format=raw,if=virtio \
    </dev/null > "$console" 2>&1 && rc=0 || rc=$?

cat "$console"
out=$(cat "$console")

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
[ "$rc" -eq 0 ] || exit "$rc"

# --- the source disks and the raw channel --------------------------------
#
# Booting is no longer the whole question. Since the media build moved
# inside the microVM (G26) it needs three more things of this host, and a
# host that has none of them still passes everything above:
#
#   * more than one virtio disk at once,
#   * an HFS+ volume mounted READ-ONLY off one of them,
#   * bytes written to a raw disk arriving intact in the file on this side.
#
# A diagnostic that stops short of what the pipeline needs sends somebody
# to a twenty-minute media build to find out the rest. So this asks.
printf '\n== source disks and the raw channel ==\n'
if ! command -v mkfs.hfsplus >/dev/null 2>&1; then
    printf 'skipped: no mkfs.hfsplus, so there is no HFS+ source to make.\n'
    printf '(The media build needs it too -- see boot/prereqs.sh.)\n'
    exit 0
fi

# shellcheck source=../lib/hfs.sh
. "$MQG_REPO_ROOT/lib/hfs.sh"
hfs_create "$work/src.img" 32 "MQG SELFTEST"
hfs_create_gpt "$work/dst.img" 32 "MQG SELFTEST"
truncate -s 8M "$work/raw.img"

cat > "$work/populate.sh" <<'PAYLOAD'
$B mkdir -p "$MQG_MNT/dir"
echo "written inside the microVM" > "$MQG_MNT/dir/file"
$B chmod 4755 "$MQG_MNT/dir/file"
PAYLOAD
privops_run_qemu_linux "$work/src.img" "$work/populate.sh" >/dev/null 2>&1 \
    || { printf 'FAILED to write a scratch HFS+ volume in the microVM\n'; exit 1; }

cat > "$work/copy.sh" <<'PAYLOAD'
$B cp -a "$MQG_SRC1/." "$MQG_MNT/"
echo "mode   $($B stat -c %a "$MQG_MNT/dir/file")"
echo "owner  $($B stat -c %u:%g "$MQG_MNT/dir/file")"
$B dd if="$MQG_SRC1/dir/file" of="$MQG_RAW2" 2>/dev/null
PAYLOAD
MQG_PRIVOPS_CONSOLE=$work/console2.txt \
    privops_run_qemu_linux "$work/dst.img" "$work/copy.sh" \
        "ro:$work/src.img" "raw:$work/raw.img" 2>&1 | sed 's/^/  /'

printf 'disks the guest saw:\n'
grep -a 'MQG-PRIVOPS-DISK' "$work/console2.txt" | tr -d '\r' | sed 's/^/  /'
came_back=$(head -c 27 "$work/raw.img" | tr -d '\000')
printf 'raw disk  %s\n' "${came_back:-(nothing came back)}"
if [ "$came_back" = "written inside the microVM" ]; then
    printf '\nThis host can build installer media: two source disks, a\n'
    printf 'read-only HFS+ mount and the raw channel all work.\n'
    exit 0
fi
printf '\nThe raw channel did not deliver. The media build cannot get\n'
printf "BaseSystem.dmg out of the ESD this way, so it would fail at its\n"
printf 'first microVM pass. See media/privops/extract-basesystem.sh.\n'
exit 1
