#!/usr/bin/env bats
#
# The host-detection half of the privops backend, tested on one
# distribution against fixtures of the others.
#
# THE REGRESSION THESE GUARD. On 2026-09-20 an EndeavourOS host built the
# installer media -- 52,292 entries, every one of Apple's packages matching
# its pinned checksum -- and then stopped dead on
# `[ -r "/boot/vmlinuz-$(uname -r)" ]`, because Arch calls its kernel
# /boot/vmlinuz-linux. The check said only "not available", so which of its
# four requirements had failed took three round trips to find out.
#
# Kernel discovery reads MQG_PRIVOPS_BOOT_DIR, MQG_PRIVOPS_MODULES_DIR and
# MQG_PRIVOPS_KVER rather than /boot and `uname -r` precisely so that this
# file can pose as Arch, Gentoo or a host with no kernel at all without a
# second machine. Same move as MQG_PKG_MANAGER in boot/prereqs.sh.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/privops.sh"

    KVER=9.9.9-test
    BOOT="$BATS_TEST_TMPDIR/boot"
    MODS="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$BOOT" "$MODS/$KVER"
    export MQG_PRIVOPS_BOOT_DIR=$BOOT
    export MQG_PRIVOPS_MODULES_DIR=$MODS
    export MQG_PRIVOPS_KVER=$KVER
    # Sourced after the variables are set: the backend reads them at source
    # time, which is what the build scripts do too.
    # shellcheck source=/dev/null
    source "$REPO/lib/privops-qemu-linux.sh"
}

# --- finding a kernel that is not named the way Debian names it ------------

@test "kernel discovery finds a Debian-style /boot/vmlinuz-<release>" {
    : > "$BOOT/vmlinuz-$KVER"
    [ "$(privops_qemu_linux_kernel)" = "$BOOT/vmlinuz-$KVER" ]
}

@test "kernel discovery finds an Arch-style /boot/vmlinuz-linux" {
    : > "$BOOT/vmlinuz-linux"
    [ "$(privops_qemu_linux_kernel)" = "$BOOT/vmlinuz-linux" ]
}

@test "kernel discovery finds the copy under /lib/modules/<release>" {
    : > "$MODS/$KVER/vmlinuz"
    [ "$(privops_qemu_linux_kernel)" = "$MODS/$KVER/vmlinuz" ]
}

@test "kernel discovery finds a Gentoo-style /boot/kernel-<release>" {
    : > "$BOOT/kernel-$KVER"
    [ "$(privops_qemu_linux_kernel)" = "$BOOT/kernel-$KVER" ]
}

@test "kernel discovery fails, quietly, when there is no kernel at all" {
    run privops_qemu_linux_kernel
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# The ordering is the safety property, not a preference: the initramfs
# stages modules from /lib/modules/<running release>, so booting a
# generically-named kernel of some other version would load none of them
# and fail at the mount with nothing said about why.
@test "a kernel keyed to the running release beats a generic name" {
    : > "$BOOT/vmlinuz-linux"
    : > "$BOOT/vmlinuz"
    : > "$MODS/$KVER/vmlinuz"
    [ "$(privops_qemu_linux_kernel)" = "$MODS/$KVER/vmlinuz" ]
    : > "$BOOT/vmlinuz-$KVER"
    [ "$(privops_qemu_linux_kernel)" = "$BOOT/vmlinuz-$KVER" ]
}

@test "only version-keyed paths count as keyed to the running kernel" {
    privops_qemu_linux_kernel_is_keyed "$BOOT/vmlinuz-$KVER"
    privops_qemu_linux_kernel_is_keyed "$MODS/$KVER/vmlinuz"
    ! privops_qemu_linux_kernel_is_keyed "$BOOT/vmlinuz-linux"
    ! privops_qemu_linux_kernel_is_keyed "$BOOT/vmlinuz"
}

# --- saying WHAT is missing, not that something is ------------------------

@test "the missing-requirement report names every one, not just the first" {
    # A PATH on which none of the three tools can be found, and no kernel
    # anywhere. `sed` and `tr` are symlinked in because the report itself
    # formats with them -- this test is about qemu, busybox and cpio.
    BARE="$BATS_TEST_TMPDIR/bare"
    mkdir -p "$BARE"
    ln -s "$(command -v sed)" "$BARE/sed"
    ln -s "$(command -v tr)" "$BARE/tr"
    saved=$PATH
    PATH=$BARE
    run privops_backend_missing qemu-linux
    PATH=$saved
    [[ "$output" == *qemu-system-x86_64* ]]
    [[ "$output" == *busybox* ]]
    [[ "$output" == *cpio* ]]
    [[ "$output" == *"kernel image"* ]]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 4 ]
}

@test "the kernel line says which paths were looked at" {
    run privops_backend_missing qemu-linux
    [[ "$output" == *"$BOOT/vmlinuz-$KVER"* ]]
    [[ "$output" == *"$BOOT/vmlinuz-linux"* ]]
    [[ "$output" == *"$MODS/$KVER/vmlinuz"* ]]
}

@test "nothing is reported missing when every requirement is met" {
    # The busybox stub is a shell script, which ldd calls "not a dynamic
    # executable" -- the same answer it gives for a static binary, and the
    # one this test wants.
    : > "$BOOT/vmlinuz-$KVER"
    STUB="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB"
    for t in qemu-system-x86_64 busybox cpio; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB/$t"
        chmod +x "$STUB/$t"
    done
    PATH="$STUB:$PATH" run privops_backend_missing qemu-linux
    [ -z "$output" ]
    PATH="$STUB:$PATH" run privops_backend_available qemu-linux
    [ "$status" -eq 0 ]
}

# --- busybox has to be the STATIC one ------------------------------------
#
# Injected through PATH rather than by needing two busyboxes on this
# machine: any dynamically linked binary will do to play the part.

@test "a dynamic busybox is reported as the wrong busybox, not a missing one" {
    command -v ldd >/dev/null 2>&1 || skip "no ldd on this host to ask"
    : > "$BOOT/vmlinuz-$KVER"
    STUB="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB"
    for t in qemu-system-x86_64 cpio; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB/$t"
        chmod +x "$STUB/$t"
    done
    cp "$(command -v bash)" "$STUB/busybox"
    ldd "$STUB/busybox" 2>&1 | grep -q '=>' \
        || skip "this host's bash is not dynamically linked, so it cannot play the part"
    PATH="$STUB:$PATH" run privops_backend_missing qemu-linux
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == *"dynamically linked"* ]]
    [[ "$output" == *"$STUB/busybox"* ]]
    # The wrong advice would be "install busybox": there is one right here.
    [[ "$output" != *"not on PATH"* ]]
}

@test "linkage is unknown, not dynamic, when there is no ldd to ask" {
    BARE="$BATS_TEST_TMPDIR/bare2"
    mkdir -p "$BARE"
    saved=$PATH
    PATH=$BARE
    run privops_qemu_linux_busybox_linkage /nonexistent
    PATH=$saved
    [ "$output" = unknown ]
}

@test "an unknown backend is unavailable and says so" {
    run privops_backend_missing no-such-backend
    [[ "$output" == *"no-such-backend"* ]]
    run privops_backend_available no-such-backend
    [ "$status" -ne 0 ]
}

# --- the predicate stays silent -------------------------------------------
#
# privops_describe, and any test that only wants a yes or no, must not
# start printing requirement lists because the predicate learned to talk.
@test "privops_backend_available prints nothing either way" {
    run privops_backend_available qemu-linux
    [ -z "$output" ]
    : > "$BOOT/vmlinuz-$KVER"
    run privops_backend_available qemu-linux
    [ -z "$output" ]
}

@test "privops_describe reports availability and, when no, what is missing" {
    run privops_describe
    [[ "${lines[0]}" == "backend: qemu-linux" ]]
    [[ "$output" == *"available: no"* ]]
    [[ "$output" == *"missing: "* ]]
}

@test "a microVM timeout reports itself instead of dying silently" {
    # squirrel-zapper 2026-09-20, twice: out=$(timeout 300 qemu ...) under
    # set -e killed the script the instant the timeout expired, before
    # reaching any die message. The media stage ran 369s and its last log
    # line was "running privileged operations in a QEMU microVM".
    run grep -n 'timeout "$MQG_PRIVOPS_TIMEOUT"' "$REPO/lib/privops-qemu-linux.sh"
    [ "$status" -eq 0 ]
    # The status is captured, not left to set -e.
    grep -q 'rc=0 || rc=\$?' "$REPO/lib/privops-qemu-linux.sh"
    # 124 is distinguished from a guest that ran and failed.
    grep -q '"\$rc" -eq 124' "$REPO/lib/privops-qemu-linux.sh"
    # And the timeout is overridable for slower hosts.
    grep -q 'MQG_PRIVOPS_TIMEOUT:=900' "$REPO/lib/privops-qemu-linux.sh"
}

@test "the microVM console is streamed to a file, not captured inline" {
    # squirrel-zapper 2026-09-20: out=$(... qemu -nographic ...) produced
    # zero bytes, while the identical command run by hand into a pipe
    # printed SeaBIOS and iPXE. The symptom is indistinguishable from the
    # microVM hanging, and cost five runs and two wrong diagnoses.
    grep -q '> "$console" 2>&1' "$REPO/lib/privops-qemu-linux.sh"
    grep -q '</dev/null' "$REPO/lib/privops-qemu-linux.sh"
    # And no bare capture of a -nographic QEMU remains.
    ! grep -q 'out=$(timeout .* qemu-system' "$REPO/lib/privops-qemu-linux.sh"
}

@test "compressed kernel modules are staged, not silently skipped" {
    # Arch ships hfsplus.ko.zst; Debian ships hfsplus.ko. Matching
    # "$m.ko" exactly meant find returned nothing on Arch, the copy was
    # skipped without a word, and the HFS+ mount failed with no hint.
    grep -q 'name "$m.ko.zst"' "$REPO/lib/privops-qemu-linux.sh"
    grep -q 'name "$m.ko.xz"' "$REPO/lib/privops-qemu-linux.sh"
    # busybox insmod reads no compressed format, so staging decompresses.
    grep -q 'zstd -dqf' "$REPO/lib/privops-qemu-linux.sh"
    # And a module we cannot decompress is fatal, not skipped.
    grep -q 'cannot decompress' "$REPO/lib/privops-qemu-linux.sh"
}

# --- extra disks: the data path that replaces the host's loop device ------
#
# G26: udisks2 grants loop-setup to a user AT A SEAT, so the old
# loop-and-mount path could not run over SSH -- on any headless host,
# including a CI runner. The fix is to hand the microVM the source images
# as further virtio disks and let it do the whole HFS+ assembly. These
# guard the seam that makes that possible.

@test "an unknown disk role is refused rather than quietly attached" {
    : > "$BOOT/vmlinuz-$KVER"
    : > "$BATS_TEST_TMPDIR/img"
    : > "$BATS_TEST_TMPDIR/src"
    run privops_run_qemu_linux "$BATS_TEST_TMPDIR/img" /dev/null \
        "rw:$BATS_TEST_TMPDIR/src"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown disk role"* ]]
}

@test "an extra image that is not there is named before anything boots" {
    : > "$BOOT/vmlinuz-$KVER"
    : > "$BATS_TEST_TMPDIR/img"
    run privops_run_qemu_linux "$BATS_TEST_TMPDIR/img" /dev/null \
        "ro:$BATS_TEST_TMPDIR/absent"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such image"* ]]
}

@test "the roles the host chose are written into the initramfs" {
    # Not passed on the kernel command line: order is the point, a path
    # with a space in it does not survive a cmdline, and the guest needs
    # the answer rather than the request -- the same reasoning as the
    # module load order.
    command -v cpio >/dev/null 2>&1 || skip "no cpio on this host"
    command -v busybox >/dev/null 2>&1 || skip "no busybox on this host"
    printf 'echo hi\n' > "$BATS_TEST_TMPDIR/payload.sh"
    export MQG_PRIVOPS_PAYLOAD="$BATS_TEST_TMPDIR/payload.sh"
    export MQG_PRIVOPS_DISK_ROLES='ro
raw
'
    privops_qemu_linux_build_initramfs "$BATS_TEST_TMPDIR/initramfs.cpio.gz"
    run bash -c "gzip -dc '$BATS_TEST_TMPDIR/initramfs.cpio.gz' |
                 cpio -i --to-stdout disk-roles 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = 'ro
raw' ]
}

@test "source images are mounted read-only, and the target is not" {
    # A payload bug must not be able to corrupt a five-gigabyte conversion
    # that took minutes to produce. Belt (QEMU's readonly=on) and braces
    # (the guest's own mount -o ro).
    grep -q 'readonly=on' "$REPO/lib/privops-qemu-linux.sh"
    grep -q 'mount -t hfsplus -o ro' "$REPO/lib/privops-qemu-linux.sh"
}

@test "a source that will not mount is not reported as a target failure" {
    # The two have nothing to do with each other and their remedies are
    # unrelated: one is a bad conversion, the other a missing virtio or a
    # broken volume. The target's own bare "mount failed" cost five remote
    # runs before it was made to say what was actually there.
    grep -q 'MQG-PRIVOPS-SOURCE-MOUNT-FAILED' "$REPO/lib/privops-qemu-linux.sh"
    grep -q 'not the target image, which was not written to' \
        "$REPO/lib/privops-qemu-linux.sh"
}

@test "the microVM copies HFS+ to HFS+, keeping hardlinks, setuid and root" {
    # The whole G26 fix in one boot: a read-only source volume, a
    # read-write target, and a raw disk the guest hands a file back on.
    #
    # This is the one test here that actually boots the backend. It costs
    # about fifteen seconds and it is the only thing that can answer
    # whether busybox `cp -a` preserves what Apple's media needs -- the six
    # setuid files above all, which a chown would otherwise strip.
    # setup() points kernel discovery at a fixture directory so the other
    # tests can pose as Arch or Gentoo. This one needs the real host.
    unset MQG_PRIVOPS_BOOT_DIR MQG_PRIVOPS_MODULES_DIR MQG_PRIVOPS_KVER
    # shellcheck source=/dev/null
    source "$REPO/lib/privops-qemu-linux.sh"
    privops_backend_available qemu-linux || skip "backend not available here"
    [ -w /dev/kvm ] || skip "no writable /dev/kvm"
    command -v mkfs.hfsplus >/dev/null 2>&1 || skip "no mkfs.hfsplus"
    # shellcheck source=/dev/null
    source "$REPO/lib/hfs.sh"
    W=$BATS_TEST_TMPDIR
    hfs_create "$W/src.img" 32 "SRC VOL"
    hfs_create_gpt "$W/dst.img" 32 "DST VOL"
    truncate -s 8M "$W/scratch.raw"

    cat > "$W/populate.sh" <<'PAYLOAD'
$B mkdir -p "$MQG_MNT/dir"
echo payload > "$MQG_MNT/dir/a"
$B ln "$MQG_MNT/dir/a" "$MQG_MNT/dir/hardlink"
$B ln -s a "$MQG_MNT/dir/sym"
$B chmod 4755 "$MQG_MNT/dir/a"
$B dd if=/dev/urandom of="$MQG_MNT/big" bs=1M count=2 2>/dev/null
PAYLOAD
    run privops_run_qemu_linux "$W/src.img" "$W/populate.sh"
    [ "$status" -eq 0 ]

    cat > "$W/copy.sh" <<'PAYLOAD'
$B cp -a "$MQG_SRC1/." "$MQG_MNT/"
echo "MQG-TEST links=$($B stat -c %h "$MQG_MNT/dir/a")"
echo "MQG-TEST mode=$($B stat -c %a "$MQG_MNT/dir/a")"
echo "MQG-TEST owner=$($B stat -c %u:%g "$MQG_MNT/dir/a")"
echo "MQG-TEST sym=$($B readlink "$MQG_MNT/dir/sym")"
$B dd if="$MQG_SRC1/big" of="$MQG_RAW2" 2>/dev/null
PAYLOAD
    MQG_PRIVOPS_CONSOLE=$W/console.txt \
        run privops_run_qemu_linux "$W/dst.img" "$W/copy.sh" \
            "ro:$W/src.img" "raw:$W/scratch.raw"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MQG-TEST links=2"* ]]
    [[ "$output" == *"MQG-TEST mode=4755"* ]]
    [[ "$output" == *"MQG-TEST owner=0:0"* ]]
    [[ "$output" == *"MQG-TEST sym=a"* ]]
    # And the raw disk really did come back out of the guest: the first
    # two megabytes of it are the file the guest wrote there.
    [ "$(head -c 2097152 "$W/scratch.raw" | sha256sum | cut -d' ' -f1)" \
      != "$(head -c 2097152 /dev/zero | sha256sum | cut -d' ' -f1)" ]
}

@test "the selftest asks for everything the media build needs, not just a boot" {
    # A diagnostic that stops short of what the pipeline needs sends
    # somebody to a twenty-minute media build to find out the rest. Since
    # the media build moved inside the microVM it needs two more things of
    # a host -- a read-only HFS+ source disk, and bytes coming back out on
    # a raw one -- and privops-selftest.sh is what a new host runs first.
    grep -q '"ro:\$work/src.img" "raw:\$work/raw.img"' \
        "$REPO/bin/privops-selftest.sh"
    grep -q 'This host can build installer media' \
        "$REPO/bin/privops-selftest.sh"
    # And it still streams the console to a file rather than capturing it.
    grep -q '> "\$console" 2>&1' "$REPO/bin/privops-selftest.sh"
}

@test "privops-selftest refuses to boot when a requirement is missing" {
    # It used to report "busybox is dynamically linked" and then boot
    # anyway, panicking with "No working init found" -- the exact failure
    # the check exists to prevent, twenty lines below the sentence
    # explaining it. A diagnostic that demonstrates the problem it just
    # diagnosed teaches a reader to distrust the diagnosis.
    grep -q 'Not booting: the backend would refuse this host' \
        "$REPO/bin/privops-selftest.sh"
    # And the exit sits inside the missing-requirements branch, before the
    # QEMU invocation.
    stop=$(grep -n 'Not booting: the backend would refuse' "$REPO/bin/privops-selftest.sh" | cut -d: -f1)
    boot=$(grep -n 'timeout "\$timeout_s" qemu-system' "$REPO/bin/privops-selftest.sh" | cut -d: -f1)
    [ "$stop" -lt "$boot" ]
}
