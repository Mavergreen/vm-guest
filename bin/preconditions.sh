#!/usr/bin/env bash
# `vmavs doctor`: gather host facts, judge them, print a table, then say
# per subcommand what this host can run. Exit status is decided below,
# where the rule is written down.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$repo_root/lib/common.sh"
# shellcheck source=../lib/preconditions.sh
. "$repo_root/lib/preconditions.sh"

OVMF_DIR=${OVMF_DIR:-/usr/share/OVMF}
# Overridable for the same reason OVMF_DIR is: so tests/doctor.bats can
# put the host facts in a known state on a CI runner that has no
# /dev/kvm and no vmx flag, and test the verdict rather than the runner.
CPUINFO=${CPUINFO:-/proc/cpuinfo}
KVM_DEVICE=${KVM_DEVICE:-/dev/kvm}

usage() {
    cat <<'EOF'
usage: vmavs doctor

Probe this host -- CPU, accelerator, firmware, and the tools the build
uses -- then print one READY or BLOCKED row per vmavs subcommand, naming
what is missing. The last line sums that table up.

Exits 0 when `vmavs image` is READY and no host fact FAILs; 1 otherwise.
EOF
}

case ${1:-} in
    -h|--help) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac

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
    if grep -qw vmx "$CPUINFO"; then vmx=yes; else vmx=no; fi
    msrs=$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || echo "unknown")
    host_verdicts=$(
        cpu_vendor_verdict "$vendor"
        vmx_verdict "$vmx"
        kvm_device_verdict "$KVM_DEVICE"
        ignore_msrs_verdict "$msrs"
        ovmf_verdict "$OVMF_DIR"
    )
else
    host_verdicts=$(printf '%s\t%s\t%s\n' UNKNOWN accelerator \
        "never probed on $os by this project -- see docs/test-hosts.md")
fi

# Every tool here is also in vmavs_tools_for image, so a FAIL row below
# always shows up again as a BLOCKED image row -- the table and the
# verdict at the bottom cannot disagree about it.
#
# bats is not one of them. It runs tests/, which a developer needs and a
# user of vmavs does not; gating on it gave a user without bats NO-GO
# beside a table of READY rows (MEASURED, final review). It stays as an
# INFO row because a developer does want to know.
verdicts=$(
    printf '%s\n' "$host_verdicts"
    for t in qemu-system-x86_64 qemu-img dmg2img sgdisk xxd \
             openssl curl unzip python3 mkfs.hfsplus; do
        tool_verdict "$t"
    done
    if command -v bats >/dev/null 2>&1; then
        check_result INFO tool:bats "$(command -v bats) (runs tests/; not needed to use vmavs)"
    else
        check_result INFO tool:bats "not installed (runs tests/; not needed to use vmavs)"
    fi
)

printf '%-6s  %-24s  %s\n' STATUS CHECK DETAIL
printf '%-6s  %-24s  %s\n' ------ ----- ------
printf '%s\n' "$verdicts" | while IFS=$'\t' read -r s n d; do
    printf '%-6s  %-24s  %s\n' "$s" "$n" "$d"
done

echo
printf '%-8s  %-11s  %s\n' STATUS SUBCOMMAND DETAIL
printf '%-8s  %-11s  %s\n' -------- ----------- ------
sub_verdicts=$(
    for c in fetch boot-stack media install clone run ssh emit image; do
        vmavs_subcommand_verdict "$c"
    done
)
printf '%s\n' "$sub_verdicts" | while IFS=$'\t' read -r s n d; do
    printf '%-8s  %-11s  %s\n' "$s" "$n" "$d"
done

echo
echo "For the ledger-grade answer -- the -cpu ladder, QEMU's device list,"
echo "nested virtualization, accelerator -- run: vmavs triangulate --probe"

# THE LAST LINE SUMS UP THE SUBCOMMAND TABLE, NOT A LIST OF ITS OWN.
#
# It used to come from the flat tool list above, with bats in it: a host
# without bats got NO-GO with every subcommand READY, and a host missing
# nasm, iasl, mtools, cpio or busybox -- none of which that list named --
# got GO printed right under "BLOCKED image" (both MEASURED, final
# review). Now it is read off the same rows the table printed.
#
# Exit status rule: 0 if and only if `image` is READY and no host-fact
# row FAILs. `image` because it is the union of every stage the pipeline
# runs (see vmavs_tools_for), so READY there means every row is READY;
# host facts because a missing /dev/kvm or a CPU this project has not
# run on stops a build that has every tool. A tool row's FAIL needs no
# rule of its own: every such tool is in image's list (see above).
#
# Only image's row gets its missing tools repeated on the summary line:
# its list is the union, so it names everything the other blocked rows
# lack, once, instead of the same tools five times over.
ready="" blocked="" image_ready=no image_missing=""
while IFS=$'\t' read -r s n d; do
    case $s in
        READY)
            ready="$ready $n"
            [ "$n" != image ] || image_ready=yes ;;
        BLOCKED)
            blocked="$blocked $n"
            [ "$n" != image ] || image_missing=" ($d)" ;;
    esac
done <<EOF
$sub_verdicts
EOF
# verdicts_exit_code decides; this loop only names the rows for the
# summary line.
host_failed=""
while IFS=$'\t' read -r s n _; do
    [ "$s" != FAIL ] || host_failed="$host_failed $n"
done <<EOF
$host_verdicts
EOF

summary="ready:${ready:- nothing}"
[ -z "$blocked" ] || summary="$summary; blocked:$blocked$image_missing"
[ -z "$host_failed" ] || summary="$summary; host FAIL:$host_failed"

echo
if [ "$image_ready" = yes ] && verdicts_exit_code "$host_verdicts"; then
    log "doctor: GO -- $summary"
else
    die "doctor: NO-GO -- $summary"
fi
