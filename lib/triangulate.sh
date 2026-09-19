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
        judge REFUTE "host CPU ('$brand') lacks SSE4.1, which our -cpu line requires. Masking DOWN is not the problem here; the guest model asks for more than the host has, and no mask fixes that. The CPU line needs to become a parameter"
    elif [ "$qemu_cpu" = rejected ]; then
        judge REFUTE "host has the flags but QEMU rejected the -cpu line under this accelerator"
    elif [ "$qemu_cpu" = accepted ]; then
        judge CONFIRM "host CPU ('$brand') provides every flag the -cpu line asks for, so it is being masked down, as on the primary host"
    else
        judge CANNOT-SAY "host CPU ('$brand') has the flags, but the -cpu line was not exercised (no QEMU)"
    fi
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
g19_verdict() {
    judge CANNOT-SAY "not tested: this script never runs two installs at once, which is the standing advice the entry gives. Settling it needs the deliberate experiment the entry describes"
}

# G20 -- "a second writer to installer media corrupts it, and only a
# post-unmount checksum notices."
g20_verdict() {
    local built=$1
    case $built in
        yes)    judge CONFIRM "media built here and verified against media/apple-packages.sha256 from a fresh mount: the verification the entry asks for ran, and passed" ;;
        no)     judge REFUTE "media build or its post-unmount verification failed on this host -- the interesting case. Keep the log" ;;
        reused) judge CANNOT-SAY "media was already on this host and was reused, not rebuilt: this run is no evidence either way" ;;
        *)      judge CANNOT-SAY "no media was built at this level" ;;
    esac
}

# The retired entries still have something to test. G5 was resolved by
# building our own firmware; the replacement claim is that the build is
# reproducible off this host's toolchain, which is a stronger test than the
# one G5 asked for -- and the only way to run it is to compare checksums
# with another host.
g5_verdict() {
    local ovmf=$1 opencore=$2 fresh=$3
    if [ -z "$ovmf" ] && [ -z "$opencore" ]; then
        judge CANNOT-SAY "nothing built at this level; run --build to get checksums worth diffing"
    elif [ "$fresh" = no ]; then
        judge CANNOT-SAY "these artifacts were already on this host, not built by this run: OVMF_CODE.fd $ovmf, OpenCore EFI image $opencore. Re-run against an empty MQG_IMAGE_DIR for checksums this host's toolchain actually produced"
    else
        judge CANNOT-SAY "built here by this host's toolchain: OVMF_CODE.fd $ovmf, OpenCore EFI image $opencore. One host cannot tell a reproducible build from a lucky one -- diff these against another host's JSON"
    fi
}
