#!/usr/bin/env bash
# vmavs emit packer -- write one Packer HCL2 template for the qemu-plugin
# builder, derived from a vm/profiles/*.args profile.
#
# WHY PACKER, AND WHY PACKER IS NOT THE BUILD
#
# docs/test-hosts.md:284 already observes that timsutton/osx-vm-templates
# -- this project's prior art twice over -- IS a Packer template, and that
# what this project builds, minus the first-boot payload, is the same
# shape. One template reaches QEMU, VirtualBox, VMware and Proxmox, and
# its `vagrant` post-processor makes the boxes -- the single
# highest-leverage interop artifact available. It is an EMIT TARGET and
# not the build, for three reasons already settled: Packer's core value is
# `boot_command` GUI keystroke automation, which P4 engineered away
# entirely by using Apple's own `rc.cdrom.local` / `minstallconfig.xml` /
# `OSInstall.collection` hooks; adopting it would cost the stage-level
# input-hash freshness this project already has (image/build-image.sh
# --freshness) and most of the manifest; and it covers two of eleven
# stages.
#
# WHAT HAS AND HAS NOT BEEN VERIFIED
#
# The VALUES this script writes are MEASURED, INHERITED or REASONED, and
# it says which for every one of them -- not just once in this header, but
# per field, because which is true differs by field and (for machine_type,
# cpu_model, memory and cpus) even by which profile is named: a profile
# that sets a flag directly earns MEASURED, one that gets it only through
# an `@include` earns INHERITED, and one that sets neither and falls back
# to this script's or image/build-image.sh's own default earns REASONED,
# said so explicitly rather than dressed up as either of the other two.
# See `value_source`/`source_label` below -- one function decides the
# word, so --describe and the emitted file cannot disagree about it.
#
# The FIELD NAMES AND NESTING -- which Packer block a value belongs in,
# and under what key -- are ALSO REASONED, from Packer's documented
# qemu-plugin schema. NO PACKER HAS EVER PARSED A FILE THIS SCRIPT WROTE:
# packer is not installed on the host this was written on, and this
# project installs nothing to make that true. `--check` exists to close
# that gap the moment somebody with packer runs it; until then, every
# emitted template says so in its own header.
#
# THE DRIVE MAPPING IS THE LEAST CERTAIN PART OF THIS FILE. Read the
# "DRIVE MAPPING IS REASONED" section inside emit_template() below (and
# NOTES.md's 2026-09-24 fix-round entry) before trusting it.
#
# THE NEVER-PUBLISH RULE REACHES HERE TOO. The emitted template references
# local paths and embeds no Apple bytes -- no InstallESD/BaseSystem
# content, no `osk=` string. This script also refuses outright to emit
# anything for a profile whose OWN expansion reaches into the Tier 2
# quarantine ($MQG_VENDOR_DIR) -- see the check right after the profile is
# read, below -- and bin/tier-check.sh --strict additionally scans emit/
# itself for the same reason it scans vm/profiles/.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=emit-packer
# shellcheck source=../lib/profile.sh
. "$MQG_REPO_ROOT/lib/profile.sh"
# shellcheck source=../lib/cpu.sh
. "$MQG_REPO_ROOT/lib/cpu.sh"
# shellcheck source=../lib/smbios.sh
. "$MQG_REPO_ROOT/lib/smbios.sh"

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
export MQG_IMAGE_DIR
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
export MQG_BUILD_DIR
MQG_VENDOR_DIR=${MQG_VENDOR_DIR:-$MQG_IMAGE_DIR/vendor-reference}
export MQG_VENDOR_DIR
PROFILE_DIR=${PROFILE_DIR:-$MQG_REPO_ROOT/vm/profiles}

profile=
out=
describe=0
check=0

usage() {
    cat <<EOF
usage: vmavs emit packer --profile NAME [--out FILE] [--describe] [--check]

  --profile NAME  Profile from vm/profiles/*.args to derive values from.
                  Required.
  --out FILE      Write the template here. Default: stdout.
  --describe      Print where each field's value came from (MEASURED,
                  INHERITED or REASONED) and write nothing.
  --check         After writing, run 'packer validate' on the result if
                  packer is on PATH -- and say plainly, and fail, if it
                  is not. Cannot-verify is never a pass.
  -h, --help      This.

Known profiles:
$(PROFILE_DIR="$PROFILE_DIR" profile_list 2>/dev/null | sed 's/^/  /')
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --profile) [ $# -ge 2 ] || die "--profile needs a name"; profile=$2; shift ;;
        --out)     [ $# -ge 2 ] || die "--out needs a path"; out=$2; shift ;;
        --describe) describe=1 ;;
        --check)    check=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

[ -n "$profile" ] || { usage >&2; die "--profile is required"; }

# Checked here, by hand, rather than relying on profile_expand's own die:
# that die only ends the process-substitution subshell that reads its
# output below (see vm/run.sh's own comment on the same thing), not this
# script -- and a caller of this script deserves the same "here is what
# DOES exist" list vm/run.sh gives, not a partial template.
known_profiles=$(PROFILE_DIR="$PROFILE_DIR" profile_list 2>/dev/null | tr '\n' ' ')
case " $known_profiles " in
    *" $profile "*) : ;;
    *) die "no such profile: $profile (known: ${known_profiles% })" ;;
esac

# build_image_default <name> -- image/build-image.sh's own default for a
# flag it defines as "<name>=<value>" near its top (ram, smp, disk_gb).
# Read from the script itself rather than copied by hand, so this stays
# right if that default ever moves.
build_image_default() {
    sed -n "s/^$1=\\([0-9][0-9]*\\)\$/\\1/p" "$MQG_REPO_ROOT/image/build-image.sh" | head -1
}

# profile_commit <name> -- the short hash this profile file was last
# changed at, or empty if this is not a git checkout (an installed tree
# has no .git, and this is provenance for the curious, not a requirement).
profile_commit() {
    command -v git >/dev/null 2>&1 || return 0
    [ -d "$MQG_REPO_ROOT/.git" ] || return 0
    git -C "$MQG_REPO_ROOT" log -1 --format=%h -- "$(profile_path "$1")" 2>/dev/null || true
}

# --- provenance: which FILE actually set a given flag -----------------------
#
# Fix-round-1 finding: --describe and the emitted header used to label
# machine_type/cpu_model as unconditionally MEASURED and memory/cpus as
# unconditionally INHERITED, regardless of what the named profile actually
# contained -- so a profile with no -cpu of its own (falling back to this
# script's default) was still labelled MEASURED, and a profile with no
# hostfwd was handed a fabricated one. These functions answer "which
# FILE, if any, sets this flag" by reading each candidate .args file's own
# RAW lines -- never profile_expand's output, which is deliberately
# flattened and cannot say which file a line came from -- so the label
# always matches the value that was actually used.
#
# Fix-round-2 finding: the first version of this section only looked ONE
# level of @include deep, and -- far worse than a label mismatch -- the
# code that APPLIED a fallback default trusted that shallow check to mean
# "this value is absent", overwriting an already-correctly-parsed value
# with the wrong default whenever a flag arrived through a SECOND @include
# hop (profile_expand itself is fully recursive and has no such depth
# limit, so the VALUE was always right; only the shallow provenance check
# was wrong, and it was trusted for more than a label). value_source below
# now walks the full @include chain, recursively, with the same textual
# cycle guard lib/profile.sh's own profile_expand uses -- so a value ten
# @includes deep is still attributed to the actual file that sets it,
# never "absent". Separately, and now the ONLY thing that decides whether
# a fallback default is applied at all: the fallback blocks after the
# parsing loop below check whether the PARSED VALUE is empty, never
# value_source's report -- value_source exists purely to label an
# already-resolved value, and must never be consulted to decide whether
# to overwrite one.

# profile_raw_flags <path> -- the flag lines (not their values) of ONE
# .args file, as literally written -- comments and blank lines dropped,
# @include lines dropped, everything else that starts with '-' kept. This
# is intentionally NOT lib/profile.sh's expansion: it must be able to say
# "this exact file has this exact line", which expansion (by design)
# erases the provenance of.
profile_raw_flags() {
    local path=$1 line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        case $line in
            '#'*) continue ;;
            '@include'*) continue ;;
            -*) printf '%s\n' "$line" ;;
        esac
    done < "$path"
}

# profile_sets_flag <profile-name> <flag> -- true if that profile's own
# file (not counting anything it includes) has <flag> as a bare line of
# its own, e.g. "-cpu" or "-netdev".
#
# NOT `profile_raw_flags ... | grep -qx -- "$2"`. That pipes into a `grep
# -q`, which exits the instant it finds a match -- SIGPIPEing the
# still-writing `profile_raw_flags` side of the pipe, which under this
# script's own `set -o pipefail` reports the pipeline as FAILED (141)
# *because* the match succeeded, for any flag that happens to appear
# early enough in the file that the writer has not already finished. That
# is the exact bug bin/tier-check.sh's and lib/preconditions.sh's own
# comments describe, caught here the same way it was there: capture the
# whole output first (no pipe still open when a match is found), then
# match in-process.
profile_sets_flag() {
    local path=$1 want=$2 flags f
    flags=$(profile_raw_flags "$(profile_path "$path")")
    while IFS= read -r f; do
        [ "$f" = "$want" ] && return 0
    done <<EOF
$flags
EOF
    return 1
}

# profile_includes <path> -- the names on THIS file's own `@include`
# lines, one per line -- one level; the recursion that reaches deeper
# ones lives in value_source_walk below, not here.
profile_includes() {
    local path=$1 line included
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case $line in
            '@include '*)
                included="${line#@include }"
                included="${included#"${included%%[![:space:]]*}"}"
                [ -n "$included" ] && printf '%s\n' "$included" ;;
        esac
    done < "$path"
}

# value_source <flag> -- "profile", "include:NAME", or "absent". "NAME" is
# whichever file in the @include chain ACTUALLY sets the flag, however
# many hops deep that is -- see value_source_walk. The caller decides what
# "absent" means (a fallback default), but per the fix-round-2 comment
# above, "absent" from THIS function must never be what triggers applying
# one; only the parsed value being empty may do that.
value_source() {
    local flag=$1 found
    if found=$(value_source_walk "$profile" "$flag" ""); then
        printf '%s\n' "$found"
    else
        printf 'absent\n'
    fi
}

# value_source_walk <profile-name> <flag> <chain> -- depth-first search of
# the @include graph starting at <profile-name> for the first file (that
# name itself, then its includes, then their includes, ...) that sets
# <flag> directly. <chain> is the colon-delimited list of names already
# visited on this path, in the exact shape lib/profile.sh's own
# profile_expand uses for its cycle guard -- borrowed rather than
# reinvented, because an include cycle here would otherwise recurse
# forever exactly the way it would there.
value_source_walk() {
    local name=$1 flag=$2 chain=$3 inc sub

    case ":$chain:" in
        *":$name:"*) return 1 ;;
    esac

    if profile_sets_flag "$name" "$flag"; then
        if [ "$name" = "$profile" ]; then
            printf 'profile\n'
        else
            printf 'include:%s\n' "$name"
        fi
        return 0
    fi

    for inc in $(profile_includes "$(profile_path "$name")"); do
        if sub=$(value_source_walk "$inc" "$flag" "$chain:$name"); then
            printf '%s\n' "$sub"
            return 0
        fi
    done
    return 1
}

# source_label <provenance> -- the MEASURED/INHERITED/REASONED word plus a
# one-line citation, for a provenance string value_source (or a
# "fallback:<why>" string a caller built after finding "absent") produced.
# Both --describe and the emitted template's inline comments call this, so
# the two cannot drift into disagreeing about the same value.
source_label() {
    case $1 in
        profile)
            printf 'MEASURED -- vm/profiles/%s.args%s\n' \
                "$profile" "${commit_profile:+ @ $commit_profile}" ;;
        include:*)
            local inc=${1#include:} inc_commit
            inc_commit=$(profile_commit "$inc")
            printf 'INHERITED -- vm/profiles/%s.args%s, pulled in by this profile'"'"'s @include\n' \
                "$inc" "${inc_commit:+ @ $inc_commit}" ;;
        fallback:*)
            printf 'REASONED -- %s\n' "${1#fallback:}" ;;
        *)
            printf 'REASONED -- unrecognised provenance "%s"\n' "$1" ;;
    esac
}

# --- read the profile -------------------------------------------------------
#
# One argument per line (lib/profile.sh's format), so the expansion is
# read into an array and walked two lines at a time: almost everything in
# a QEMU command line is "-flag" followed by its value, and the one
# exception this project's own profiles use (-enable-kvm) is called out
# below by name rather than guessed at generically.

expanded=()
while IFS= read -r eline; do
    expanded+=("$eline")
done < <(profile_expand "$profile")

# Refuse outright if the profile's OWN expansion reaches into the Tier 2
# quarantine. bin/tier-check.sh --strict separately scans emit/ itself --
# the GENERATOR's own source text (this script, and anything else that
# lives under emit/), not anything it writes at runtime to wherever --out
# points -- for the same path, which only catches this script's own
# source ever hardcoding a quarantine reference. That is a different
# failure from a QUARANTINED PROFILE being faithfully copied into
# someone's --out file; without the check right here, a profile with a
# %VENDOR% placeholder would sail straight through emit with exit 0 and a
# quarantine path sitting in qemuargs, and nothing under emit/ itself
# would ever show it. This is the check that catches that. Fix-round-1
# finding: an earlier version of this script had no such check at all.
expanded_text=$(printf '%s\n' "${expanded[@]+"${expanded[@]}"}")
if [ "${expanded_text#*"$MQG_VENDOR_DIR/"}" != "$expanded_text" ]; then
    die "profile '$profile' expands into the Tier 2 quarantine" \
        "($MQG_VENDOR_DIR) -- refusing to emit. This is exactly what" \
        "bin/tier-check.sh guards vm/profiles/ against; emit must never" \
        "re-export it as a Packer template. See docs/decisions/0003."
fi

machine=''
cpu=''
mem=''
smp=''
qemuargs=()   # each entry: "flag\tvalue", in profile order
netdev_hostfwd=''
nic_model=''

# Packer's own convention for the disk it would have created and attached
# itself, had qemuargs not overridden every default -drive/-device (see
# the "DRIVE MAPPING" note in emit_template() below). Declared once, here,
# so the qemuargs target drive and the source block's own
# output_directory/vm_name fields cannot say two different things.
OUTPUT_DIRECTORY='output-mavericks'
VM_NAME='mavericks'
TARGET_DISK_PATH="$OUTPUT_DIRECTORY/$VM_NAME.qcow2"

# drive_field <qemu drive-or-device value> <key> -- the value of key=...
# within a comma-separated QEMU option string, or nothing (exit 1).
#
# Pure bash, no sed. The previous implementation used GNU sed's `\b`
# (`sed -n 's/.*\bid=\([^,]*\).*/\1/p'`) to extract `id=`; BSD/macOS sed --
# a host this project targets -- does not support `\b` and silently
# returns EMPTY rather than erroring, which would have made every drive
# look id-less and, worse, would have left an absolute host path in
# `file=` unrewritten in the emitted template. Comma-splitting the option
# string in bash has no such platform seam.
drive_field() {
    local val=$1 key=$2 part
    local old_ifs=$IFS
    IFS=,
    # shellcheck disable=SC2086  # word-splitting on IFS=',' is the point
    set -- $val
    IFS=$old_ifs
    for part in "$@"; do
        case $part in
            "$key="*) printf '%s\n' "${part#"$key"=}"; return 0 ;;
        esac
    done
    return 1
}

# rewrite_drive_file <value> <id> -- a -drive value with its bare host
# path under file= replaced by whatever this template names that artifact
# once `vmavs boot-stack`/`vmavs media` have produced it (a Packer
# variable), or, for the installer and target drives, by the path this
# template's own fields use for the same file (see the "DRIVE MAPPING"
# note in emit_template()). Nothing is dropped: every -drive the profile
# has, this template keeps, id for id.
rewrite_drive_file() {
    local val=$1 id=$2
    case $id in
        installer)
            # shellcheck disable=SC2016  # ${var.media} is literal HCL2, not a shell expansion
            printf '%s\n' "$(printf '%s' "$val" | sed 's#file=[^,]*#file=${var.media}#')"
            return 0 ;;
        target)
            printf '%s\n' "$(printf '%s' "$val" | sed "s#file=[^,]*#file=$TARGET_DISK_PATH#")"
            return 0 ;;
    esac
    case $val in
        *OVMF_CODE.fd*)
            # shellcheck disable=SC2016
            printf '%s\n' "$(printf '%s' "$val" | sed 's#file=[^,]*#file=${var.ovmf_code}#')" ;;
        *VARS.fd*)
            # shellcheck disable=SC2016
            printf '%s\n' "$(printf '%s' "$val" | sed 's#file=[^,]*#file=${var.ovmf_vars}#')" ;;
        *opencore*.img*)
            # shellcheck disable=SC2016
            printf '%s\n' "$(printf '%s' "$val" | sed 's#file=[^,]*#file=${var.opencore_media}#')" ;;
        *) printf '%s\n' "$val" ;;
    esac
}

i=0
n=${#expanded[@]}
while [ "$i" -lt "$n" ]; do
    line=${expanded[$i]}
    case $line in
        -enable-kvm)
            # Covered by this template's own qemu-plugin acceleration,
            # which is not a field this script sets -- Packer's qemu
            # builder manages its own -accel/-enable-kvm.
            i=$((i + 1)) ;;
        -machine)
            machine=${expanded[$((i + 1))]}; i=$((i + 2)) ;;
        -cpu)
            cpu=${expanded[$((i + 1))]}; i=$((i + 2)) ;;
        -m)
            mem=${expanded[$((i + 1))]}; i=$((i + 2)) ;;
        -smp)
            smp=${expanded[$((i + 1))]}; i=$((i + 2)) ;;
        -display)
            # "-display none" -- covered by this template's own
            # `headless = true`.
            i=$((i + 2)) ;;
        -monitor)
            # Packer's own control channel, not this template's to set.
            i=$((i + 2)) ;;
        -netdev)
            netdev_hostfwd=${expanded[$((i + 1))]}
            qemuargs+=("$line	$netdev_hostfwd")
            i=$((i + 2)) ;;
        -drive)
            val=${expanded[$((i + 1))]}
            id=$(drive_field "$val" id || true)
            qemuargs+=("$line	$(rewrite_drive_file "$val" "$id")")
            i=$((i + 2)) ;;
        -device)
            val=${expanded[$((i + 1))]}
            case $val in
                *netdev=*) nic_model=${val%%,*} ;;
            esac
            qemuargs+=("$line	$val")
            i=$((i + 2)) ;;
        *)
            # Anything this profile does not currently use. Treated as a
            # flag with a value, which is every other line in this
            # project's profiles; passed through unchanged so a new
            # profile does not silently lose a device.
            if [ $((i + 1)) -lt "$n" ]; then
                qemuargs+=("$line	${expanded[$((i + 1))]}")
                i=$((i + 2))
            else
                qemuargs+=("$line	")
                i=$((i + 1))
            fi
            ;;
    esac
done

# --- resolve provenance, applying fallbacks only where the PARSED VALUE
# is truly empty -- never where value_source merely reports "absent" -----
#
# Fix-round-2: this is the one thing that changed behaviorally. The
# parsing loop above already produced the right VALUE regardless of
# @include depth (profile_expand is fully recursive); value_source's job
# below is now ONLY to label that value for --describe and the emitted
# header, never to decide whether a fallback default overwrites it. `[ -z
# "$machine" ]` etc. ask the one question that actually matters: did the
# parsing loop find this flag ANYWHERE, at any depth.

machine_prov=$(value_source -machine)
if [ -z "$machine" ]; then
    machine=q35
    machine_prov="fallback:no -machine line anywhere in this profile's @include chain; using this script's own q35 default"
fi

cpu_prov=$(value_source -cpu)
if [ -z "$cpu" ]; then
    cpu=$MQG_CPU_DEFAULT
    cpu_prov="fallback:no -cpu line anywhere in this profile's @include chain; using lib/cpu.sh's MQG_CPU_DEFAULT (docs/decisions/0009)"
fi

mem_prov=$(value_source -m)
if [ -z "$mem" ]; then
    mem=$(build_image_default ram)
    [ -n "$mem" ] || mem=4096
    mem_prov="fallback:no -m line anywhere in this profile's @include chain; using image/build-image.sh's own ram default"
fi

smp_prov=$(value_source -smp)
if [ -z "$smp" ]; then
    smp=$(build_image_default smp)
    [ -n "$smp" ] || smp=2
    smp_prov="fallback:no -smp line anywhere in this profile's @include chain; using image/build-image.sh's own smp default"
fi

disk_gb=$(build_image_default disk_gb)
[ -n "$disk_gb" ] || disk_gb=60
disk_size="$((disk_gb * 1024))M"

# The NIC and its forwarded port, if any -- derived from the actual
# -netdev/-device pair this profile has, never assumed. Fix-round-1
# finding: this used to hardcode "usb-net" and default a missing hostfwd
# to 2222, so a profile like p3-full (e1000-82545em, no hostfwd at all)
# still got a template claiming a usb-net port forward that does not
# exist on that profile.
ssh_port=''
if [ -n "$netdev_hostfwd" ]; then
    ssh_port=$(printf '%s' "$netdev_hostfwd" | sed -n 's/.*hostfwd=tcp::\([0-9]*\)-:22.*/\1/p')
fi
netdev_prov=$(value_source -netdev)

commit_profile=$(profile_commit "$profile")

# --- --describe --------------------------------------------------------

if [ "$describe" -eq 1 ]; then
    cat <<EOF
vmavs emit packer --describe --profile $profile

Where the emitted template's values come from. MEASURED means this
profile's own file sets the flag directly; INHERITED means it comes from
this profile's @include; REASONED means neither does, and a fallback
default (this script's own, or image/build-image.sh's) was used instead.

  machine_type   $machine
                 $(source_label "$machine_prov")
  cpu_model      $cpu
                 $(source_label "$cpu_prov")
  memory         ${mem} MB
                 $(source_label "$mem_prov")
  cpus           $smp
                 $(source_label "$smp_prov")
  disk_size      $disk_size
                 REASONED -- image/build-image.sh's disk_gb default; no
                 .args profile in this project sets a disk size of its own
  network        ${nic_model:-no NIC device found in this profile}${ssh_port:+, hostfwd tcp::$ssh_port-:22}
                 $(if [ -n "$nic_model" ]; then source_label "$netdev_prov"; else printf 'REASONED -- this profile has no -netdev/-device pair\n'; fi)
  drive mapping (installer + target disk attachment)
                 REASONED -- packer-plugin-qemu's qemuargs OVERRIDE every
                 default -drive/-device once you supply your own, so
                 both are kept in qemuargs and rewritten rather than left
                 to Packer's own iso/disk handling. UNVERIFIED against a
                 real packer-plugin-qemu build; see NOTES.md's
                 2026-09-24 fix-round entry.
  smbios (comment only -- not a QEMU flag in this profile)
                 $(smbios_default_text)
                 INHERITED -- lib/smbios.sh's MQG_SMBIOS_DEFAULT. Baked into OpenCore's config.plist by \`vmavs boot-stack\`; this profile and this template never set it as a QEMU argument.
  field names & nesting (the HCL2 schema itself)
                 REASONED -- from Packer's documented qemu-plugin schema.
                 UNVERIFIED: no packer is installed on this host. Run
                 \`vmavs emit packer --check\` once one is, and record the
                 result in NOTES.md.
EOF
    exit 0
fi

# --- the template --------------------------------------------------------

emit_template() {
    cat <<HEADER
# Generated by \`vmavs emit packer\` -- do not edit; re-emit instead.
#
# Profile: $profile (vm/profiles/$profile.args${commit_profile:+ @ $commit_profile})
#
# WHAT HAS AND HAS NOT BEEN VERIFIED
#
# Every value below is labelled inline as MEASURED (this profile's own
# file sets it), INHERITED (only its @include does), or REASONED (neither
# does, and a fallback default was used -- or, for the drive mapping
# below, this script's own interpretation of Packer's qemuargs-override
# behavior, never run against a real Packer). Read the value with its own
# label; do not assume every field is the strongest kind just because some
# are.
#
# The FIELD NAMES AND NESTING have never been checked against a real
# Packer. NO PACKER HAS EVER PARSED THIS FILE: packer is not installed on
# the host that generated it, and this project installs nothing to make
# that true. Run \`packer validate\` on it and write the result into
# NOTES.md; \`vmavs emit packer --check\` does exactly that the moment
# packer is on PATH.
#
# THIS TEMPLATE CONTAINS NO APPLE BYTES and must never be changed so that
# it does. It names local paths that YOU produced with \`vmavs boot-stack\`
# and \`vmavs media\`. A box built from it can never be shared: it
# contains Apple's operating system. There is deliberately no Vagrant
# Cloud box_tag here.
#
# WHY THERE IS NO boot_command
#
# Packer's central value is GUI keystroke automation during install, and
# P4 engineered that need away: Apple's own installer reads
# /etc/rc.cdrom.local, Extras/minstallconfig.xml and OSInstall.collection
# straight off the media, so the install proceeds unattended with nobody
# typing at a console. That is why this is an emit target and not the
# build.
#
# WHAT THIS PROFILE HAS THAT PACKER'S FIRST-CLASS FIELDS DO NOT COVER
#
# machine_type, cpu_model, memory, cpus and disk_size below are Packer's
# own qemu-plugin fields. Everything else this profile configures -- OVMF
# as a genuinely split CODE/VARS pflash pair, the ich9 USB controllers,
# the OpenCore boot image on its own USB drive, the installer media and
# target disk (see DRIVE MAPPING below), the NIC, USB keyboard/mouse, and
# the VGA device -- has no first-class field, so it is passed through in
# \`qemuargs\`, unchanged from the profile line for line except where DRIVE
# MAPPING says otherwise.
#
# SystemProductName ($(smbios_default_text)), which is NOT a QEMU flag
# in this profile at all: it is baked into OpenCore's config.plist by
# \`vmavs boot-stack\`, once, before this template ever runs -- so there is
# no \`-smbios\` line here, and no isa-applesmc device carrying Apple's
# OSK string either. This profile has neither, and this template must
# never grow one: that string is Apple's and belongs nowhere this project
# writes.
#
# DRIVE MAPPING IS REASONED, NOT MEASURED, AND HERE IS WHY.
#
# packer-plugin-qemu's own documented behavior: ANY -drive you place in
# qemuargs replaces ALL of its default -drive arguments, and any -device
# you place there replaces its default -device arguments too. This
# template always has to supply its own -drive entries (there is no
# first-class field for a split CODE/VARS pflash pair at all), which means
# Packer's own iso_url attachment and its own freshly-created output disk
# do NOT get attached automatically once qemuargs is in play.
#
# So the installer media and the target disk are KEPT in qemuargs, not
# dropped, each rewritten from the profile's own line rather than invented:
#   * installer (id=installer, present only on profiles that have one) ->
#     ide-hd, file=\${var.media}, exactly as the profile attaches it.
#     iso_url below still names the same file -- packer-plugin-qemu's
#     schema appears to require an iso_url regardless -- which is very
#     likely redundant given the paragraph above. REASONED, unverified,
#     and named here rather than hidden. This is also why there is no
#     ide-cd and no boot_command: OpenCore's ScanPolicy here is
#     HFS+-on-SATA only, and Packer's default iso attachment is a
#     CD-ROM -- the profile's own comment on its installer drive is the
#     MEASURED reason ide-hd replaced ide-cd upstream, and it applies to
#     this template exactly as it does to the real build.
#   * target (id=target, present only on profiles that have one) -> ide-hd,
#     file pointed at $TARGET_DISK_PATH -- packer-plugin-qemu's documented
#     <output_directory>/<vm_name>.<format> naming for the disk it would
#     otherwise have created and attached itself. output_directory and
#     vm_name are set explicitly below so this path is self-consistent
#     with what the rest of the template declares, but no \`packer build\`
#     has ever run against this file to confirm the convention.
# Neither is dropped for any profile that lacks one: a profile with no
# installer drive (p3-full, which boots against a blank target with no
# separate installer media at all) simply never has an "installer" id to
# rewrite, and this template reflects that rather than inventing one.
HEADER

    cat <<'PLUGIN'

packer {
  required_plugins {
    qemu = { source = "github.com/hashicorp/qemu", version = "~> 1" }
  }
}

variable "media" {
  type        = string
  description = "Installer media image from `vmavs media`"
}

variable "ovmf_code" {
  type        = string
  description = "OVMF_CODE.fd from `vmavs boot-stack`"
}

variable "ovmf_vars" {
  type        = string
  description = "This VM's own OVMF_VARS.fd (boot/make-nvram.sh; never the shared template)"
}

variable "opencore_media" {
  type        = string
  description = "OpenCore boot image from `vmavs boot-stack`"
}

variable "ssh_key" {
  type        = string
  description = "Private key whose public half vmavs boot-stack's payload authorized"
}

PLUGIN

    printf 'source "qemu" "mavericks" {\n'
    printf '  iso_url      = var.media # REASONED: likely redundant once qemuargs supplies its own installer -drive; see DRIVE MAPPING above\n'
    printf '  iso_checksum = "none" # the media is yours; vmavs media checksums its own inputs\n'
    printf '  disk_image   = false\n'
    printf '  disk_size    = "%s" # REASONED -- image/build-image.sh disk_gb default; no profile sets a size\n' "$disk_size"
    printf '  format       = "qcow2"\n'
    printf '  output_directory = "%s" # REASONED: the qemuargs target drive below assumes this exact convention\n' "$OUTPUT_DIRECTORY"
    printf '  vm_name          = "%s"\n' "$VM_NAME"
    printf '\n'
    printf '  machine_type = "%s" # %s\n' "$machine" "$(source_label "$machine_prov")"
    printf '  cpu_model    = "%s" # %s\n' "$cpu" "$(source_label "$cpu_prov")"
    printf '  memory       = %s # %s\n' "$mem" "$(source_label "$mem_prov")"
    printf '  cpus         = %s # %s\n' "$smp" "$(source_label "$smp_prov")"
    printf '\n'
    printf '  headless     = true # covers this profile'"'"'s "-display none"\n'
    printf '\n'
    printf '  communicator          = "ssh"\n'
    printf '  ssh_username          = "mavsuser"\n'
    printf '  ssh_private_key_file  = var.ssh_key\n'
    printf '  ssh_timeout           = "60m"\n'
    if [ -n "$ssh_port" ]; then
        printf '  # This profile forwards the guest'"'"'s SSH port to a FIXED host port\n'
        printf '  # (%s, not a range Packer picks itself) because qemuargs below\n' "$ssh_port"
        printf '  # supplies its own -netdev/-device rather than letting the\n'
        printf '  # qemu-plugin build one -- REASONED, unverified: whether the plugin\n'
        printf '  # honors a fixed port instead of adding a second NIC is exactly the\n'
        printf '  # kind of nesting question --check exists to close.\n'
        printf '  ssh_host_port_min = %s\n' "$ssh_port"
        printf '  ssh_host_port_max = %s\n' "$ssh_port"
    else
        printf '  # %s sets no hostfwd of its own -- its NIC (%s) forwards no\n' "$profile" "${nic_model:-none}"
        printf '  # fixed host port, so this template sets no ssh_host_port_min/max\n'
        printf '  # either, rather than inventing one. REASONED, unverified: whether\n'
        printf '  # Packer'"'"'s SSH communicator can even reach a guest whose\n'
        printf '  # -netdev/-device came entirely from qemuargs, with no forwarded\n'
        printf '  # port declared anywhere, is exactly the kind of question --check\n'
        printf '  # exists to close once a real Packer runs against this file.\n'
    fi
    printf '\n'
    printf '  qemuargs = [\n'
    local entry flag val
    for entry in "${qemuargs[@]+"${qemuargs[@]}"}"; do
        flag=${entry%%	*}
        val=${entry#*	}
        printf '    ["%s", "%s"],\n' "$flag" "$val"
    done
    printf '  ]\n'
    printf '}\n'

    cat <<'BUILD'

build {
  sources = ["source.qemu.mavericks"]

  # decisions/0007 and docs/test-hosts.md: a box built from this contains
  # Apple's operating system and can never be shared. No Vagrant Cloud
  # box_tag here, on purpose, forever.
  post-processor "vagrant" {
    output = "mavericks-{{.Provider}}.box"
  }
}
BUILD
}

if [ -n "$out" ]; then
    emit_template > "$out"
    log "wrote $out (no packer has parsed it -- see its own header)"
else
    emit_template
fi

# --- --check ---------------------------------------------------------------

if [ "$check" -eq 1 ]; then
    [ -n "$out" ] || die "--check needs --out: nothing to validate on stdout"
    if ! command -v packer >/dev/null 2>&1; then
        die "packer is not installed / not on PATH -- cannot validate $out." \
            "This is the expected state on this project's hosts today; the" \
            "template's own header says so. Install packer and re-run" \
            "--check, then record the result in NOTES.md."
    fi
    if ! packer validate "$out"; then
        die "packer validate failed against $out -- see its output above"
    fi
    log "packer validate: OK against $out. Record this in NOTES.md: it is" \
        "the first time any Packer has ever parsed this template."
fi
