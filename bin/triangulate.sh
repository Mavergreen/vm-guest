#!/usr/bin/env bash
# Ask a host what it can do, and say what that settles.
#
# WHO RUNS THIS
#
# Not us. The other hosts in docs/test-hosts.md belong to the user, and
# some of them are doing a job already -- the Mac Pro runs OpenMediaVault
# and is presumably serving something. That shapes every rule below:
#
#   * it installs nothing, and never asks for root
#   * it writes only under $MQG_IMAGE_DIR (and a temporary directory it
#     removes), and at --probe it writes nothing that outlives the run
#   * it cleans up after itself, and says exactly what it removed and what
#     it left behind
#   * the default level is the safe one, because the safe thing should be
#     what happens when someone types the command with no arguments
#
# WHAT IT PRODUCES
#
# Not "it worked". A run that prints "it worked" is a failed run. The
# deliverable is an updated generalization ledger: for every entry in
# docs/host-profile.md section 4 that this host can speak to, what was
# observed and whether it CONFIRMs, REFUTEs, or CANNOT-SAY. The last
# section of the report is markdown table rows meant to be pasted into
# that file, and --json emits the same thing machine-readably so several
# hosts can be diffed rather than read side by side.
#
# THREE LEVELS
#
#   --probe   what the host can do; touches nothing        ~2 min
#   --build   probe, plus the boot stack and the media     ~10 min
#   --full    build, plus an unattended install and SSH    ~30 min
#
# Each includes the previous.
#
# NOTHING HOST-SPECIFIC IS HARDCODED, AND WHERE IT IS, THAT IS A FINDING
#
# This is the one script in the repository that must assume nothing about
# its host, which makes it a measurement of how much the rest of the
# repository assumes. Every place it has to special-case an operating
# system or a toolchain is recorded with tri_special and printed in its own
# section. That section is not an apology; it is a list of the portability
# work this project still owes.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/triangulate.sh
. "$MQG_REPO_ROOT/lib/triangulate.sh"

# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=triangulate

level=probe
want_json=0
json_out=
keep=0
name=
qemu_bin=${MQG_QEMU:-qemu-system-x86_64}

usage() {
    cat <<EOF
usage: $(basename "$0") [--probe|--build|--full] [options]

  --probe          Report what this host can do. Touches nothing. (default)
  --build          Probe, then build the boot stack and the installer media.
  --full           Build, then install a guest unattended and check SSH.

  --json           Write the JSON report to stdout, the human one to stderr.
  --json-out FILE  Write the JSON report to FILE, the human one to stdout.
  --keep           Leave behind whatever --build/--full created.
  --name NAME      Name for the image --full builds.
  --qemu BINARY    QEMU to interrogate (default: $qemu_bin).
  -h, --help       This.

The levels are cumulative and the cheap one is the default, because a user
with five machines runs --probe on all of them and --full on the two that
look promising.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --probe) level=probe ;;
        --build) level=build ;;
        --full)  level=full ;;
        --json)  want_json=1 ;;
        --json-out) want_json=1; json_out=$2; shift ;;
        --keep)  keep=1 ;;
        --name)  name=$2; shift ;;
        --qemu)  qemu_bin=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

name=${name:-triangulate-$(date -u +%Y%m%d-%H%M%S)}

# The human report goes to stdout unless --json has taken stdout for the
# machine-readable one. Everything the report prints goes through say().
report=""
say() { report="$report$*
"; }

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- a scratch directory that always goes away -----------------------------

scratch=$(mktemp -d "${TMPDIR:-/tmp}/mqg-triangulate.XXXXXX") \
    || die "cannot create a scratch directory"
# Tracked separately from the scratch directory: things created under
# $MQG_IMAGE_DIR by --build and --full, which a user may want to keep.
created_list=$scratch/created
: > "$created_list"

# shellcheck disable=SC2317  # reached through the EXIT/INT/TERM trap below
cleanup() {
    local p
    if [ "$keep" -eq 0 ] && [ -s "$created_list" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            [ -e "$p" ] || continue
            rm -rf "$p" && printf 'triangulate: removed %s\n' "$p" >&2
        done < "$created_list"
    elif [ -s "$created_list" ]; then
        printf 'triangulate: --keep: left behind:\n' >&2
        sed -e 's/^/  /' "$created_list" >&2
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

track_created() { printf '%s\n' "$1" >> "$created_list"; }

# --- portable fact gathering -----------------------------------------------
#
# Every helper here has one job: get the same fact off a Linux, a macOS or a
# BSD host, and say "unknown" rather than guess. The special cases are
# recorded as they are used.

# The special cases this script contains, recorded whether or not this
# host takes them. The list is the point: each line is a fact about one
# kind of host that had to be written down somewhere, and the report prints
# them all so that "how portable is this project" has an answer with a
# length rather than a yes or a no.
tri_special "CPU brand, vendor and feature flags come from three different places -- /proc/cpuinfo on Linux, sysctl on macOS, cpuctl on NetBSD -- because there is no portable way to ask"
tri_special "filesystem type uses GNU 'stat -f -c %T' on Linux and parses mount(8) output in two different shapes elsewhere"
tri_special "free space and mount points come from 'df -P', which is POSIX, and that is the only part of this that needed no special case"

os=$(uname -s 2>/dev/null || echo unknown)
kernel=$(uname -r 2>/dev/null || echo unknown)
arch=$(uname -m 2>/dev/null || echo unknown)
host=$(hostname 2>/dev/null || echo unknown)

first_line() { sed -n '1p'; }

sysctl_n() {
    command -v sysctl >/dev/null 2>&1 || return 1
    sysctl -n "$1" 2>/dev/null
}

cpu_brand() {
    case $os in
        Linux)
            awk -F': *' '/^model name/ { print $2; exit }' /proc/cpuinfo ;;
        Darwin)
            sysctl_n machdep.cpu.brand_string ;;
        *)
            sysctl_n machdep.cpu_brand || sysctl_n hw.model || true ;;
    esac
}

cpu_vendor() {
    case $os in
        Linux)
            awk -F': *' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo ;;
        Darwin)
            sysctl_n machdep.cpu.vendor ;;
        *)
            # NetBSD prints the vendor inside cpuctl's identify output.
            if command -v cpuctl >/dev/null 2>&1; then
                cpuctl identify 0 2>/dev/null \
                    | sed -n 's/.*\(GenuineIntel\|AuthenticAMD\).*/\1/p' | first_line
            fi ;;
    esac
}

cpu_flags() {
    case $os in
        Linux)
            awk -F': *' '/^flags/ { print $2; exit }' /proc/cpuinfo ;;
        Darwin)
            printf '%s %s %s' \
                "$(sysctl_n machdep.cpu.features || true)" \
                "$(sysctl_n machdep.cpu.leaf7_features || true)" \
                "$(sysctl_n machdep.cpu.extfeatures || true)" ;;
        *)
            if command -v cpuctl >/dev/null 2>&1; then
                cpuctl identify 0 2>/dev/null | tr ',' ' '
            fi ;;
    esac
}

ram_mib() {
    case $os in
        Linux)
            awk '/^MemTotal/ { printf "%d", $2 / 1024; exit }' /proc/meminfo ;;
        Darwin)
            local b; b=$(sysctl_n hw.memsize || echo 0); printf '%d' $((b / 1048576)) ;;
        *)
            local n; n=$(sysctl_n hw.physmem64 || sysctl_n hw.physmem || echo 0)
            printf '%d' $((n / 1048576)) ;;
    esac
}

cpu_cores() {
    case $os in
        Linux)
            local c s
            c=$(awk -F': *' '/^cpu cores/ { print $2; exit }' /proc/cpuinfo)
            s=$(awk -F': *' '/^physical id/ { print $2 }' /proc/cpuinfo | sort -u | wc -l)
            [ -n "$c" ] || c=0
            [ "$s" -gt 0 ] 2>/dev/null || s=1
            printf '%d' $((c * s)) ;;
        Darwin)
            sysctl_n hw.physicalcpu || printf '0' ;;
        *)
            getconf _NPROCESSORS_ONLN 2>/dev/null || printf '0' ;;
    esac
}

cpu_logical() {
    case $os in
        Linux)  grep -c '^processor' /proc/cpuinfo ;;
        Darwin) sysctl_n hw.logicalcpu || printf '0' ;;
        *)      getconf _NPROCESSORS_ONLN 2>/dev/null || printf '0' ;;
    esac
}

# The nearest existing ancestor of a path. --probe must not create
# $MQG_IMAGE_DIR on a host that has never run this project, so the
# filesystem questions are asked of the directory that would hold it.
nearest_existing() {
    local p=$1
    while [ -n "$p" ] && [ "$p" != / ] && [ ! -d "$p" ]; do
        p=$(dirname "$p")
    done
    printf '%s\n' "$p"
}

fs_type_of() {
    local path=$1 mp t=""
    if [ "$os" = Linux ] && command -v stat >/dev/null 2>&1; then
        t=$(stat -f -c %T "$path" 2>/dev/null || true)
    fi
    if [ -z "$t" ]; then
        mp=$(df -P "$path" 2>/dev/null | awk 'NR == 2 { for (i = 6; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "") }')
        if [ -n "$mp" ]; then
            # Two shapes: "dev on /mnt type ext4 (...)" on Linux, and
            # "dev on /mnt (apfs, local, ...)" on macOS and the BSDs.
            t=$(mount 2>/dev/null | sed -n "s|^.* on ${mp} type \([^ ]*\).*|\1|p" | first_line)
            [ -n "$t" ] || t=$(mount 2>/dev/null | sed -n "s|^.* on ${mp} (\([^,)]*\).*|\1|p" | first_line)
        fi
    fi
    [ -n "$t" ] || t=unknown
    printf '%s\n' "$t"
}

free_mib_of() {
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }'
}

# G10. Measured, not inferred from the filesystem name: a filesystem that
# usually has reflinks can be mounted somewhere that does not.
reflink_probe() {
    local dir=$1 d rc=unknown
    d=$(mktemp -d "$dir/.mqg-triangulate.XXXXXX" 2>/dev/null) || {
        printf 'unknown\n'; return 0; }
    dd if=/dev/zero of="$d/src" bs=1024 count=64 >/dev/null 2>&1 || true
    if cp --help 2>&1 | grep -q -- --reflink; then
        if cp --reflink=always "$d/src" "$d/dst" >/dev/null 2>&1; then
            rc=yes
        else
            rc=no
        fi
    elif [ "$os" = Darwin ]; then
        # macOS has no --reflink; APFS clones are `cp -c`.
        tri_special "reflink probe: macOS cp has no --reflink, so 'cp -c' (APFS clonefile) is used instead"
        if cp -c "$d/src" "$d/dst" >/dev/null 2>&1; then
            rc=yes
        else
            rc=no
        fi
    else
        tri_special "reflink probe: this cp knows neither --reflink nor -c, so G10 cannot be measured here"
    fi
    rm -rf "$d"
    printf '%s\n' "$rc"
}

# G11. Only meaningful on btrfs, and chattr is a Linux e2fsprogs tool.
nocow_probe() {
    local dir=$1 d rc=unknown
    command -v chattr >/dev/null 2>&1 || {
        tri_special "chattr is not on this host, so G11's btrfs chore cannot be exercised (it is Linux-only, and only applies to btrfs)"
        printf 'unknown\n'; return 0; }
    d=$(mktemp -d "$dir/.mqg-triangulate.XXXXXX" 2>/dev/null) || {
        printf 'unknown\n'; return 0; }
    if chattr +C "$d" >/dev/null 2>&1; then rc=yes; else rc=no; fi
    rm -rf "$d"
    printf '%s\n' "$rc"
}

# G12. Milliseconds per file create. Sub-second timing is the one thing
# POSIX gives no portable way to do, so python3 is used when it is there
# and the whole-second fallback says so rather than inventing precision.
create_ms() {
    local dir=$1 d n=200 t0 t1 secs
    d=$(mktemp -d "$dir/.mqg-triangulate.XXXXXX" 2>/dev/null) || {
        printf 'unknown\n'; return 0; }
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$d" "$n" <<'PY'
import os, sys, time
d, n = sys.argv[1], int(sys.argv[2])
t0 = time.time()
for i in range(n):
    with open(os.path.join(d, "f%d" % i), "w"):
        pass
print("%.2f" % ((time.time() - t0) * 1000.0 / n))
PY
    else
        tri_special "no python3: file-create timing falls back to whole seconds, which cannot see a local filesystem at all"
        t0=$SECONDS
        local i=0
        while [ "$i" -lt "$n" ]; do : > "$d/f$i"; i=$((i + 1)); done
        t1=$SECONDS
        secs=$((t1 - t0))
        printf '%d' $((secs * 1000 / n))
    fi
    rm -rf "$d"
}

# --- gather ----------------------------------------------------------------

log "level $level on $host ($os $kernel $arch)"

brand=$(cpu_brand || true); brand=${brand:-unknown}
vendor=$(cpu_vendor || true); vendor=${vendor:-unknown}
flags=$(cpu_flags || true)
cores=$(cpu_cores || echo 0)
logical=$(cpu_logical || echo 0)
threads=1
[ "$cores" -gt 0 ] 2>/dev/null && threads=$((logical / cores))
ram=$(ram_mib || echo 0)

case $os in
    Linux)  sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true) ;;
    Darwin) sys_vendor="Apple Inc." ;;
    *)      sys_vendor=$(sysctl_n machdep.dmi.system-vendor || true) ;;
esac
[ -n "$sys_vendor" ] || sys_vendor=""

os_name=unknown
if [ -r /etc/os-release ]; then
    os_name=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-$NAME}")
elif command -v sw_vers >/dev/null 2>&1; then
    os_name="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
else
    os_name="$os $kernel"
fi

# The three flags our -cpu line names, by the spelling /proc/cpuinfo uses.
have_ssse3=no;  cpu_has_flag "$flags" ssse3  && have_ssse3=yes
have_sse41=no;  cpu_has_flag "$flags" sse4_1 && have_sse41=yes
have_sse42=no;  cpu_has_flag "$flags" sse4_2 && have_sse42=yes
have_vmx=no;    cpu_has_flag "$flags" vmx    && have_vmx=yes
have_svm=no;    cpu_has_flag "$flags" svm    && have_svm=yes
have_ept=no;    cpu_has_flag "$flags" ept    && have_ept=yes
virt=none
[ "$have_vmx" = yes ] && virt=vmx
[ "$have_svm" = yes ] && virt=svm

kvm=no
[ -w /dev/kvm ] && kvm=yes
kvm_note=""
if [ "$kvm" = no ] && [ -e /dev/kvm ]; then
    kvm_note="/dev/kvm exists but is not writable by this user (group membership?)"
fi
hvf=no
if [ "$os" = Darwin ] && [ "$(sysctl_n kern.hv_support || echo 0)" = 1 ]; then
    hvf=yes
fi
nvmm=no
[ -e /dev/nvmm ] && nvmm=yes
accel=$(accel_pick "$kvm" "$hvf" "$nvmm")

nested=unknown
for f in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
    [ -r "$f" ] || continue
    nested=$(cat "$f")
    break
done
ignore_msrs=unknown
[ -r /sys/module/kvm/parameters/ignore_msrs ] \
    && ignore_msrs=$(cat /sys/module/kvm/parameters/ignore_msrs)
if [ "$os" != Linux ]; then
    tri_special "nested virt and kvm.ignore_msrs are read from /sys, which only Linux has; on any other host they report 'unknown' rather than a guess"
fi

image_dir=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
# Exported, not merely read: --build and --full run image/build-image.sh as
# a child, and it takes this from the environment. A value this script
# resolved and the child defaulted differently would put the guest image
# somewhere nobody looked.
export MQG_IMAGE_DIR=$image_dir
image_dir_exists=yes
[ -d "$image_dir" ] || image_dir_exists=no
probe_dir=$(nearest_existing "$image_dir")
image_fs=$(fs_type_of "$probe_dir")
repo_fs=$(fs_type_of "$MQG_REPO_ROOT")
free_mib=$(free_mib_of "$probe_dir")
[ -n "$free_mib" ] || free_mib=0

reflink=$(reflink_probe "$probe_dir")
nocow=$(nocow_probe "$probe_dir")
repo_ms=$(create_ms "$MQG_REPO_ROOT")
local_ms=$(create_ms "$probe_dir")

# --- QEMU ------------------------------------------------------------------

qemu_path=$(command -v "$qemu_bin" 2>/dev/null || true)
qemu_version=""
qemu_accels=""
qemu_devices=""
qemu_machines=""
qemu_has_penryn=no
missing_devices=""
DEVICES="ich9-usb-ehci1 ich9-usb-uhci1 ich9-usb-uhci2 ich9-usb-uhci3 usb-storage usb-net usb-kbd usb-mouse usb-tablet ide-hd VGA"
if [ -n "$qemu_path" ]; then
    qemu_version=$("$qemu_bin" --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | first_line)
    qemu_accels=$("$qemu_bin" -accel help 2>&1 | sed -e '1d' -e 's/^[[:space:]]*//' | tr '\n' ' ')
    qemu_devices=$("$qemu_bin" -device help 2>&1 || true)
    qemu_machines=$("$qemu_bin" -machine help 2>&1 || true)
    case $qemu_machines in *q35*) : ;; *) missing_devices="$missing_devices q35(machine)" ;; esac
    for d in $DEVICES; do
        case $qemu_devices in
            *"\"$d\""*) : ;;
            *) missing_devices="$missing_devices $d" ;;
        esac
    done
    "$qemu_bin" -cpu help 2>/dev/null | grep -qi penryn && qemu_has_penryn=yes
fi
devices_ok=yes
[ -z "$missing_devices" ] || devices_ok=no

# THE HEADLINE TEST.
#
# docs/test-hosts.md predicts that the Mac Pro 1,1's Woodcrest cannot
# provide SSE4.1, so `-cpu Penryn,+sse4.1` should be rejected outright --
# and says that confirming the prediction is worth as much as refuting it.
# `enforce` is what turns QEMU's warning into a refusal, so the test is
# decisive rather than a line in a log nobody reads. It starts a VM with no
# disks, no network and no display, paused, and quits it from the monitor:
# about a tenth of a second, and nothing is written anywhere.
#
# Only meaningful under a hardware accelerator. TCG implements SSE4.1
# itself, so a Woodcrest host would pass this test under TCG and learn
# nothing -- which is why the accelerator is part of the observation.
CPU_LINE='Penryn,+ssse3,+sse4.1,+sse4.2'
qemu_cpu=unknown
qemu_cpu_detail=""
if [ -n "$qemu_path" ] && [ "$qemu_has_penryn" = yes ]; then
    if printf 'quit\n' | "$qemu_bin" -nodefaults -no-user-config -display none \
            -machine "q35,accel=$accel" -cpu "$CPU_LINE,enforce" -S \
            -monitor stdio > "$scratch/cpu.log" 2>&1; then
        qemu_cpu=accepted
    else
        qemu_cpu=rejected
    fi
    qemu_cpu_detail=$(grep -i "doesn't support\|not support\|unsupported" "$scratch/cpu.log" | tr '\n' '; ' || true)
fi

# --- tools, BY TOOL ---------------------------------------------------------
#
# Named by the binary, never by a package. boot/prereqs.sh names Debian
# packages and prints an apt line; the EndeavourOS host in
# docs/test-hosts.md exists precisely to break that assumption, so this
# script must not inherit it. The package manager is reported as a fact
# about the host -- not as a mapping, and never as a command to run.
RUNTIME_TOOLS="qemu-system-x86_64 qemu-img dmg2img kpartx sgdisk rsync xxd openssl curl unzip python3 mkfs.hfsplus bats"
BUILD_TOOLS="gcc make git python3 nasm iasl mcopy mformat sgdisk"
tools_present=""
tools_missing=""
tool_rows=""
for t in $RUNTIME_TOOLS $BUILD_TOOLS; do
    case " $tools_present $tools_missing " in *" $t "*) continue ;; esac
    if command -v "$t" >/dev/null 2>&1; then
        tools_present="$tools_present $t"
        tool_rows="$tool_rows$t	$(command -v "$t")
"
    else
        tools_missing="$tools_missing $t"
        tool_rows="$tool_rows$t	MISSING
"
    fi
done

pkg_manager=none
for p in apt-get pacman brew pkgin dnf zypper emerge apk port; do
    if command -v "$p" >/dev/null 2>&1; then pkg_manager=$p; break; fi
done

bash_version=${BASH_VERSION:-unknown}

# --- levels beyond probe ----------------------------------------------------

build_ok=unknown
media_built=unknown
failed_stage=

boot_fresh=unknown
install_ok=unknown
guest_bus=""
ovmf_sha=""
opencore_sha=""
stage_report=""

# The principal output of each pipeline stage, so a stage that found its
# work already done can be reported as "reused" rather than "ok".
#
# THE DIFFERENCE MATTERS MORE HERE THAN IN THE PIPELINE. build-image.sh is
# resumable on purpose and "already there" is a success for it. For a
# triangulation run it is the opposite: a host that reused media somebody
# else built has not tested that it can build media, and a report that
# said "ok" would be claiming evidence this run does not have.
stage_output() {
    case $1 in
        esd)      printf '%s\n' "$image_dir/media/InstallESD.dmg" ;;
        opencore) printf '%s\n' "${MQG_BUILD_DIR:-$image_dir/build}/artifacts/SHA256SUMS" ;;
        ovmf)     printf '%s\n' "${MQG_BUILD_DIR:-$image_dir/build}/firmware/OVMF_CODE.fd" ;;
        efi)      printf '%s\n' "$image_dir/work/opencore-p3.img" ;;
        media)    printf '%s\n' "$image_dir/media/installer-linux.img" ;;
        *)        printf '\n' ;;
    esac
}

# Stages whose output was already on this host when the run started.
preexisting=""
note_preexisting() {
    local s out
    for s in $1; do
        out=$(stage_output "$s")
        [ -n "$out" ] || continue
        [ -s "$out" ] || continue
        preexisting="$preexisting $s"
    done
}

stage_was_preexisting() {
    case " $preexisting " in *" $1 "*) return 0 ;; esac
    return 1
}

run_stage() {
    local stage=$1 t0 rc=0 result=ok
    t0=$SECONDS
    log "stage $stage"
    if "$MQG_REPO_ROOT/image/build-image.sh" --name "$name" --accel "$pipeline_accel" \
            --generate-ssh-key --stage "$stage" >> "$scratch/pipeline.log" 2>&1; then
        stage_was_preexisting "$stage" && result=reused
        stage_report="$stage_report$stage	$result	$((SECONDS - t0))s
"
    else
        rc=1
        stage_report="$stage_report$stage	FAILED	$((SECONDS - t0))s
"
    fi
    return $rc
}

pipeline_accel=$accel
if [ "$level" != probe ]; then
    # A FINDING, NOT A WORKAROUND. image/build-image.sh validates --accel
    # against kvm|tcg and dies on anything else, so a macOS host with HVF
    # or a NetBSD host with NVMM cannot run the pipeline as its own
    # accelerator today. Recorded here rather than papered over.
    case $accel in
        kvm|tcg) : ;;
        *)
            tri_special "image/build-image.sh --accel accepts only kvm|tcg, so this host's '$accel' cannot drive the pipeline; --build/--full fall back to tcg, which is slower and is NOT a test of '$accel'"
            pipeline_accel=tcg ;;
    esac
    if [ "$image_dir_exists" = no ]; then
        track_created "$image_dir"
    else
        track_created "$image_dir/images/$name.qcow2"
        track_created "$image_dir/images/$name.manifest"
        track_created "$image_dir/work/build-$name"
    fi
    build_ok=yes
    # payload is not on this list: stage_payload has no "already done"
    # check and rebuilds every time, so it is never reused.
    note_preexisting "esd opencore ovmf efi media"
    for s in esd opencore ovmf efi openssh payload media target; do
        run_stage "$s" || build_ok=no
        [ "$build_ok" = yes ] || break
    done
    # WHAT EACH STAGE DID, ASKED OF THE STAGE.
    #
    # Not inferred from build_ok: the loop above stops at the first
    # failure, so build_ok=no means "something failed", not "this failed".
    # Inferring media's fate from it blamed the media path for a compiler
    # error in the opencore stage once already -- see tri_stage_result.
    failed_stage=$(tri_failed_stage "$stage_report")
    case $(tri_stage_result media "$stage_report") in
        reused) media_built=reused ;;
        ok)     media_built=yes ;;
        FAILED) media_built=no ;;
        *)      media_built=not-run ;;
    esac
    if stage_was_preexisting ovmf && stage_was_preexisting efi; then
        boot_fresh=no
    else
        boot_fresh=yes
    fi
    [ -f "${MQG_BUILD_DIR:-$image_dir/build}/firmware/OVMF_CODE.fd" ] \
        && ovmf_sha=$(sha256_file "${MQG_BUILD_DIR:-$image_dir/build}/firmware/OVMF_CODE.fd")
    [ -f "$image_dir/work/opencore-p3.img" ] \
        && opencore_sha=$(sha256_file "$image_dir/work/opencore-p3.img")
fi

if [ "$level" = full ] && [ "$build_ok" = yes ]; then
    install_ok=yes
    for s in install verify manifest; do
        run_stage "$s" || install_ok=no
        [ "$install_ok" = yes ] || break
    done
    # The verify stage asks the guest what it is, diskbus included (for
    # G16); its answer is in the log.
    guest_bus=$(sed -n 's/^ *diskbus=//p' "$scratch/pipeline.log" | first_line || true)
    failed_stage=$(tri_failed_stage "$stage_report")
fi

# --- facts ------------------------------------------------------------------

tri_fact host "$host"
tri_fact os "$os"
tri_fact os_name "$os_name"
tri_fact kernel "$kernel"
tri_fact arch "$arch"
tri_fact bash "$bash_version"
tri_fact system_vendor "$sys_vendor"
tri_fact cpu_brand "$brand"
tri_fact cpu_vendor "$vendor"
tri_fact cpu_cores "$cores"
tri_fact cpu_logical "$logical"
tri_fact cpu_threads_per_core "$threads"
tri_fact flag_ssse3 "$have_ssse3"
tri_fact flag_sse4_1 "$have_sse41"
tri_fact flag_sse4_2 "$have_sse42"
tri_fact flag_vmx "$have_vmx"
tri_fact flag_svm "$have_svm"
tri_fact flag_ept "$have_ept"
tri_fact accel_kvm "$kvm"
tri_fact kvm_note "$kvm_note"
tri_fact accel_hvf "$hvf"
tri_fact accel_nvmm "$nvmm"
tri_fact accel_chosen "$accel"
tri_fact kvm_nested "$nested"
tri_fact kvm_ignore_msrs "$ignore_msrs"
tri_fact ram_mib "$ram"
tri_fact image_dir "$image_dir"
tri_fact image_dir_exists "$image_dir_exists"
tri_fact image_fs "$image_fs"
tri_fact image_free_mib "$free_mib"
tri_fact repo_root "$MQG_REPO_ROOT"
tri_fact repo_fs "$repo_fs"
tri_fact repo_create_ms "$repo_ms"
tri_fact image_create_ms "$local_ms"
tri_fact reflink "$reflink"
tri_fact chattr_nocow "$nocow"
tri_fact qemu "$qemu_path"
tri_fact qemu_version "$qemu_version"
tri_fact qemu_accels "$qemu_accels"
tri_fact qemu_has_penryn "$qemu_has_penryn"
tri_fact qemu_missing_devices "${missing_devices# }"
tri_fact cpu_line "$CPU_LINE"
tri_fact cpu_line_verdict "$qemu_cpu"
tri_fact cpu_line_detail "$qemu_cpu_detail"
tri_fact tools_missing "${tools_missing# }"
tri_fact package_manager "$pkg_manager"
tri_fact level "$level"
tri_fact build_ok "$build_ok"
tri_fact failed_stage "${failed_stage:-none}"
tri_fact media_built "$media_built"
tri_fact install_ok "$install_ok"
tri_fact ovmf_sha256 "$ovmf_sha"
tri_fact opencore_sha256 "$opencore_sha"

# --- judge ------------------------------------------------------------------

add() {
    local entry=$1 line v o
    shift
    line=$("$@")
    v=${line%%	*}
    o=${line#*	}
    tri_ledger "$entry" "$v" "$o"
}

add G1  g1_verdict  "$sys_vendor"
add G2  g2_verdict  "$vendor" "$virt"
add G3  g3_verdict  "$brand" "$have_sse41" "$qemu_cpu"
add G4  g4_verdict  "$cores" "$threads"
add G5  g5_verdict  "$ovmf_sha" "$opencore_sha" "$boot_fresh" "$failed_stage"
add G6  g6_verdict  "$qemu_version"
add G7  g7_verdict  "$kernel"
add G8  g8_verdict  "$ram" "$free_mib"
add G9  g9_verdict  "$repo_fs" "$image_fs"
add G10 g10_verdict "$image_fs" "$reflink"
add G11 g11_verdict "$image_fs" "$nocow"
add G12 g12_verdict "$repo_fs" "$repo_ms" "$local_ms"
add G13 g13_verdict "$devices_ok" "$install_ok"
add G14 g14_verdict "$brand"
add G16 g16_verdict "$guest_bus"
add G17 g17_verdict "$nested"
add G18 g18_verdict "$have_ept"
add G19 g19_verdict
add G20 g20_verdict "$media_built" "$failed_stage"

# --- report -----------------------------------------------------------------

say "mavericks-qemu-guest triangulation report"
say "========================================="
say "level:     $level"
say "generated: $started_at"
say "host:      $host -- $os_name ($os $kernel $arch), bash $bash_version"
say ""
say "## Host"
say ""
printf '%s\n' "$TRI_FACTS" | while IFS='	' read -r k v; do
    [ -n "$k" ] || continue
    printf '  %-22s %s\n' "$k" "$v"
done > "$scratch/facts.txt"
say "$(cat "$scratch/facts.txt")"
say ""
say "## The -cpu line"
say ""
say "  asked for:   $CPU_LINE"
say "  accelerator: $accel"
say "  ssse3 $have_ssse3, sse4.1 $have_sse41, sse4.2 $have_sse42"
say "  QEMU verdict (with 'enforce'): $qemu_cpu"
[ -z "$qemu_cpu_detail" ] || say "  $qemu_cpu_detail"
if [ "$qemu_cpu" = unknown ]; then
    say "  not exercised: no QEMU with a Penryn model on this host"
fi
say ""
say "## Tools -- by tool, never by package name"
say ""
printf '%s' "$tool_rows" | while IFS='	' read -r t p; do
    [ -n "$t" ] || continue
    printf '  %-20s %s\n' "$t" "$p"
done > "$scratch/tools.txt"
say "$(cat "$scratch/tools.txt")"
say ""
say "  package manager present: $pkg_manager (reported as a fact; this"
say "  script maps no tool to any package and prints no install command)"
say ""
if [ -n "$stage_report" ]; then
    say "## Pipeline stages"
    say ""
    printf '%s' "$stage_report" | while IFS='	' read -r s r d; do
        [ -n "$s" ] || continue
        printf '  %-10s %-7s %s\n' "$s" "$r" "$d"
    done > "$scratch/stages.txt"
    say "$(cat "$scratch/stages.txt")"
    say ""
    case $stage_report in
        *FAILED*)
            # The report has to be self-contained: the scratch directory
            # holding the full log is gone by the time anyone reads this,
            # and a report that says "see the log" about a log it deleted
            # is worse than no report.
            say "  The last 25 lines before it stopped:"
            say ""
            tail -25 "$scratch/pipeline.log" 2>/dev/null | sed -e 's/^/    /' \
                > "$scratch/tail.txt" || true
            say "$(cat "$scratch/tail.txt")"
            say "" ;;
    esac
fi
say "## Ledger -- paste these rows into docs/host-profile.md section 4"
say ""
say "| Entry | Verdict | Host | Observation |"
say "|---|---|---|---|"
printf '%s' "$TRI_LEDGER" | while IFS='	' read -r e v o; do
    [ -n "$e" ] || continue
    printf '| %s | %s | %s | %s |\n' "$e" "$v" "$host" "$o"
done > "$scratch/ledger.txt"
say "$(cat "$scratch/ledger.txt")"
say ""
say "  CONFIRM = true here too. REFUTE = the opposite here, so the entry is"
say "  host-specific and whatever depends on it needs a parameter."
say "  CANNOT-SAY = this host, at this level, cannot settle it -- which is a"
say "  result, not a gap: an entry nobody has tried to falsify is not knowledge."
say ""
if [ -n "$TRI_SPECIALS" ]; then
    say "## Where this script had to know what kind of host it was on"
    say ""
    say "  Each line is portability work this project still owes."
    say ""
    printf '%s' "$TRI_SPECIALS" | sed -e 's/^/  - /' > "$scratch/specials.txt"
    say "$(cat "$scratch/specials.txt")"
    say ""
fi

emit_json() {
    printf '{\n'
    printf '  "schema": "mqg-triangulate-1",\n'
    printf '  "generated": "%s",\n' "$(json_escape "$started_at")"
    printf '  "level": "%s",\n' "$(json_escape "$level")"
    printf '  "facts": {\n'
    printf '%s' "$TRI_FACTS" | awk -F'\t' '
        NF >= 1 && $1 != "" { rows[n++] = $0 }
        END {
            for (i = 0; i < n; i++) {
                split(rows[i], f, "\t")
                printf "    \"%s\": \"%s\"%s\n", f[1], f[2], (i < n - 1 ? "," : "")
            }
        }'
    printf '  },\n'
    printf '  "ledger": [\n'
    printf '%s' "$TRI_LEDGER" | awk -F'\t' '
        NF >= 1 && $1 != "" { rows[n++] = $0 }
        END {
            for (i = 0; i < n; i++) {
                split(rows[i], f, "\t")
                printf "    {\"entry\": \"%s\", \"verdict\": \"%s\", \"observation\": \"%s\"}%s\n", \
                    f[1], f[2], f[3], (i < n - 1 ? "," : "")
            }
        }'
    printf '  ],\n'
    printf '  "special_cases": [\n'
    printf '%s' "$TRI_SPECIALS" | awk '
        $0 != "" { rows[n++] = $0 }
        END { for (i = 0; i < n; i++) printf "    \"%s\"%s\n", rows[i], (i < n - 1 ? "," : "") }'
    printf '  ]\n'
    printf '}\n'
}

# JSON values come from command output, so they are escaped before they
# reach the emitter rather than trusted inside it.
escape_accumulators() {
    TRI_FACTS=$(printf '%s' "$TRI_FACTS" | while IFS='	' read -r k v; do
        [ -n "$k" ] || continue
        printf '%s\t%s\n' "$(json_escape "$k")" "$(json_escape "$v")"
    done)
    TRI_LEDGER=$(printf '%s' "$TRI_LEDGER" | while IFS='	' read -r e v o; do
        [ -n "$e" ] || continue
        printf '%s\t%s\t%s\n' "$(json_escape "$e")" "$(json_escape "$v")" "$(json_escape "$o")"
    done)
    TRI_SPECIALS=$(printf '%s' "$TRI_SPECIALS" | while IFS= read -r s; do
        [ -n "$s" ] || continue
        printf '%s\n' "$(json_escape "$s")"
    done)
}

if [ "$want_json" -eq 1 ]; then
    escape_accumulators
    if [ -n "$json_out" ]; then
        emit_json > "$json_out"
        printf '%s' "$report"
        log "JSON written to $json_out"
    else
        emit_json
        printf '%s' "$report" >&2
    fi
else
    printf '%s' "$report"
fi

# A failed --build or --full is a failed run; a probe that found a host
# that cannot do something is not. The report is the deliverable either
# way, so it is printed before this decides anything.
if [ "$build_ok" = no ] || [ "$install_ok" = no ]; then
    die "$level stopped at the '${failed_stage:-unknown}' stage on this host" \
        "-- see the stage table above. Every stage after it never ran, and" \
        "the ledger rows say CANNOT-SAY rather than blaming them"
fi
exit 0
