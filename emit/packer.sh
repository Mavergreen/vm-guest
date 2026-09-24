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
# The VALUES this script writes are MEASURED or INHERITED: they come from
# the named profile as lib/profile.sh's own %BUILD%/%IMAGES%/%VENDOR%
# expansion produces it -- the same code every other caller of a profile
# uses, never reparsed by hand here -- with completed installs behind them
# (docs/decisions/0009, docs/decisions/0010).
#
# The FIELD NAMES AND NESTING -- which Packer block a value belongs in,
# and under what key -- are REASONED from Packer's documented qemu-plugin
# schema. NO PACKER HAS EVER PARSED A FILE THIS SCRIPT WROTE: packer is
# not installed on the host this was written on, and this project
# installs nothing to make that true. `--check` exists to close that gap
# the moment somebody with packer runs it; until then, every emitted
# template says so in its own header.
#
# THE NEVER-PUBLISH RULE REACHES HERE TOO. The emitted template references
# local paths and embeds no Apple bytes -- no InstallESD/BaseSystem
# content, no `osk=` string. bin/tier-check.sh --strict covers emit/ for
# the same reason it covers vm/profiles/.
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

machine=''
cpu=''
mem=''
smp=''
qemuargs=()   # each entry: "flag\tvalue", in profile order
skip_drive_id=''
netdev_hostfwd=''

# rewrite_drive_file <value> -- a -drive value with a bare host path
# under file= replaced by the Packer variable that names the same
# artifact once `vmavs boot-stack`/`vmavs media` have produced it. Only
# the three drives this profile's boot chain actually needs once Packer
# is supplying the installer media and the output disk itself; see the
# "DROPPED ON PURPOSE" note in the template header below for the two that
# are not rewritten because they are not emitted at all.
rewrite_drive_file() {
    # The ${...} inside each sed replacement below is literal HCL2 output
    # (a Packer variable reference), not a shell expansion -- the single
    # quotes are deliberate, hence the per-line disables.
    case $1 in
        *OVMF_CODE.fd*)
            # shellcheck disable=SC2016
            printf '%s\n' "$(printf '%s' "$1" | sed 's#file=[^,]*#file=${var.ovmf_code}#')" ;;
        *VARS.fd*)
            # shellcheck disable=SC2016
            printf '%s\n' "$(printf '%s' "$1" | sed 's#file=[^,]*#file=${var.ovmf_vars}#')" ;;
        *opencore*.img*)
            # shellcheck disable=SC2016
            printf '%s\n' "$(printf '%s' "$1" | sed 's#file=[^,]*#file=${var.opencore_media}#')" ;;
        *) printf '%s\n' "$1" ;;
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
            id=$(printf '%s' "$val" | sed -n 's/.*\bid=\([^,]*\).*/\1/p')
            case $id in
                target|installer)
                    # DROPPED ON PURPOSE: this template's own fields
                    # replace both. `media` (iso_url) replaces the
                    # installer drive; `disk_size` replaces the target
                    # drive -- a qemu-plugin build always creates and
                    # formats its own output disk. Keeping either verbatim
                    # would leave two competing definitions of the same
                    # thing.
                    skip_drive_id=$id
                    i=$((i + 2))
                    continue ;;
            esac
            qemuargs+=("$line	$(rewrite_drive_file "$val")")
            i=$((i + 2)) ;;
        -device)
            val=${expanded[$((i + 1))]}
            if [ -n "$skip_drive_id" ] \
               && printf '%s' "$val" | grep -q "drive=$skip_drive_id"; then
                skip_drive_id=
                i=$((i + 2))
                continue
            fi
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

[ -n "$mem" ] || mem=$(build_image_default ram)
[ -n "$mem" ] || mem=4096
[ -n "$smp" ] || smp=$(build_image_default smp)
[ -n "$smp" ] || smp=2
[ -n "$cpu" ] || cpu=$MQG_CPU_DEFAULT
[ -n "$machine" ] || machine=q35

disk_gb=$(build_image_default disk_gb)
[ -n "$disk_gb" ] || disk_gb=60
disk_size="$((disk_gb * 1024))M"

ssh_port=$(printf '%s' "$netdev_hostfwd" | sed -n 's/.*hostfwd=tcp::\([0-9]*\)-:22.*/\1/p')
[ -n "$ssh_port" ] || ssh_port=2222

commit_profile=$(profile_commit "$profile")
commit_base=$(profile_commit base-kvm)

# --- --describe --------------------------------------------------------

if [ "$describe" -eq 1 ]; then
    cat <<EOF
vmavs emit packer --describe --profile $profile

Where the emitted template's values come from. MEASURED and INHERITED
values have a completed install behind them; REASONED does not.

  machine_type   $machine
                 MEASURED -- vm/profiles/$profile.args${commit_profile:+ @ $commit_profile}
  cpu_model      $cpu
                 MEASURED -- same profile, docs/decisions/0009
  memory         ${mem} MB
                 INHERITED -- vm/profiles/base-kvm.args${commit_base:+ @ $commit_base}, pulled in by this profile's @include
  cpus           $smp
                 INHERITED -- same @include
  disk_size      $disk_size
                 INHERITED -- image/build-image.sh's disk_gb default; this profile sets no size of its own
  network        usb-net on usb.0, hostfwd tcp::${ssh_port}-:22
                 MEASURED -- same profile (docs/open-questions.md Q2, docs/decisions/0008 explain usb-net over e1000)
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
#          vm/profiles/base-kvm.args${commit_base:+ @ $commit_base} (@include)
#
# WHAT HAS AND HAS NOT BEEN VERIFIED
#
# The VALUES below are MEASURED or INHERITED: they are the same -machine,
# -cpu, memory, cpu count, NIC and drive lines the profile above carries,
# read through lib/profile.sh's own expansion -- not retyped by hand --
# and docs/decisions/0009 and docs/decisions/0010 each have a completed,
# SSH-reachable install behind the CPU and SMBIOS choices.
#
# The FIELD NAMES AND NESTING have never been checked against a real
# Packer. NO PACKER HAS EVER PARSED THIS FILE: packer is not installed on
# the host that generated it, and this project installs nothing to make
# that true. Run \`packer validate\` on it and write the result into
# NOTES.md; \`vmavs emit packer --check\` does exactly that the moment
# packer is on PATH. Until then, treat the block structure below as
# REASONED, not measured.
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
# the OpenCore boot image on its own USB drive, a USB NIC with a fixed
# port forward, USB keyboard/mouse, and the VGA device -- has no
# first-class field, so it is passed through in \`qemuargs\`, unchanged
# from the profile line for line.
#
# SystemProductName ($(smbios_default_text)), which is NOT a QEMU flag
# in this profile at all: it is baked into OpenCore's config.plist by
# \`vmavs boot-stack\`, once, before this template ever runs -- so there is
# no \`-smbios\` line here, and no isa-applesmc device carrying Apple's
# OSK string either. This profile has neither, and this template must
# never grow one: that string is Apple's and belongs nowhere this project
# writes.
#
# DROPPED ON PURPOSE: the two drives this template's own fields replace.
# The profile's installer media (id=installer) is the \`media\` variable's
# job (iso_url); its target disk (id=target) is \`disk_size\`'s job -- a
# qemu-plugin build always creates and formats its own output disk. Both
# are gone from qemuargs below so there are not two competing definitions
# of either.
HEADER

    cat <<'PLUGIN'

packer {
  required_plugins {
    qemu = { source = "github.com/hashicorp/qemu", version = "~> 1" }
  }
}

variable "media"          { type = string  description = "Installer media image from `vmavs media`" }
variable "ovmf_code"      { type = string  description = "OVMF_CODE.fd from `vmavs boot-stack`" }
variable "ovmf_vars"      { type = string  description = "This VM's own OVMF_VARS.fd (boot/make-nvram.sh; never the shared template)" }
variable "opencore_media" { type = string  description = "OpenCore boot image from `vmavs boot-stack`" }
variable "ssh_key"        { type = string  description = "Private key whose public half vmavs boot-stack's payload authorized" }

PLUGIN

    printf 'source "qemu" "mavericks" {\n'
    printf '  iso_url      = var.media\n'
    printf '  iso_checksum = "none" # the media is yours; vmavs media checksums its own inputs\n'
    printf '  disk_image   = false\n'
    printf '  disk_size    = "%s" # INHERITED: image/build-image.sh disk_gb default (this profile sets no size)\n' "$disk_size"
    printf '  format       = "qcow2"\n'
    printf '\n'
    printf '  machine_type = "%s" # MEASURED: vm/profiles/%s.args\n' "$machine" "$profile"
    printf '  cpu_model    = "%s" # MEASURED: same profile, docs/decisions/0009\n' "$cpu"
    printf '  memory       = %s # INHERITED: vm/profiles/base-kvm.args, pulled in by @include\n' "$mem"
    printf '  cpus         = %s # INHERITED: same @include\n' "$smp"
    printf '\n'
    printf '  headless     = true # covers this profile'"'"'s "-display none"\n'
    printf '\n'
    printf '  communicator          = "ssh"\n'
    printf '  ssh_username          = "mavsuser"\n'
    printf '  ssh_private_key_file  = var.ssh_key\n'
    printf '  ssh_timeout           = "60m"\n'
    printf '  # This profile forwards the guest'"'"'s SSH port to a FIXED host port\n'
    printf '  # (%s, not a range Packer picks itself) because qemuargs below\n' "$ssh_port"
    printf '  # supplies its own -netdev/-device rather than letting the\n'
    printf '  # qemu-plugin build one -- REASONED, unverified: whether the plugin\n'
    printf '  # honors a fixed port instead of adding a second NIC is exactly the\n'
    printf '  # kind of nesting question --check exists to close.\n'
    printf '  ssh_host_port_min = %s\n' "$ssh_port"
    printf '  ssh_host_port_max = %s\n' "$ssh_port"
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
