# shellcheck shell=bash
# Host precondition verdicts.
#
# Each *_verdict function takes an already-gathered fact and returns a line
# of the form "<PASS|WARN|FAIL>\t<name>\t<detail>". Gathering is separated
# from judging so the judging can be tested without a particular host.
#
# Requires lib/common.sh to be sourced first.

check_result() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

cpu_vendor_verdict() {
    case $1 in
        GenuineIntel)
            check_result PASS cpu-vendor "Intel: the documented KVM path" ;;
        AuthenticAMD)
            check_result FAIL cpu-vendor \
                "AMD is a known-harder case for macOS guests; stop and ask" ;;
        *)
            check_result FAIL cpu-vendor "unrecognised CPU vendor: $1" ;;
    esac
}

vmx_verdict() {
    if [ "$1" = "yes" ]; then
        check_result PASS vmx "VT-x present"
    else
        check_result FAIL vmx "no VT-x; KVM acceleration unavailable"
    fi
}

kvm_device_verdict() {
    if [ -w "$1" ]; then
        check_result PASS kvm-device "$1 is writable by this user"
    elif [ -e "$1" ]; then
        check_result FAIL kvm-device \
            "$1 exists but is not writable; is this user in group kvm?"
    else
        check_result FAIL kvm-device "$1 does not exist"
    fi
}

# Somlo and OSX-KVM both require ignore_msrs. Setting it needs sudo, which
# is an ask -- so this warns rather than fails, and says what to do.
ignore_msrs_verdict() {
    if [ "$1" = "Y" ]; then
        check_result PASS ignore-msrs "kvm.ignore_msrs is enabled"
    else
        check_result WARN ignore-msrs \
            "kvm.ignore_msrs is '$1'; required by prior art. Needs sudo: ask before running 'echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs'"
    fi
}

# The distro's OVMF is informational since P3, not a requirement. The
# shipped profile boots firmware we build ourselves out of the pinned
# acidanthera/audk tree (boot/build-ovmf.sh), so a host with no `ovmf`
# package is not a no-go host -- and insisting otherwise would reimpose,
# as an executable check, exactly the per-host assumption that retiring
# ledger entry G5 removed. There is no such package on macOS at all, and
# P6 runs there. Still reported, because knowing what the host has is
# useful when comparing against the reference configuration.
ovmf_verdict() {
    local dir=$1
    if [ -f "$dir/OVMF_CODE_4M.fd" ] && [ -f "$dir/OVMF_VARS_4M.fd" ]; then
        check_result PASS ovmf "4M split CODE/VARS found in $dir"
    elif [ -f "$dir/OVMF.fd" ]; then
        check_result PASS ovmf "combined OVMF.fd found in $dir"
    else
        check_result WARN ovmf \
            "no distro OVMF in $dir -- not required: we build our own (boot/build-ovmf.sh)"
    fi
}

tool_verdict() {
    local tool=$1
    if command -v "$tool" >/dev/null 2>&1; then
        check_result PASS "tool:$tool" "$(command -v "$tool")"
    else
        check_result FAIL "tool:$tool" "not installed"
    fi
}

# Matched in-process rather than by piping into `grep -q`. grep -q exits on
# the first match, SIGPIPEing the writer; under `set -o pipefail` (which
# bin/preconditions.sh sets) the pipeline then reports 141 and this function
# would return 0 -- reporting GO *because* it found a FAIL. Same bug bit
# bin/tier-check.sh. No pipe, no signal, no surprise.
verdicts_exit_code() {
    case $1 in
        FAIL*|*"
FAIL"*) return 1 ;;
    esac
    return 0
}

# What each subcommand needs, one list apiece.
#
# spec: docs/superpowers/plans/2026-09-22-shipping-vmavs.md Task 3
#
# One list per subcommand rather than one list for the repository: a host
# with QEMU and no mkfs.hfsplus cannot build media and CAN run an image
# somebody else built, and "NO-GO" tells that person nothing.
#
# A `case`, not an associative array: bash 3.2 is the floor and
# `declare -A` is one of the constructs this project removed to keep it.
#
# Every tool named below is traced to a `require_cmd`-declared dependency
# (or, for the compiler toolchain, to bin/triangulate.sh's BUILD_TOOLS,
# which is where gcc/nasm/iasl are checked today -- boot/build-ovmf.sh
# declares none of its own, and just fails mid-compile without one) in the
# scripts each subcommand actually runs. (Note for anyone grepping this
# file for the literal declaration form: the two words above are written
# with a hyphen between them, on purpose, so this comment cannot be
# mistaken by tooling for an actual declaration naming bogus tools.)
#
#   fetch      media/fetch-installesd.sh, image/fetch-openssh.sh,
#              image/fetch-updates.sh
#   boot-stack boot/fetch-edk2.sh, boot/fetch-opencorepkg.sh,
#              boot/fetch-kexts.sh, boot/build-opencore.sh (the opencore
#              stage), bin/triangulate.sh's BUILD_TOOLS (the ovmf stage,
#              which declares no dependency of its own), boot/build-efi-image.sh
#              (the efi stage)
#   media      media/build-installer-img.sh, lib/hfs.sh, and the
#              qemu-linux privops backend (lib/privops-qemu-linux.sh) that
#              does the one privileged step inside a microVM
#   install    image/build-image.sh's own top-level dependency line, plus
#              the QEMU binary it boots (checked separately, right after)
#   clone      vm/clone.sh, lib/golden.sh (qemu-img create / info)
#   run        vm/run.sh (qemu-system-x86_64, hardcoded)
#   ssh        the ssh client itself
#   emit       python3 (image/payload/build-firstboot-pkg.sh's writer)
#   image      the union of fetch, boot-stack, media and install -- every
#               stage image/build-image.sh's pipeline runs
#
# Left out on purpose, as ubiquitous POSIX baseline present on every host
# this project targets (Linux, macOS, NetBSD) even though a `require_cmd`
# line somewhere names them: awk, tr, head, tail, dd, od, truncate. Naming
# them here would not help anyone triangulate a missing tool; a host
# without them cannot run bin/vmavs itself. 7z is left out too: it is
# media/verify-installer-img.sh's tool, not anything image/build-image.sh's
# media stage calls.
#
# tests/doctor.bats asserts that nothing named here is unknown to
# boot/prereqs.sh or bin/triangulate.sh. That test exists because the
# build-VM spec, section 9.1, records what happened when three tool lists
# disagreed: a host stopped on `zip` 23 seconds into a build.
vmavs_tools_for() {
    case $1 in
        doctor)     printf '%s\n' "" ;;
        fetch)      printf '%s\n' "curl openssl xxd sha256sum" ;;
        boot-stack) printf '%s\n' "gcc make git python3 nasm iasl mcopy mformat sgdisk curl tar unzip zip mmd mdir" ;;
        media)      printf '%s\n' "dmg2img sgdisk mkfs.hfsplus tar sha256sum python3 qemu-system-x86_64 cpio busybox" ;;
        install)    printf '%s\n' "qemu-system-x86_64 qemu-img ssh ssh-keygen python3 sha256sum" ;;
        target)     printf '%s\n' "qemu-img" ;;
        clone)      printf '%s\n' "qemu-img" ;;
        run)        printf '%s\n' "qemu-system-x86_64" ;;
        ssh)        printf '%s\n' "ssh" ;;
        emit)       printf '%s\n' "python3" ;;
        image)      printf '%s\n' "curl openssl xxd sha256sum gcc make git python3 nasm iasl mcopy mformat sgdisk tar unzip zip mmd mdir dmg2img mkfs.hfsplus qemu-system-x86_64 cpio busybox qemu-img ssh ssh-keygen" ;;
        *) return 1 ;;
    esac
}

# READY/BLOCKED for one subcommand, plus what is missing. Printed as
# "<verdict>\t<subcommand>\t<detail>", the same tab shape the existing
# verdict helpers use.
vmavs_subcommand_verdict() {
    local cmd=$1 missing="" t
    for t in $(vmavs_tools_for "$cmd"); do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -z "$missing" ]; then
        printf '%s\t%s\t%s\n' READY "$cmd" "-"
    else
        printf '%s\t%s\tmissing:%s\n' BLOCKED "$cmd" "$missing"
    fi
}
