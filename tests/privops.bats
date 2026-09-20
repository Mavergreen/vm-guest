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
