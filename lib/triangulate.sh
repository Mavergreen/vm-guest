# shellcheck shell=bash
# The judging half of bin/triangulate.sh.
#
# Gathering host facts and deciding what they mean are separated for the
# same reason lib/preconditions.sh separates them: the deciding can then be
# tested here, on this host, against facts from hosts nobody has. Every
# function below is pure -- it takes facts as arguments and prints a
# verdict. Nothing here reads /proc, runs a command, or touches a disk.
#
# Requires lib/common.sh to be sourced first.
#
# VOCABULARY
#
# A ledger entry (docs/host-profile.md section 4) is a hypothesis about
# this project's primary host. A second host can do one of three things to
# it, and the report says which:
#
#   CONFIRM     the same thing is true here, so the entry is portable or
#               the primary host is not special in the way it claimed
#   REFUTE      the opposite is true here, so the entry is host-specific
#               and whatever depends on it needs a parameter
#   CANNOT-SAY  this host cannot settle it at this level -- either the
#               claim is about the guest and no guest was booted, or the
#               experiment was never run
#
# "CANNOT-SAY" is a result, not a failure. An entry nobody has tried to
# falsify is not knowledge, and an entry a run could not reach should say
# so out loud rather than be quietly absent.

# --- accumulators ----------------------------------------------------------
#
# Plain newline-separated strings with tab-separated fields, not arrays of
# structs and not associative arrays: bash 3.2 has neither, and 10.9 ships
# bash 3.2. See bin/bash32-check.sh.

TRI_FACTS=""
TRI_LEDGER=""
TRI_SPECIALS=""

# tri_fact <key> <value>
tri_fact() {
    TRI_FACTS="$TRI_FACTS$1	$2
"
}

# tri_fact_get <key> -- the value, or empty
tri_fact_get() {
    printf '%s\n' "$TRI_FACTS" | awk -F'\t' -v k="$1" '$1 == k { print $2; exit }'
}

# tri_ledger <entry> <verdict> <observation>
tri_ledger() {
    TRI_LEDGER="$TRI_LEDGER$1	$2	$3
"
}

# tri_special <what> -- record a place where this script had to know
# something about a particular kind of host. The brief for this script says
# nothing host-specific may be hardcoded; where that is impossible, the
# special case is itself a finding, so it is collected and printed rather
# than buried in an `if`.
tri_special() {
    TRI_SPECIALS="$TRI_SPECIALS$1
"
}

tri_is_verdict() {
    case $1 in
        CONFIRM|REFUTE|CANNOT-SAY) return 0 ;;
    esac
    return 1
}

# tri_stage_result <stage> <stage report>
#
# What the pipeline recorded for one stage: "ok", "reused", "FAILED", or
# "not-run" when the report has no row for it at all.
#
# WHY THIS EXISTS. The stages run in order and the loop stops at the first
# failure, so a report can be silent about a stage for two entirely
# different reasons: the level never asked for it, or an earlier stage
# failed and it never got its turn. Both look like "no evidence", and the
# ledger judges below used to infer a stage's fate from the run's overall
# build_ok instead -- which made every failure, anywhere in the pipeline,
# read as a failure of whichever stage a judge happened to care about.
# That is how a C23 compiler error in the `opencore` stage got reported as
# `G20 REFUTE -- media build or its post-unmount verification failed`,
# sending a reader after a filesystem bug that was not there.
#
# A misattributed verdict is worse than no verdict, so a judge now asks
# this what its own stage actually did, and says CANNOT-SAY for a stage
# that never ran.
tri_stage_result() {
    printf '%s' "$2" | awk -F'\t' -v s="$1" '
        $1 == s { r = $2 }
        END { print (r == "" ? "not-run" : r) }'
}

# tri_failed_stage <stage report> -- the first stage the report marks
# FAILED, or empty. The stage that failed is the stage to blame.
tri_failed_stage() {
    printf '%s' "$1" | awk -F'\t' '$2 == "FAILED" { print $1; exit }'
}

# tri_media_failure_kind <pipeline log> -- what KIND of failure the media
# stage had: "verification", "other", or "unknown".
#
# WHY A STAGE RESULT IS NOT ENOUGH. G20 is a claim about a second writer
# corrupting installer media, and the only evidence for or against it is
# the post-unmount package check. The media stage does a dozen other
# things first -- convert the ESD, populate an HFS+ volume, inject hooks,
# restore root ownership in a microVM -- and any of them can stop it. On
# squirrel-zapper 2026-09-20 the media was built, entry for entry, all
# sixteen of Apple's packages matching, and the run then died because the
# privops backend was unavailable on that distribution. The ledger called
# that G20 REFUTE. Nothing had been written twice and nothing had been
# verified.
#
# So "verification" is recognised POSITIVELY, from the message the check
# itself dies with, and everything else is "other". An unrecognised failure
# is not evidence about media corruption, and guessing that it is, is the
# bug this exists to prevent.
tri_media_failure_kind() {
    local log=${1:-}
    if [ -z "$log" ] || [ ! -r "$log" ]; then
        printf 'unknown\n'
        return 0
    fi
    # The ESD's copy of this message is deliberately NOT matched: it means
    # the conversion off Apple's image was wrong before the media existed,
    # which is a dmg2img question, not a G20 one. See check_esd_packages
    # and verify_media_packages in media/build-installer-img.sh.
    if grep -q 'the media does not contain what Apple shipped' "$log"; then
        printf 'verification\n'
    else
        printf 'other\n'
    fi
}

# tri_media_failure_reason <pipeline log> -- the last error the pipeline
# printed, without its script prefix. Empty when the log says nothing.
#
# A verdict that says only "something else failed" sends a reader into a
# megabyte of build log; one that names the failure sends them to the line.
tri_media_failure_reason() {
    local log=${1:-}
    [ -n "$log" ] && [ -r "$log" ] || return 0
    sed -n 's/^[A-Za-z0-9_.-]*: error: //p' "$log" | tail -1
}

# --- small pure judges -----------------------------------------------------

# cpu_has_flag <flag list> <flag> -- spelling-insensitive.
#
# The same feature is spelled three ways by the three hosts we may meet:
# Linux /proc/cpuinfo says `sse4_1`, macOS sysctl says `SSE4.1`, NetBSD's
# cpuctl says `SSE4.1` in a comma-separated list. Canonicalise rather than
# ask the caller to know which host it is on.
cpu_has_flag() {
    local list want
    list=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ',.' ' _')
    want=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr '.' '_')
    case " $list " in
        *" $want "*) return 0 ;;
    esac
    return 1
}

# accel_pick <kvm> <hvf> <nvmm> -- each "yes" or "no". Prints the
# accelerator this host would use. The order is the order of preference:
# hardware first, and TCG only when there is no hardware at all.
accel_pick() {
    if [ "$1" = yes ]; then
        printf 'kvm\n'
    elif [ "$2" = yes ]; then
        printf 'hvf\n'
    elif [ "$3" = yes ]; then
        printf 'nvmm\n'
    else
        printf 'tcg\n'
    fi
}

# A filesystem the repository or the image directory might be on, and what
# we know about it without measuring. Deliberately a list of names rather
# than a probe: the probe is in bin/triangulate.sh, and this is what the
# name alone implies.
fs_is_remote() {
    case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
        nfs|nfs3|nfs4|nfsv3|nfsv4|cifs|smbfs|smb2|smb3|afpfs|sshfs|fuse.sshfs|\
        ncpfs|9p|virtiofs|fuse.davfs|davfs)
            return 0 ;;
    esac
    return 1
}

fs_expects_reflink() {
    case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
        btrfs|xfs|apfs|zfs|bcachefs) return 0 ;;
    esac
    return 1
}

# G11 is a btrfs-only chore. Naming the filesystem it applies to, rather
# than asking whether `chattr` exists, is the difference between "not
# needed here" and "the tool is missing".
fs_needs_nocow() {
    case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
        btrfs) return 0 ;;
    esac
    return 1
}

# json_escape <string> -- enough of RFC 8259 for the values we emit, which
# are command output and paths. Control characters below 0x20 are dropped
# rather than escaped: none of them belong in a fact, and a report that
# smuggles one through is a report that will not parse somewhere else.
json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' \
        | tr -d '\000-\010\013\014\016-\037'
}

# --- ledger judges ---------------------------------------------------------
#
# Each takes the facts it needs and prints "<verdict>\t<observation>".
# One per entry, so the report and the tests name the same thing.

judge() { printf '%s\t%s\n' "$1" "$2"; }

# G1 -- "Host is Apple hardware, so running OS X in a VM is licensed."
g1_verdict() {
    case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
        *apple*)
            judge CONFIRM "system vendor is '$1': Apple's EULA covers this host" ;;
        "")
            judge CANNOT-SAY "no system vendor string available on this host" ;;
        *)
            judge REFUTE "system vendor is '$1', not Apple: outside Apple's EULA. A legal constraint, not a technical one -- the build may work and still not be licensed" ;;
    esac
}

# G2 -- "Intel CPU with VT-x."
g2_verdict() {
    local vendor=$1 virt=$2
    case $vendor in
        GenuineIntel)
            if [ "$virt" = vmx ]; then
                judge CONFIRM "GenuineIntel with vmx present"
            else
                judge REFUTE "GenuineIntel but no vmx flag: VT-x absent or disabled in firmware"
            fi ;;
        AuthenticAMD)
            judge REFUTE "AuthenticAMD ($virt): the brief treated AMD as a hard stop, and this host is the counter-example that can price it" ;;
        *)
            judge CANNOT-SAY "unrecognised CPU vendor '$vendor'" ;;
    esac
}

# G3 -- "the guest CPU model must be masked down from the host's."
#
# The interesting failure is the opposite one: a host OLDER than the model
# we ask for cannot be masked down to it, and no amount of configuration
# changes that.
g3_verdict() {
    local brand=$1 has_sse41=$2 qemu_cpu=$3
    if [ "$has_sse41" = no ]; then
        judge REFUTE "host CPU ('$brand') lacks SSE4.1, which the DEFAULT -cpu line asks for. Masking DOWN is not the problem here; the default asks for more than the host has, and no mask fixes that. It is NOT a stopper: 10.9 does not need SSE4.1 -- '-cpu Conroe' boots this guest to SSH (docs/decisions/0009) -- so the CPU line is a parameter and this host should take the Conroe row of lib/cpu.sh's table. See the -cpu table above for which rows this host can actually provide"
    elif [ "$qemu_cpu" = rejected ]; then
        judge REFUTE "host has the flags but QEMU rejected the -cpu line under this accelerator"
    elif [ "$qemu_cpu" = accepted ]; then
        judge CONFIRM "host CPU ('$brand') provides every flag the -cpu line asks for, so it is being masked down, as on the primary host"
    else
        judge CANNOT-SAY "host CPU ('$brand') has the flags, but the -cpu line was not exercised (no QEMU)"
    fi
}

# G25 -- "every -cpu line in lib/cpu.sh's table can be provided by this
# host". True on the primary host, which is Coffee Lake and therefore newer
# than every model in the table. It is the entry a 2006 machine exists to
# refute, and refuting it is useful rather than fatal: the table has rows
# below the one that gets refused.
#
# WHY THE ACCELERATOR IS AN ARGUMENT. TCG implements SSE4.1 itself, so
# under TCG every row is accepted and the answer is about the emulator
# rather than about the machine. That is CANNOT-SAY, not CONFIRM -- a
# confident yes from the wrong measurement is how docs/test-hosts.md came
# to write a host off for a year.
g25_verdict() {
    local qemu_version=$1 accel=$2 provided=$3 refused=$4 absent=$5 why=$6
    if [ -z "$qemu_version" ]; then
        judge CANNOT-SAY "no QEMU here to ask which CPU models it can provide"
        return
    fi
    if [ "$accel" != kvm ]; then
        judge CANNOT-SAY "the table was probed under $accel, which emulates every feature it is asked for, so the results describe the emulator and not this host's CPU. Re-run where a hardware accelerator is available"
        return
    fi
    if [ -z "$provided" ] && [ -z "$refused" ]; then
        judge CANNOT-SAY "QEMU $qemu_version offered none of the models in lib/cpu.sh's table by name:${absent:+ $absent}"
        return
    fi
    if [ -n "$refused" ]; then
        judge REFUTE "QEMU $qemu_version under KVM refused $refused and accepted ${provided:-nothing}${why:+ ($why)}. This host cannot provide every row of lib/cpu.sh's table. Read WHICH row before concluding anything: the table is a ladder, a refused row near the top means the host is older than the default and should use a row below it, and a refused row that names a feature 10.9 never needed (qemu64 asks for AMD's svm) means nothing at all. Picking an accepted row with --cpu is a supported outcome, not a broken host${absent:+; models this QEMU does not have at all: $absent}"
        return
    fi
    judge CONFIRM "QEMU $qemu_version under KVM provides every -cpu line in lib/cpu.sh's table ($provided), as on the primary host${absent:+; models this QEMU does not have at all: $absent}"
}

# G4 -- "6 physical cores available for pinning, SMT siblings identifiable."
g4_verdict() {
    local cores=$1 threads=$2
    if [ -z "$cores" ] || [ "$cores" = 0 ]; then
        judge CANNOT-SAY "core topology not available on this host"
    elif [ "$cores" = 6 ] && [ "$threads" = 2 ]; then
        judge CONFIRM "6 cores x $threads threads, as on the primary host"
    else
        judge REFUTE "$cores cores x $threads threads: P5's pinning choices are topology-specific and do not transfer unchanged"
    fi
}

# G6 -- "QEMU 8.2.2 from Ubuntu."
g6_verdict() {
    local ver=$1
    if [ -z "$ver" ]; then
        judge CANNOT-SAY "no QEMU on this host"
    elif [ "$ver" = 8.2.2 ]; then
        judge CONFIRM "QEMU $ver, the same version the primary host has"
    else
        judge REFUTE "QEMU $ver, not 8.2.2: whatever this run observes is also evidence about this QEMU"
    fi
}

# G7 -- "t2-patched kernel."
g7_verdict() {
    case $1 in
        *t2*) judge CONFIRM "kernel '$1' carries the t2 patches, as on the primary host" ;;
        "")   judge CANNOT-SAY "no kernel release string" ;;
        *)    judge REFUTE "kernel '$1' is not t2-patched, so any KVM or IOMMU oddity seen on the primary host and not here was plausibly caused there" ;;
    esac
}

# G8 -- "62 GB RAM and 1.7 TB free: no pressure on image sizes locally."
#
# The thresholds are what the pipeline actually needs, not a copy of the
# primary host's numbers: a 60 GB target disk that stays sparse, the media,
# the ESD and the build tree, and enough memory for a 4 GB guest plus the
# host. A host that clears them is under no pressure; one that does not is
# in P6's position, which is a budget rather than a failure.
g8_verdict() {
    local ram_mib=$1 free_mib=$2
    local want_ram=6144 want_free=120000
    if [ -z "$ram_mib" ] || [ -z "$free_mib" ]; then
        judge CANNOT-SAY "RAM or free space not measurable here"
    elif [ "$ram_mib" -ge "$want_ram" ] && [ "$free_mib" -ge "$want_free" ]; then
        judge CONFIRM "${ram_mib} MiB RAM, ${free_mib} MiB free: room for a 4 GB guest and a 60 GB sparse target"
    else
        judge REFUTE "${ram_mib} MiB RAM, ${free_mib} MiB free (want >= ${want_ram} MiB and >= ${want_free} MiB): this host has to budget, like P6's runners"
    fi
}

# G9 -- "the repo is on NFS, so MQG_IMAGE_DIR points images at local disk."
g9_verdict() {
    local repo_fs=$1 image_fs=$2
    if fs_is_remote "$repo_fs" && ! fs_is_remote "$image_fs"; then
        judge CONFIRM "repo on $repo_fs, images on $image_fs: the split is doing the same work here"
    elif fs_is_remote "$repo_fs"; then
        judge REFUTE "repo on $repo_fs and MQG_IMAGE_DIR also on $repo_fs: the split is not set up on this host, and images must not live on remote storage"
    else
        judge CONFIRM "repo on $repo_fs, which is local: the split is unnecessary here, which is the portable half of the entry"
    fi
}

# G10 -- "local filesystem is btrfs, so cp --reflink=auto makes golden
# promotion near-instant."
g10_verdict() {
    local fs=$1 result=$2
    case $result in
        yes) judge CONFIRM "$fs supports reflinks: golden promotion is near-free here too" ;;
        no)
            if fs_expects_reflink "$fs"; then
                judge REFUTE "$fs usually supports reflinks but this one did not: promotion is a full copy, and the cost is in space as well as time"
            else
                judge REFUTE "$fs has no reflinks: golden promotion is a full copy. Budget the time and the space"
            fi ;;
        *) judge CANNOT-SAY "reflink support on $fs was not measured" ;;
    esac
}

# G11 -- "btrfs needs chattr +C on the image directory."
g11_verdict() {
    local fs=$1 result=$2
    if ! fs_needs_nocow "$fs"; then
        judge CONFIRM "image directory is $fs, not btrfs: the chore does not apply, which is what the entry predicted"
    else
        case $result in
            yes) judge CONFIRM "btrfs, and chattr +C works here" ;;
            no)  judge REFUTE "btrfs, but chattr +C failed: qcow2 files will fragment" ;;
            *)   judge CANNOT-SAY "btrfs, but chattr +C was not exercised" ;;
        esac
    fi
}

# G12 -- "the repo is on NFSv3 and slow enough to force the vendor
# quarantine off it."
g12_verdict() {
    local repo_fs=$1 repo_ms=$2 local_ms=$3
    if fs_is_remote "$repo_fs"; then
        judge CONFIRM "repo is on $repo_fs (remote): ${repo_ms} ms per file create against ${local_ms} ms locally. Both the images and the vendor quarantine have to stay off it"
    else
        judge REFUTE "repo is on $repo_fs (local): ${repo_ms} ms per file create against ${local_ms} ms in the image directory. A host whose repo is already local needs no split at all"
    fi
}

# G13 -- "the guest needs EHCI + UHCI companions, not qemu-xhci."
#
# This is a claim about 10.9, not about a host, so a probe can only say
# whether the devices this host's QEMU offers are the ones we name. Only a
# completed install is evidence for the claim itself.
g13_verdict() {
    local devices_ok=$1 installed=$2
    if [ "$installed" = yes ]; then
        judge CONFIRM "a guest installed and answered SSH over the EHCI+UHCI stack on this host's QEMU"
    elif [ "$devices_ok" = yes ]; then
        judge CANNOT-SAY "this QEMU has ich9-usb-ehci1 and the UHCI companions, but no guest was booted: the entry is a claim about 10.9's AppleUSBXHCI, and only an install speaks to it"
    else
        judge REFUTE "this QEMU does not offer the EHCI/UHCI devices the profiles name"
    fi
}

# G14 -- "SMBIOS must not be MacPro5,1: AppleTyMCEDriver panics on a
# non-Xeon CPU."
#
# Settling this needs an install with SMBIOS MacPro5,1 on a Xeon, which is
# not something this script does at any level. What it can do is say
# whether the host is the Xeon the experiment needs.
g14_verdict() {
    local brand=$1
    case $(printf '%s' "$brand" | tr '[:upper:]' '[:lower:]') in
        *xeon*)
            judge CANNOT-SAY "this IS a Xeon ('$brand') -- the host the entry has been waiting for. Settling it needs an install with SMBIOS MacPro5,1, which this script does not do: see docs/test-hosts.md" ;;
        "")
            judge CANNOT-SAY "no CPU brand string" ;;
        *)
            judge CANNOT-SAY "not a Xeon ('$brand'), so this host cannot tell a host-specific mask from a necessary one" ;;
    esac
}

# G16 -- "ide-hd on q35 presents as SATA/AHCI in the guest."
g16_verdict() {
    local bus=$1
    case $bus in
        "") judge CANNOT-SAY "no guest was booted, and this is a claim about what the guest sees" ;;
        *SATA*|*sata*) judge CONFIRM "the guest reports connection bus '$bus'" ;;
        *) judge REFUTE "the guest reports connection bus '$bus', not SATA" ;;
    esac
}

# G17 -- "kvm_intel.nested = Y, so nested virtualization is available."
g17_verdict() {
    case $1 in
        Y|y|1) judge CONFIRM "nested virtualization is on" ;;
        N|n|0) judge REFUTE "nested virtualization is off: it is a module parameter, and decisions/0005 needs it" ;;
        *)     judge CANNOT-SAY "nested virtualization state unknown on this host ('$1')" ;;
    esac
}

# G18 -- "the guest CPU model is Penryn, which predates EPT."
g18_verdict() {
    local has_ept=$1
    if [ "$has_ept" = yes ]; then
        judge CONFIRM "host has EPT, so a Nehalem-or-newer guest model is available if VMware Fusion turns out to need one"
    else
        judge REFUTE "host has no EPT: VMware Fusion in the guest is out of reach here whatever CPU model we pick, and this host cannot evaluate decisions/0005"
    fi
}

# G19 -- "two concurrent guest installs wedge one of them. Cause unproven."
#
# Always CANNOT-SAY from this script, deliberately and permanently: it runs
# one install at a time, because running two is the thing the entry warns
# about. Saying so is better than omitting the row, because the reason is
# the finding.
# G21 -- kvm.ignore_msrs=1 was set on the primary host on 2026-09-17 on the
# authority of Somlo and OSX-KVM, and never tested without. This is the
# entry that existed in the ledger for a full day with no verdict function,
# so a run that could have settled it said nothing about it. A hypothesis
# the harness cannot report on is not being tested by the harness.
g21_verdict() {
    local ignore_msrs=$1 install_ok=$2
    case "$ignore_msrs" in
        unknown|'')
            judge CANNOT-SAY "this host does not expose kvm.ignore_msrs (not Linux, or the module parameter is unreadable)" ;;
        1|Y|y)
            judge CANNOT-SAY "ignore_msrs is on here, as on the primary host, so this run cannot tell a necessary setting from an inherited one" ;;
    esac
    case "$install_ok" in
        yes)
            judge REFUTE "ignore_msrs is OFF here and a guest installed and answered SSH anyway: the setting is not required, at least on this CPU and this QEMU. Stop asking users to change a kernel parameter until something shows it is needed" ;;
        no)
            judge CANNOT-SAY "ignore_msrs is off here and the install did not complete -- but it failed for a named reason unrelated to MSRs, so this says nothing either way. See the stage table" ;;
        *)
            judge CANNOT-SAY "ignore_msrs is off here, but no install was attempted at this level: run --full to settle it" ;;
    esac
}

# G26 -- the media build reaches the host's filesystems through udisks2,
# whose polkit policy grants loop-setup to a user AT A SEAT. ap-juicer
# 2026-09-21, over SSH to a headless server: NotAuthorizedCanObtain.
# "CanObtain" means polkit would allow it after an interactive password
# prompt, which is no use to an unattended pipeline.
g26_verdict() {
    local media_failure=$1 media_built=$2
    case "$media_failure" in
        *NotAuthorized*|*polkit*|*"loop-setup failed"*)
            judge REFUTE "udisks2 refused loop-setup here: this host has no active local session for polkit to grant it to. The unprivileged path assumes a desktop seat, and a headless server does not have one. The fix is structural -- do the HFS+ work inside the privops microVM so no host loop device is needed at all" ;;
    esac
    case "$media_built" in
        yes)  judge CONFIRM "udisks2 granted loop-setup here, so this host does have whatever polkit wants -- usually an active local session" ;;
        *)    judge CANNOT-SAY "no media was built at this level, or it failed for an unrelated reason: nothing here speaks to whether udisks2 would authorize this user" ;;
    esac
}

g19_verdict() {
    judge CANNOT-SAY "not tested: this script never runs two installs at once, which is the standing advice the entry gives. Settling it needs the deliberate experiment the entry describes"
}

# G20 -- "a second writer to installer media corrupts it, and only a
# post-unmount checksum notices."
#
# `built` is what the media stage itself did, not what the run did: see
# tri_stage_result. `kind` is what kind of failure it was, when it failed:
# see tri_media_failure_kind.
#
# REFUTE IS RESERVED FOR THE POST-UNMOUNT VERIFICATION FINDING CORRUPTION,
# because that is the only outcome that is evidence about this entry. A
# media stage that fell over for some other reason -- a missing privops
# backend, a full disk, a tool this host does not have -- is a CANNOT-SAY
# that names the reason. This is the same misattribution tri_stage_result
# fixed one level up: there, "the run failed" was read as "media failed";
# here, "media failed" was read as "G20 happened".
g20_verdict() {
    local built=$1 failed=${2:-} kind=${3:-unknown} reason=${4:-}
    case $built in
        yes)    judge CONFIRM "media built here and verified against media/apple-packages.sha256 from a fresh mount: the verification the entry asks for ran, and passed" ;;
        no)
            case $kind in
                verification)
                    judge REFUTE "the media built and then FAILED its post-unmount check against media/apple-packages.sha256${reason:+ -- $reason}. That is the interesting case, and the only one that is evidence here. Keep the log" ;;
                *)
                    judge CANNOT-SAY "the media stage failed before any verification ran${reason:+: $reason}. Whatever that is, it is not a second writer corrupting media -- nothing was verified and nothing reported corrupt. Fix the named failure and re-run" ;;
            esac ;;
        reused) judge CANNOT-SAY "media was already on this host and was reused, not rebuilt: this run is no evidence either way" ;;
        not-run)
            if [ -n "$failed" ]; then
                judge CANNOT-SAY "the media stage never ran: the pipeline stopped at the '$failed' stage, and that is where the failure belongs. Nothing here is evidence about media"
            else
                judge CANNOT-SAY "the media stage never ran at this level"
            fi ;;
        *)      judge CANNOT-SAY "no media was built at this level" ;;
    esac
}

# The retired entries still have something to test. G5 was resolved by
# building our own firmware; the replacement claim is that the build is
# reproducible off this host's toolchain, which is a stronger test than the
# one G5 asked for -- and the only way to run it is to compare checksums
# with another host.
g5_verdict() {
    local ovmf=$1 opencore=$2 fresh=$3 failed=${4:-}
    if [ -z "$ovmf" ] && [ -z "$opencore" ] && [ -n "$failed" ]; then
        judge CANNOT-SAY "no firmware or OpenCore checksums: the pipeline stopped at the '$failed' stage before they existed. Fix that stage first -- and if it is a build stage, note that this project pins its sources but not its compiler (decisions/0004)"
    elif [ -z "$ovmf" ] && [ -z "$opencore" ]; then
        judge CANNOT-SAY "nothing built at this level; run --build to get checksums worth diffing"
    elif [ "$fresh" = no ]; then
        judge CANNOT-SAY "these artifacts were already on this host, not built by this run: OVMF_CODE.fd $ovmf, OpenCore EFI image $opencore. Re-run against an empty MQG_IMAGE_DIR for checksums this host's toolchain actually produced"
    else
        judge CANNOT-SAY "built here by this host's toolchain: OVMF_CODE.fd $ovmf, OpenCore EFI image $opencore. One host cannot tell a reproducible build from a lucky one -- diff these against another host's JSON"
    fi
}

# G24 -- "the NIC ranking is QEMU's, not this host's." The default guest NIC
# became e1000-82545em on 2026-09-21 on numbers taken entirely under QEMU
# 8.2.2 (docs/decisions/0008). Two things another host can say without
# running a benchmark: whether its QEMU offers the device the default now
# names, and -- at --full -- whether a guest installs and answers SSH over
# it, which is the same evidence the decision was made on.
#
# This function exists because G21 sat in the ledger for a day without one,
# and the run that settled it printed nothing about it.
g24_verdict() {
    local missing=$1 install_ok=$2 qemu_version=$3
    case " $missing " in
        *" e1000-82545em "*)
            judge REFUTE "this QEMU does not offer e1000-82545em, which image/build-image.sh now defaults to. On this host the default is unbuildable and --nic usb-net is the fallback"
            return ;;
    esac
    if [ -z "$qemu_version" ]; then
        judge CANNOT-SAY "no QEMU here to ask about the device the default names"
    elif [ "$install_ok" = yes ]; then
        judge CONFIRM "a guest installed and answered SSH over e1000-82545em on QEMU $qemu_version -- the device works outside 8.2.2, though this run measured no throughput"
    elif [ "$install_ok" = no ]; then
        judge CANNOT-SAY "QEMU $qemu_version offers e1000-82545em but the install did not finish, and it stopped for a named reason of its own: see the stage table before blaming the NIC"
    else
        judge CANNOT-SAY "QEMU $qemu_version offers e1000-82545em, but only a --full run puts a guest on it. The throughput half of this entry needs a deliberate benchmark, which this script does not run"
    fi
}
