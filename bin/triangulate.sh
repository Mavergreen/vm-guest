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
#     removes), and at --probe it creates neither of those
#   * it cleans up after itself, and says exactly what it removed and what
#     it left behind
#   * the one thing it deliberately leaves on disk is the run directory in
#     the current directory: the report, the JSON and the build log. That
#     is the deliverable, not a leftover, and it is kilobytes.
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
# shellcheck source=../lib/cpu.sh
. "$MQG_REPO_ROOT/lib/cpu.sh"
# shellcheck source=../lib/smbios.sh
. "$MQG_REPO_ROOT/lib/smbios.sh"

# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=triangulate

level=probe
want_json=0
cpu_choice=
smbios_choice=
json_out=
keep=0
keep_build=0
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
  --keep-build     Leave the BUILD TREE behind, and remove the rest. The
                   boot stack is ~14 minutes of compiling and this script
                   exists to be run again; the images and target disks,
                   which are the gigabytes, still go.
  --cpu MODEL      Guest CPU line for --build/--full, from lib/cpu.sh's
                   table. Needed on any host that cannot provide the
                   default: the probe's -cpu table says which rows this
                   machine accepts.
  --smbios MODEL   SMBIOS SystemProductName for --build/--full. The
                   default is what every image this project has shipped
                   was built with; --smbios MacPro5,1 is the G14
                   experiment, and it is opt-in because it deliberately
                   builds an image we expect to panic (lib/smbios.sh).
  --name NAME      Name for the image --full builds.
  --qemu BINARY    QEMU to interrogate (default: $qemu_bin).
  -h, --help       This.

Every run, at every level, writes what it found into
./triangulate-logs-<host>-<stamp>/ -- report.txt, report.json,
pipeline.log, and any build logs salvaged from a failed stage. The
directory's path is printed at the start, so that pipeline.log can be
followed with tail -f while a long run is going, and again as the last
line, so that it cannot be missed. --json still writes JSON to stdout and
nothing else, for piping.

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
        --keep-build) keep_build=1 ;;
        --cpu)   cpu_choice=$2; shift ;;
        --smbios) smbios_choice=$2; shift ;;
        --name)  name=$2; shift ;;
        --qemu)  qemu_bin=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

# Refused at the door, before any probe and long before any firmware.
# image/build-image.sh refuses the same strings for the same reason, but a
# triangulation run spends minutes probing before it ever calls the
# pipeline, and a typo should not survive that long. An unknown MODEL is
# fine and warns; a string that cannot go into a plist is not.
if [ -n "$smbios_choice" ] && ! smbios_wellformed "$smbios_choice"; then
    die "unusable --smbios '$smbios_choice': letters, digits, comma, dot," \
        "dash and underscore only, 64 characters at most"
fi
smbios_used=${smbios_choice:-$MQG_SMBIOS_DEFAULT}

name=${name:-triangulate-$(date -u +%Y%m%d-%H%M%S)}

# The human report goes to stdout unless --json has taken stdout for the
# machine-readable one. Everything the report prints goes through say().
report=""
say() { report="$report$*
"; }

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run_stamp=$(date -u +%Y%m%d-%H%M%S)
# Set for real below, once the hostname is known. Declared here because the
# EXIT trap and salvage_logs both read them and either can fire first.
run_dir=
pipeline_log=

# --- a scratch directory that always goes away -----------------------------

scratch=$(mktemp -d "${TMPDIR:-/tmp}/mqg-triangulate.XXXXXX") \
    || die "cannot create a scratch directory"
# Tracked separately from the scratch directory: things created under
# $MQG_IMAGE_DIR by --build and --full, which a user may want to keep.
created_list=$scratch/created
: > "$created_list"

# Copy build logs somewhere that survives cleanup.
#
# This exists because of a self-inflicted wound on squirrel-zapper
# 2026-09-20: the ovmf stage failed, the report printed its 25-line tail,
# the final line said "report the error rather than working around it" --
# and then cleanup deleted $MQG_IMAGE_DIR, taking ovmf-build.log with it.
# The one artifact needed to diagnose the failure was destroyed by the
# script that had just asked for it, and the cost was a second eleven-minute
# run on someone else's laptop.
#
# A cleanup that runs on failure must not remove the evidence of the
# failure. Logs are kilobytes; the build trees they sit in are gigabytes,
# so --keep (which keeps everything) is the wrong instrument for this.
# shellcheck disable=SC2317  # reached through the EXIT/INT/TERM trap below
salvage_logs() {
    local dest n=0 f
    [ -s "$created_list" ] || return 0
    # The run directory, which already holds pipeline.log and is about to
    # hold report.txt and report.json. One directory per run rather than a
    # second one stamped at the second the failure happened: a reader
    # should not have to work out which of two directories is the run.
    dest=$run_dir
    if [ -z "$dest" ]; then
        dest="$PWD/triangulate-logs-$(hostname 2>/dev/null || echo host)"
        dest="$dest-$(date -u +%Y%m%d-%H%M%S)"
    fi
    while IFS= read -r p; do
        if [ -z "$p" ] || [ ! -d "$p" ]; then
            continue
        fi
        # -type f and a size cap: a build tree can contain a log of any
        # size, and this is meant to be small enough to paste or mail.
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            mkdir -p "$dest" || return 0
            cp "$f" "$dest/" 2>/dev/null && n=$((n + 1))
        done <<EOF
$(find "$p" -type f -name '*.log' -size -8M 2>/dev/null)
EOF
    done <<EOF
$(printf '%s\n' "${salvage_extra:-}"; cat "$created_list")
EOF
    # pipeline.log holds every stage's stdout AND stderr (see the redirect
    # on the build-image.sh call). It used to live in $scratch, which
    # cleanup deletes unconditionally, so the single file holding the
    # actual failure was the one file guaranteed not to survive it. The
    # report's 25-line tail is a window onto this log; when the error falls
    # past the edge of that window, as a microVM failure did on
    # squirrel-zapper on 2026-09-20, there was nothing left to read.
    # Since this run directory exists from the start, pipeline.log is
    # normally written straight into it and there is nothing to copy. The
    # copy remains for the fallback case where the directory could not be
    # created and the log went to $scratch after all.
    if [ -f "${pipeline_log:-$scratch/pipeline.log}" ] \
       && [ "${pipeline_log:-}" != "$dest/pipeline.log" ]; then
        mkdir -p "$dest" 2>/dev/null || true
        cp "${pipeline_log:-$scratch/pipeline.log}" "$dest/" 2>/dev/null \
            && n=$((n + 1))
    fi
    # The report is the deliverable, and until 2026-09-20 it went only to
    # stdout -- so a failed run on someone else's machine left build logs
    # saying every stage succeeded, and the stage table naming the one that
    # did not was visible on their terminal and nowhere else. Write it
    # beside the logs. This also covers a stage that fails without
    # producing a .log at all, which is why $dest is created even when
    # n is 0. write_evidence writes it again, with the stage table filled
    # in; this copy is the one that exists if anything below goes wrong.
    if [ -n "${report:-}" ]; then
        mkdir -p "$dest" 2>/dev/null || true
        if printf '%s' "${report:-}" > "$dest/report.txt" 2>/dev/null; then
            n=$((n + 1))
        fi
    fi
    if [ "$n" -gt 0 ]; then
        printf 'triangulate: saved %d file(s) to %s\n' "$n" "$dest" >&2
        printf 'triangulate: these survive the cleanup below. report.txt has the\n' >&2
        printf 'triangulate: stage table; the .log files have the compiler output.\n' >&2
        printf 'triangulate: send the directory, not a summary of it.\n' >&2
    fi
}

# $MQG_IMAGE_DIR ITSELF, WHEN THIS RUN IS WHAT CREATED IT.
#
# Leaving a host as it was found is the right default and stays the
# default: this script runs on other people's machines, and one of them is
# a Mac Pro serving files.
#
# But that default used to be the only behaviour, and it threw away the
# BUILD TREE with everything else -- about fourteen minutes of compiling --
# on every run of a script whose entire purpose is repeated runs. So
# --keep-build is the middle setting: the images and the target disks,
# which are the gigabytes, still go; the build tree stays, and the next run
# skips the opencore and ovmf stages.
#
# Kept as a decision made HERE rather than as a path in $created_list,
# because the thing to spare lives inside the thing to remove.
# shellcheck disable=SC2317  # reached through the EXIT/INT/TERM trap below
cleanup_image_dir() {
    local e
    [ "$image_dir_exists" = no ] || return 0
    [ -d "$image_dir" ] || return 0
    if [ "$keep" -eq 1 ]; then
        printf 'triangulate: --keep: left behind:\n  %s\n' "$image_dir" >&2
        return 0
    fi
    if [ "$keep_build" -eq 0 ]; then
        rm -rf "$image_dir" && printf 'triangulate: removed %s\n' "$image_dir" >&2
        return 0
    fi
    for e in "$image_dir"/* "$image_dir"/.[!.]*; do
        [ -e "$e" ] || continue
        [ "$e" != "$build_dir" ] || continue
        rm -rf "$e" && printf 'triangulate: removed %s\n' "$e" >&2
    done
    printf 'triangulate: --keep-build: kept %s\n' "$build_dir" >&2
}

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
    cleanup_image_dir
    rm -rf "$scratch"
    # THE LAST LINE, after all the removal chatter, because a path printed
    # before a screenful of "removed ..." is a path nobody sees.
    if [ -n "${run_dir:-}" ] && [ -d "${run_dir:-}" ]; then
        printf 'triangulate: this run is written down here:\n  %s\n' \
            "$run_dir" >&2
    fi
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

# Processors the kernel could use if they all answered. /proc/cpuinfo
# lists only the ONLINE ones, so a machine with a dead core reports fewer
# than it has and nothing says why.
cpu_present() {
    case $os in
        Linux)
            if [ -r /sys/devices/system/cpu/present ]; then
                # "0-3" or "0-2,4" -> a count
                awk -F, '{ n=0; for (i=1;i<=NF;i++) { split($i,r,"-");
                    n += (r[2] == "" ? 1 : r[2]-r[1]+1) } print n }' \
                    /sys/devices/system/cpu/present
            else
                printf '0'
            fi ;;
        *) printf '0' ;;
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

# --- where this run is written down ----------------------------------------
#
# EVERY RUN LEAVES ITS EVIDENCE, NOT ONLY THE ONES THAT FAIL.
#
# The report went to stdout and was copied to a file only on the failure
# path, so a SUCCESSFUL run left nothing at all. The ledger rows -- which
# docs/test-hosts.md calls the actual deliverable, "not 'it worked' or 'it
# didn't', but an updated ledger" -- existed only as scrollback on the
# terminal of whoever typed the command, and getting them back meant
# asking that person to paste a result that had already been produced.
#
# AND A RUN IN PROGRESS WAS OPAQUE TO EVERYONE BUT THAT PERSON.
#
# pipeline.log lived in a mktemp -d under /tmp, on that host, deleted at
# the end. Watching a two-hour --full on another machine meant asking the
# user to find a path they had to discover first. It is written here from
# the start instead, at a name anyone can predict and tail -f.
#
# The existing triangulate-logs-<host>-<stamp>/ name is reused rather than
# invented afresh: .gitignore already covers it, docs/triangulation already
# refers to directories with that name, and one directory per run means a
# failure appends to the run's own directory instead of creating a second
# one stamped at a different second. The name says "logs" and the contents
# are now more than logs -- but they have been since report.txt joined them
# on 2026-09-20, so the name was already the narrower half of the truth.
run_dir="$PWD/triangulate-logs-$host-$run_stamp"
if mkdir -p "$run_dir" 2>/dev/null && : > "$run_dir/pipeline.log" 2>/dev/null
then
    pipeline_log=$run_dir/pipeline.log
    log "evidence:  $run_dir"
    log "watch it:  tail -f $pipeline_log"
else
    # Say it, rather than failing or pretending. A read-only working
    # directory is a reason this run produces no artifact, and the person
    # who has to copy their terminal by hand should be told now and not
    # discover it at the end.
    warn "cannot create $run_dir -- this run will leave NO evidence" \
        "behind, and the report will exist only on this terminal." \
        "Run it from a writable directory to get one."
    run_dir=
    pipeline_log=$scratch/pipeline.log
fi

brand=$(cpu_brand || true); brand=${brand:-unknown}
vendor=$(cpu_vendor || true); vendor=${vendor:-unknown}
flags=$(cpu_flags || true)
cores=$(cpu_cores || echo 0)
logical=$(cpu_logical || echo 0)
# ap-juicer 2026-09-21 reported 4 cores and 3 logical CPUs, which reads as
# a parsing bug and is not one: "CPU3 failed to report alive state" in
# dmesg -- a core that did not come up. A host quietly running on less
# hardware than it has is a triangulation fact, not a footnote: it changes
# every timing this project records there.
present=$(cpu_present 2>/dev/null || echo 0)
cpu_offline=none
if [ "$present" -gt 0 ] 2>/dev/null && [ "$logical" -gt 0 ] 2>/dev/null \
   && [ "$present" -gt "$logical" ]; then
    cpu_offline=$((present - logical))
    tri_special "this host has $present processors but only $logical are online: $cpu_offline offline. Check 'lscpu' and dmesg for why -- a core that failed to start makes every timing here slower than the hardware implies"
fi
# threads-per-core, guarded. `cpu_cores` reads the topology (cpu cores x
# sockets) while `cpu_logical` counts ONLINE processors, so the two are not
# comparable and their ratio can be nonsense: ap-juicer reported 4 cores, 3
# logical and therefore 0 threads per core, which describes no machine.
# Prefer /proc/cpuinfo's own per-socket `siblings`, and where the numbers
# disagree say unknown rather than print a quotient nobody can act on.
threads=unknown
if [ "$os" = Linux ] && [ -r /proc/cpuinfo ]; then
    sib=$(awk -F': *' '/^siblings/ { print $2; exit }' /proc/cpuinfo)
    percore=$(awk -F': *' '/^cpu cores/ { print $2; exit }' /proc/cpuinfo)
    if [ -n "$sib" ] && [ -n "$percore" ] && [ "$percore" -gt 0 ] 2>/dev/null; then
        threads=$((sib / percore))
    fi
fi
if [ "$threads" = unknown ] || [ "$threads" -lt 1 ] 2>/dev/null; then
    if [ "$cores" -gt 0 ] 2>/dev/null && [ "$logical" -ge "$cores" ] 2>/dev/null; then
        threads=$((logical / cores))
    else
        threads=unknown
    fi
fi
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
# The expensive half: fetched tarballs, the assembled EDK II tree, the
# OpenCore and OVMF artifacts. --keep-build is about this directory and
# nothing else.
build_dir=${MQG_BUILD_DIR:-$image_dir/build}
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
DEVICES="ich9-usb-ehci1 ich9-usb-uhci1 ich9-usb-uhci2 ich9-usb-uhci3 usb-storage usb-net e1000-82545em virtio-net-pci usb-kbd usb-mouse usb-tablet ide-hd VGA"
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
#
# 2026-09-21: the prediction was half right and the conclusion drawn from
# it was wrong. A Woodcrest host really cannot provide SSE4.1 -- but 10.9
# does not need it. `-cpu Conroe` boots this guest to SSH (lib/cpu.sh,
# docs/decisions/0009), so a host that fails the line below is not a host
# that cannot run this project; it is a host that needs a different row of
# the table. Which is why the probe no longer asks about one line.

# cpu_line_accepted <cpu line> -- "accepted", "rejected" or "no-model".
#
# `enforce` is what turns QEMU's "does not support" warning into a refusal.
# A paused VM with no disks, no network and no display, quit from the
# monitor: about a tenth of a second each, and nothing is written anywhere.
cpu_line_accepted() {
    local line=$1 base
    base=$(cpu_model_base "$line")
    case $qemu_cpu_models in
        *"$base"*) : ;;
        *) printf 'no-model\n'; return 0 ;;
    esac
    if printf 'quit\n' | "$qemu_bin" -nodefaults -no-user-config -display none \
            -machine "q35,accel=$accel" -cpu "$line,enforce" -S \
            -monitor stdio > "$scratch/cpu-probe.log" 2>&1; then
        printf 'accepted\n'
    else
        printf 'rejected\n'
    fi
}

CPU_LINE=$MQG_CPU_DEFAULT
qemu_cpu=unknown
qemu_cpu_detail=""
qemu_cpu_models=""
[ -z "$qemu_path" ] || qemu_cpu_models=$("$qemu_bin" -cpu help 2>/dev/null || true)
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

# THE SAME TEST, ACROSS THE WHOLE TABLE.
#
# lib/cpu.sh lists the -cpu lines this project has evidence for. Which of
# them a given host can actually PROVIDE is a different question from which
# ones Mavericks can use, and it is a question the host can answer in about
# a second without anyone installing anything on it. That is the point: the
# Mac Pro 1,1 in docs/test-hosts.md has been written off for a year on a
# prediction, and `bin/triangulate.sh --probe` there now settles it in two
# minutes.
#
# Only meaningful under a hardware accelerator, and the accelerator is
# therefore reported beside the result. TCG implements SSE4.1 itself, so a
# Woodcrest host would accept every row under TCG and learn nothing.
cpu_table_results=""
cpu_provided=""
cpu_refused=""
cpu_no_model=""
cpu_refused_why=""
if [ -n "$qemu_path" ]; then
    while IFS= read -r cpu_row; do
        [ -n "$cpu_row" ] || continue
        cpu_row_result=$(cpu_line_accepted "$cpu_row")
        cpu_row_why=""
        case $cpu_row_result in
            accepted) cpu_provided="$cpu_provided $cpu_row" ;;
            no-model) cpu_no_model="$cpu_no_model $cpu_row" ;;
            rejected)
                cpu_refused="$cpu_refused $cpu_row"
                # WHICH FEATURE, NOT JUST "NO".
                #
                # A bare "rejected" invites the reader to assume the host is
                # too old, and on the primary host that assumption is wrong:
                # `qemu64` is refused on an Intel machine because QEMU's own
                # qemu64 model asks for `svm`, which is AMD's. A rejection
                # that does not name the feature is a rejection anyone can
                # misread, and misreading this exact kind of evidence is what
                # docs/test-hosts.md did to the Mac Pro 1,1.
                cpu_row_why=$(sed -n 's/.*requested feature: \([^ ]*\).*/\1/p' \
                    "$scratch/cpu-probe.log" | tr '\n' ',' | sed -e 's/,$//')
                cpu_refused_why="$cpu_refused_why; $cpu_row needs ${cpu_row_why:-an unnamed feature} this host does not have"
                ;;
        esac
        cpu_table_results="$cpu_table_results$cpu_row	$cpu_row_result	$cpu_row_why
"
    done <<EOF
$(cpu_model_lines)
EOF
fi

# --- tools, BY TOOL ---------------------------------------------------------
#
# Named by the binary, never by a package. boot/prereqs.sh names Debian
# packages and prints an apt line; the EndeavourOS host in
# docs/test-hosts.md exists precisely to break that assumption, so this
# script must not inherit it. The package manager is reported as a fact
# about the host -- not as a mapping, and never as a command to run.
RUNTIME_TOOLS="qemu-system-x86_64 qemu-img dmg2img sgdisk xxd openssl curl unzip python3 mkfs.hfsplus bats"
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

# --- which code produced this result ---------------------------------------
#
# Several of this project's triangulation runs have been made from a
# working tree shared over NFS rather than from a clone: /home/schmonz/
# trees/... on one host and /home/schmonz/Documents/trees/... on another
# are the same files. Two things follow, and both have already happened.
#
#   * A run picks up whatever is on disk when it starts, including another
#     machine's uncommitted mid-edit. That nearly happened on 2026-09-20,
#     and on 2026-09-21 a commit landed DURING a run and changed its
#     behaviour in flight -- helpfully that time, by accident.
#   * docs/decisions/0006 claims a fresh clone reproduces the image. A run
#     from the shared tree does not test that claim while looking exactly
#     like a run that does.
#
# So the report records the commit and whether the tree was dirty, the same
# kind of fact as the host and the kernel. A result that cannot be traced
# to a particular state of the code is worth much less than one that can.
#
# Three answers, not two: 'clean', 'DIRTY', and 'unknown' for no git or no
# repository -- which is the same distinction bin/image-staleness.sh makes
# between "I cannot tell" and "it is fine", and for the same reason.
repo_commit=unknown
repo_dirty=unknown
repo_changes=0
if command -v git >/dev/null 2>&1 \
   && git -C "$MQG_REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    repo_commit=$(git -C "$MQG_REPO_ROOT" rev-parse HEAD 2>/dev/null \
        || echo unknown)
    repo_status=$(git -C "$MQG_REPO_ROOT" status --porcelain 2>/dev/null \
        || true)
    if [ -z "$repo_status" ]; then
        repo_dirty=clean
    else
        repo_dirty=DIRTY
        repo_changes=$(printf '%s\n' "$repo_status" | grep -c . || true)
    fi
fi
case $repo_dirty in
    DIRTY)
        warn "the working tree at $MQG_REPO_ROOT is DIRTY:" \
            "$repo_changes path(s) differ from $repo_commit. This result" \
            "will not be traceable to any committed state." ;;
    unknown)
        warn "no git repository at $MQG_REPO_ROOT, so which code produced" \
            "this run cannot be determined. That is not the same as clean." ;;
esac

# --- levels beyond probe ----------------------------------------------------

build_ok=unknown
media_built=unknown
media_failure_kind=unknown
media_failure=
failed_stage=

boot_fresh=unknown
install_ok=unknown
guest_bus=""
# The last thing the pipeline said was on the guest's screen, verbatim from
# vm/screenshot.sh. Empty unless a boot was attempted and long enough for a
# screenshot. A KERNEL PANIC IS ONLY EVER ON THE SCREEN -- it reaches no
# log and no exit status -- so this is the only trace of one a report can
# carry, and it is carried as a description and never as a verdict: "2
# colours, text" is what a panic looks like AND what a boot picker looks
# like. G14 is the entry that needs it.
guest_screen=""
ovmf_sha=""
opencore_sha=""
stage_report=""

# WHICH STAGES WILL SKIP, ASKED OF THE PIPELINE RATHER THAN OF THE DISK.
#
# A stage that found its work already done is reported as "reused" rather
# than "ok".
#
# THE DIFFERENCE MATTERS MORE HERE THAN IN THE PIPELINE. build-image.sh is
# resumable on purpose and "already there" is a success for it. For a
# triangulation run it is the opposite: a host that reused media somebody
# else built has not tested that it can build media, and a report that
# said "ok" would be claiming evidence this run does not have.
#
# This used to look for the output FILE, which was the same question
# build-image.sh asked. It no longer is: a stage now reruns when the inputs
# it recorded stop matching, so an output that is present but stale gets
# rebuilt -- and a report that called that "reused" would be crediting this
# host with work it did do. So ask build-image.sh itself, once, before any
# stage runs. --freshness touches nothing.
preexisting=""
note_preexisting() {
    local s
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        preexisting="$preexisting $s"
    done <<EOF
$("$MQG_REPO_ROOT/image/build-image.sh" --name "$name" \
    --accel "$pipeline_accel" ${cpu_choice:+--cpu "$cpu_choice"} \
    ${smbios_choice:+--smbios "$smbios_choice"} \
    --freshness 2>>"$pipeline_log" \
  | awk -F'\t' '$2 == "skip" { print $1 }' || true)
EOF
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
            ${cpu_choice:+--cpu "$cpu_choice"} \
            ${smbios_choice:+--smbios "$smbios_choice"} \
            --generate-ssh-key --stage "$stage" >> "$pipeline_log" 2>&1; then
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
    # What this run makes, one path at a time. $MQG_IMAGE_DIR itself is
    # NOT tracked here even when this run created it: whether the whole
    # directory goes is decided in cleanup_image_dir, which is where
    # --keep-build can spare the build tree inside it.
    track_created "$image_dir/images/$name.qcow2"
    track_created "$image_dir/images/$name.manifest"
    track_created "$image_dir/work/build-$name"
    # The build tree is where build.log and ovmf-build.log are, and a
    # cleanup that runs on failure must not remove the evidence of the
    # failure. It is no longer in $created_list, so salvage_logs is told
    # about it separately.
    salvage_extra=$build_dir

    # Refuse before the firmware, not after it.
    #
    # ap-juicer 2026-09-21: a Woodcrest Xeon that rejects the default
    # -cpu line for want of SSE4.1. Without this check, --full there
    # compiles OpenCore and OVMF for about fourteen minutes and only
    # then fails at the install, on the slowest host in the fleet, for a
    # reason the probe already knew before it started.
    #
    # The remedy is named rather than applied. Choosing a row of
    # lib/cpu.sh's table is the user's decision -- picking one silently
    # would bury the fact that this host cannot run what the others do,
    # which is precisely the finding triangulation exists to surface.
    if [ -z "$cpu_choice" ] && [ "$qemu_cpu" = rejected ]; then
        warn "this host refuses the default -cpu line:"
        warn "  $MQG_CPU_DEFAULT"
        if [ -n "${cpu_provided# }" ]; then
            warn "rows of lib/cpu.sh's table this host DOES accept:"
            for m in ${cpu_provided# }; do warn "  $m"; done
            warn "re-run with --cpu <one of those>. 10.9 does not need"
            warn "SSE4.1 -- see docs/decisions/0009 -- so a refused"
            warn "default is a parameter to change, not a dead host."
        else
            warn "and no row of the table either -- see the -cpu section above"
        fi
        die "refusing to build for an hour and fail at the install stage"
    fi

    build_ok=yes
    # Every stage at once, and payload included: it used to rebuild on
    # every run because it had no "already done" check at all, and now it
    # records its inputs like the rest.
    note_preexisting
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
    # WHY the media stage failed, not just that it did. G20 is a claim
    # about media corruption, and only the post-unmount verification can
    # speak to it; a media stage that stopped for any other reason is not
    # evidence. See tri_media_failure_kind.
    if [ "$media_built" = no ]; then
        media_failure_kind=$(tri_media_failure_kind "$pipeline_log")
        media_failure=$(tri_media_failure_reason "$pipeline_log")
    fi
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
    guest_bus=$(sed -n 's/^ *diskbus=//p' "$pipeline_log" | first_line || true)
    guest_screen=$(grep 'lit px' "$pipeline_log" 2>/dev/null \
        | sed -e 's/^ *//' -e 's/  */ /g' | tail -1 || true)
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
tri_fact cpu_offline "$cpu_offline"
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
tri_fact repo_commit "$repo_commit"
tri_fact repo_dirty "$repo_dirty"
tri_fact repo_uncommitted "$repo_changes"
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
tri_fact guest_screen "${guest_screen:-none}"
tri_fact smbios "$smbios_used"
tri_fact smbios_verdict "$(smbios_verdict "$smbios_used" | cut -f1)"
tri_fact cpu_line "$CPU_LINE"
tri_fact cpu_line_verdict "$qemu_cpu"
tri_fact cpu_line_detail "$qemu_cpu_detail"
tri_fact cpu_models_provided "${cpu_provided# }"
tri_fact cpu_models_refused "${cpu_refused# }"
tri_fact cpu_models_absent "${cpu_no_model# }"
tri_fact tools_missing "${tools_missing# }"
tri_fact package_manager "$pkg_manager"
tri_fact level "$level"
tri_fact build_ok "$build_ok"
tri_fact failed_stage "${failed_stage:-none}"
tri_fact media_built "$media_built"
tri_fact media_failure "${media_failure:-none}"
tri_fact install_ok "$install_ok"
# What this run leaves on the host, machine-readably: the human report says
# it in the "What stays on this host" section, and a user diffing several
# hosts should not have to read prose to find out which of them still has a
# build tree.
# An if, not an && || chain. As written before 2026-09-21 this was
#   [ "$level" = probe ] && echo n/a || { ... } && echo yes || echo no
# and on a probe `echo n/a` SUCCEEDS, so the trailing `&& echo yes` ran
# too: the value became "n/a\nyes" and the report printed a second line
# with no fact name on it. Found on ap-juicer, the third host. Same
# SC2015 shape shellcheck flags elsewhere in this repo -- it did not
# reach inside the command substitution.
if [ "$level" = probe ]; then
    build_tree_kept=n/a
elif [ "$keep" -eq 1 ] || [ "$keep_build" -eq 1 ] || [ "$image_dir_exists" = yes ]; then
    build_tree_kept=yes
else
    build_tree_kept=no
fi
tri_fact build_tree_kept "$build_tree_kept"
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
add G14 g14_verdict "$brand" "$smbios_used" "$install_ok" "${failed_stage:-}" "$guest_screen"
add G16 g16_verdict "$guest_bus"
add G17 g17_verdict "$nested"
add G18 g18_verdict "$have_ept"
add G19 g19_verdict
add G20 g20_verdict "$media_built" "$failed_stage" "$media_failure_kind" "$media_failure"
add G21 g21_verdict "$ignore_msrs" "$install_ok"
add G26 g26_verdict "$media_failure" "$media_built"
add G24 g24_verdict "$missing_devices" "$install_ok" "$qemu_version"
add G25 g25_verdict "$qemu_version" "$accel" "${cpu_provided# }" "${cpu_refused# }" "${cpu_no_model# }" "${cpu_refused_why#; }"

# --- report -----------------------------------------------------------------

say "mavericks-qemu-guest triangulation report"
say "========================================="
say "level:     $level"
say "generated: $started_at"
say "host:      $host -- $os_name ($os $kernel $arch), bash $bash_version"
say "code:      $repo_commit ($repo_dirty) in $MQG_REPO_ROOT ($repo_fs)"
say ""
case $repo_dirty in
    DIRTY)
        say "  !! THE WORKING TREE WAS DIRTY: $repo_changes path(s) differ from"
        say "     HEAD. Nothing here is traceable to a commit anyone else can"
        say "     check out. If this tree is shared -- an NFS export mounted at"
        say "     a different path on another machine is still the same files --"
        say "     another host may have been editing it while this ran. And a"
        say "     run from a shared tree does not test the fresh clone that"
        say "     docs/decisions/0006 is about, while looking like one that does."
        say "" ;;
    unknown)
        say "  !! NO GIT REPOSITORY WAS FOUND HERE, so which code produced this"
        say "     cannot be determined. That is a third answer, not a synonym"
        say "     for clean."
        say "" ;;
esac
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
say "## Which of the tested -cpu lines this host can provide"
say ""
say "  lib/cpu.sh lists the lines this project has evidence for. This is"
say "  the other half: which of them THIS host and THIS QEMU can hand to a"
say "  guest, asked with 'enforce' against a paused diskless VM."
say ""
say "  Mavericks does not need SSE4.1 -- '-cpu Conroe' boots it to SSH"
say "  (docs/decisions/0009) -- so a refused line is not a refused host."
say "  It says which row of the table this machine should use."
say ""
if [ -z "$qemu_path" ]; then
    say "  not exercised: no QEMU on this host"
else
    printf '%s' "$cpu_table_results" | while IFS='	' read -r m r w; do
        [ -n "$m" ] || continue
        printf '  %-32s %-9s %s\n' "$m" "$r" "${w:+missing: $w}"
    done > "$scratch/cputable.txt"
    say "$(cat "$scratch/cputable.txt")"
    say ""
    say "  accelerator: $accel"
    if [ "$accel" != kvm ]; then
        say "  NOTE: under $accel these results are about the emulator, not the"
        say "  host CPU. TCG implements SSE4.1 itself, so every row passes and"
        say "  nothing is learned about what this machine can provide."
    fi
    say "  no-model = this QEMU has no such CPU model at all, which is a"
    say "  statement about the QEMU and not about the hardware."
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
            tail -25 "$pipeline_log" 2>/dev/null | sed -e 's/^/    /' \
                > "$scratch/tail.txt" || true
            say "$(cat "$scratch/tail.txt")"
            say "" ;;
    esac
fi

# WHAT THIS RUN IS ABOUT TO LEAVE BEHIND, AND WHAT THAT BUYS THE NEXT ONE.
#
# The cleanup itself prints line by line as it removes things, but that
# scrolls past and is not in the saved report. A run on somebody else's
# machine has to end with a plain statement of what is still on their disk.
if [ "$level" != probe ]; then
    say "## What stays on this host"
    say ""
    if [ "$keep" -eq 1 ]; then
        say "  --keep: everything this run created stays, including the"
        say "  images and the target disks. Nothing is removed."
    elif [ "$image_dir_exists" = yes ]; then
        say "  $image_dir was already here and is not this run's to remove."
        say "  Going: this run's image, its manifest and its work directory."
        say "  Staying: $build_dir, which was not ours either."
        say "  A second run skips the opencore and ovmf stages if that tree"
        say "  still matches the pins -- build-image.sh --freshness says."
    elif [ "$keep_build" -eq 1 ]; then
        say "  --keep-build: $build_dir stays -- about 1.5 GB of fetched"
        say "  sources, the assembled EDK II tree and the built firmware."
        say "  Everything else this run created under $image_dir goes,"
        say "  including the images and the target disks."
        say "  A SECOND RUN THEREFORE SKIPS: opencore and ovmf, roughly"
        say "  fourteen minutes of compiling. It still fetches the ESD and"
        say "  rebuilds the EFI image, the payload and the installer media,"
        say "  which is where the gigabytes are."
    else
        say "  Nothing. $image_dir did not exist before this run and does"
        say "  not exist after it -- including $build_dir, so the next run"
        say "  recompiles the boot stack from scratch (~14 min)."
        say "  --keep-build keeps that tree and nothing else."
    fi
    say ""
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

say "## Where this run is written down"
say ""
if [ -n "$run_dir" ]; then
    say "  $run_dir"
    say ""
    say "  report.txt    this, in full"
    say "  report.json   the same facts and ledger rows, machine-readable"
    say "  pipeline.log  every stage's stdout and stderr, written as the run"
    say "                goes, so 'tail -f' on it follows a run in progress"
    if [ "$level" = probe ]; then
        say "                -- empty here, because --probe runs no stages"
    fi
    say "  *.log         build logs, salvaged out of the build trees before"
    say "                the cleanup removed them, when a stage failed"
    say ""
    say "  Send the directory, not a summary of it. The ledger rows above"
    say "  are what a triangulation run is for, and they are in report.txt"
    say "  whether this run succeeded or failed."
else
    say "  NOWHERE. The working directory could not be written to, so this"
    say "  report exists only on the terminal that produced it. Re-run from"
    say "  a writable directory if it needs to reach anybody else."
fi
say ""

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

# The accumulators are escaped exactly once, and now always: the JSON goes
# into the run directory whether or not anybody asked for it on stdout.
escape_accumulators

# --json means stdout is JSON and nothing but JSON, for whoever is piping
# it. Unchanged.
if [ "$want_json" -eq 1 ]; then
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

# Written whether this run succeeded or failed, which is the whole point:
# a success used to leave nothing, and the ledger rows are the deliverable
# either way.
write_evidence() {
    [ -n "$run_dir" ] || return 0
    mkdir -p "$run_dir" 2>/dev/null || return 0
    printf '%s' "$report" > "$run_dir/report.txt" 2>/dev/null \
        || warn "could not write $run_dir/report.txt"
    emit_json > "$run_dir/report.json" 2>/dev/null \
        || warn "could not write $run_dir/report.json"
}
write_evidence

# A failed --build or --full is a failed run; a probe that found a host
# that cannot do something is not. The report is the deliverable either
# way, so it is printed before this decides anything.
if [ "$build_ok" = no ] || [ "$install_ok" = no ]; then
    # Before the EXIT trap removes the build trees. The stage tail printed
    # in the report is 25 lines; the log is the whole story.
    salvage_logs
    die "$level stopped at the '${failed_stage:-unknown}' stage on this host" \
        "-- see the stage table above. Every stage after it never ran, and" \
        "the ledger rows say CANNOT-SAY rather than blaming them"
fi
exit 0
