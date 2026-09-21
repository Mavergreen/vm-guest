#!/usr/bin/env bash
# Gather host facts, judge them, print a table, exit non-zero on any FAIL.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$repo_root/lib/common.sh"
# shellcheck source=../lib/preconditions.sh
. "$repo_root/lib/preconditions.sh"

OVMF_DIR=${OVMF_DIR:-/usr/share/OVMF}

vendor=$(awk -F': *' '/^Vendor ID/ { print $2; exit }' < <(LC_ALL=C lscpu))
if grep -qw vmx /proc/cpuinfo; then vmx=yes; else vmx=no; fi
msrs=$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || echo "unknown")

verdicts=$(
    cpu_vendor_verdict "$vendor"
    vmx_verdict "$vmx"
    kvm_device_verdict /dev/kvm
    ignore_msrs_verdict "$msrs"
    ovmf_verdict "$OVMF_DIR"
    for t in qemu-system-x86_64 qemu-img dmg2img kpartx sgdisk xxd \
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
if verdicts_exit_code "$verdicts"; then
    log "preconditions: GO"
else
    die "preconditions: NO-GO (see FAIL rows above)"
fi
