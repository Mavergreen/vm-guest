#!/usr/bin/env bash
# Gather host facts, judge them, print a table, exit non-zero on any FAIL.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$repo_root/lib/common.sh"
# shellcheck source=../lib/preconditions.sh
. "$repo_root/lib/preconditions.sh"

OVMF_DIR=${OVMF_DIR:-/usr/share/OVMF}

# HOST FACTS, GUARDED BY OS.
#
# lscpu, /proc/cpuinfo and /sys/module/kvm/parameters/ignore_msrs are all
# Linux-only. decisions/0007 names Linux, macOS and NetBSD as this
# project's hosts; on the other two this used to die before printing
# anything, which is the wrong failure for a command whose whole job is
# to say what a host can do.
#
# The fix is not an HVF branch for macOS or an NVMM branch for NetBSD.
# Nobody has run this project on either, and decisions/0007's own rule for
# the Snow Leopard want applies here word for word: a parameter with one
# value is honest, and a parameter with one value plus a second branch
# nobody has run is a claim we cannot support. So on a non-Linux host
# doctor reports exactly one accelerator row, UNKNOWN, and says in as many
# words that this project has never probed an accelerator there -- rather
# than guess.
os=$(uname -s)
if [ "$os" = Linux ]; then
    vendor=$(awk -F': *' '/^Vendor ID/ { print $2; exit }' < <(LC_ALL=C lscpu))
    if grep -qw vmx /proc/cpuinfo; then vmx=yes; else vmx=no; fi
    msrs=$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || echo "unknown")
    host_verdicts=$(
        cpu_vendor_verdict "$vendor"
        vmx_verdict "$vmx"
        kvm_device_verdict /dev/kvm
        ignore_msrs_verdict "$msrs"
        ovmf_verdict "$OVMF_DIR"
    )
else
    host_verdicts=$(printf '%s\t%s\t%s\n' UNKNOWN accelerator \
        "never probed on $os by this project -- see docs/test-hosts.md")
fi

verdicts=$(
    printf '%s\n' "$host_verdicts"
    for t in qemu-system-x86_64 qemu-img dmg2img sgdisk xxd \
             openssl curl unzip python3 mkfs.hfsplus bats; do
        tool_verdict "$t"
    done
)

printf '%-6s  %-24s  %s\n' STATUS CHECK DETAIL
printf '%-6s  %-24s  %s\n' ------ ----- ------
printf '%s\n' "$verdicts" | while IFS=$'\t' read -r s n d; do
    printf '%-6s  %-24s  %s\n' "$s" "$n" "$d"
done

echo
printf '%-8s  %-11s  %s\n' STATUS SUBCOMMAND DETAIL
printf '%-8s  %-11s  %s\n' -------- ----------- ------
for c in fetch boot-stack media install clone run ssh emit image; do
    vmavs_subcommand_verdict "$c"
done | while IFS=$'\t' read -r s n d; do
    printf '%-8s  %-11s  %s\n' "$s" "$n" "$d"
done

echo
echo "For the ledger-grade answer -- the -cpu ladder, QEMU's device list,"
echo "nested virtualization, accelerator -- run: vmavs triangulate --probe"

echo
if verdicts_exit_code "$verdicts"; then
    log "preconditions: GO"
else
    die "preconditions: NO-GO (see FAIL rows above)"
fi
