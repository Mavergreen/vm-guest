#!/usr/bin/env bash
# One command, from a clean checkout to a bootable, SSH-reachable Mavericks
# image, with nobody watching. This is goal #2.
#
# WHAT IT DOES NOT DO
#
# It does not reimplement anything. Every stage below is an existing script
# in this repository, run in order, with its output checked before it is run
# again. The value here is the ordering, the skipping, and the manifest --
# not the work, which was already written and already tested.
#
# WHY IT IS PARAMETERISED
#
# P6 runs this same pipeline under TCG on arm64. Accelerator, machine type,
# CPU model and memory are therefore arguments from the start rather than
# something retrofitted when the second consumer appears, because a second
# pipeline would be a second thing to keep correct.
#
# WHY IT IS RESUMABLE, AND WHAT "ALREADY DONE" MEANS
#
# Each stage records what it consumed and reruns when that record stops
# matching -- NOT when its output file is missing, which is what this used
# to check. The install alone is a quarter of an hour and the OpenCore
# build is longer; a pipeline that cannot resume gets debugged an hour at a
# time, which is how a two-hour session becomes a two-day one. But a
# pipeline that resumes past a moved pin builds an image out of stale
# firmware and says nothing, which is worse. See "stage freshness" below,
# and `--freshness` for the answer without the build.
#
# WHERE THINGS GO
#
# Everything under $MQG_IMAGE_DIR, never in the repository: the repo is on
# NFS at roughly 18 ms per file create, and a guest image must never be
# published.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/cpu.sh
. "$MQG_REPO_ROOT/lib/cpu.sh"
# shellcheck source=../lib/smbios.sh
. "$MQG_REPO_ROOT/lib/smbios.sh"

# Used by log()/warn()/die() in lib/common.sh, which read it at call time.
# shellcheck disable=SC2034
MQG_LOG_PREFIX=build-image

# --- stages ----------------------------------------------------------------
#
# "<name>|<one-line description>". The order is the pipeline.
STAGES="\
esd|Fetch Apple's InstallESD.dmg, SHA-256 verified (media/fetch-installesd.sh)
opencore|Build OpenCore from pinned source (boot/build-opencore.sh)
ovmf|Build the guest's UEFI firmware from the same tree (boot/build-ovmf.sh)
efi|Assemble the OpenCore EFI image (boot/build-efi-image.sh)
openssh|Fetch the guest's own OpenSSH, pinned and verified (image/fetch-openssh.sh)
payload|Build the first-boot payload package (image/payload/build-firstboot-pkg.sh)
media|Build installer media with the unattended hooks and the payload
target|Create the blank target disk and this VM's own EFI variable store
install|Boot the media, install unattended, wait for SSH to answer
verify|Ask the guest what it is, over SSH
manifest|Record every input that produced this image"

MANIFEST_FIELDS="\
name|the image this manifest describes
commit|the git commit this was built from, and whether the tree was dirty
built|when the build finished
esd|sha256 of Apple's InstallESD.dmg
media|sha256 of the installer media file built from it (not byte-stable)
mediacontent|sha256 over every file on that media -- the part that is stable
opencore|sha256 of the OpenCore EFI image
ovmf|sha256 of the guest firmware (OVMF_CODE.fd)
config|sha256 of boot/config/config.plist
payload|sha256 of the first-boot payload package
sshkey|fingerprint of the public key authorized in the image
openssh|the ModernMavericks/openssh release the guest got, or none
updates|which post-10.9.5 updates the image carries
nic|the network device the guest was installed and verified with
accel|accelerator, machine, cpu, memory and disk size
cpuline|whether that -cpu line was one this project had evidence for, as judged when this image was built (lib/cpu.sh)
smbios|the SMBIOS model OpenCore told the guest it was, and whether this project had evidence for it when this image was built (lib/smbios.sh)
qemu|the QEMU this was built with
compiler|the C compiler the boot stack was built with, and the dialect it was asked for -- NOT a pin, see docs/decisions/0004
compilerrange|whether that compiler was inside the range this project declares it supports, as judged when this image was built (lib/compiler.sh)
ccache|whether the firmware was compiled through ccache, which is claimed to change nothing and is recorded so that claim stays checkable (lib/ccache.sh)
image|sha256 and size of the qcow2 produced
ingredients|digest over every pin this repo controls (bin/ingredient-fingerprint.sh)
ingredient.*|each of those pins, one line each, so a diff names what moved"

# --- defaults --------------------------------------------------------------

name=
accel=kvm
machine=q35
# THE GUEST CPU MODEL IS A PARAMETER, AND WHICH LINES ARE KNOWN TO WORK IS
# A MEASUREMENT.
#
# See lib/cpu.sh for the table and docs/decisions/0009 for how it was
# arrived at. Two things worth knowing before you change this line:
# Mavericks does NOT require SSE4.1 (Conroe boots), and `+ssse3` and
# `+sse4.1` are redundant with the `Penryn` model while `+sse4.2` is not.
# The default is unchanged anyway, because it is the only line with a
# completed install behind it -- twice, on two QEMUs.
#
# Unlike --nic and --updates this is NOT validated against its list. The
# list is guidance; an arbitrary QEMU -cpu string still works and only
# earns a warning. A host this project has never seen must not be blocked
# by our ignorance.
cpu=$MQG_CPU_DEFAULT
# THE GUEST'S SMBIOS MODEL IS A PARAMETER, AND WHY IT IS NOT MacPro5,1 IS
# AN OBSERVATION WITH AN UNTESTED EXPLANATION ATTACHED.
#
# See lib/smbios.sh for the table and docs/decisions/0010 for the reasoning.
# Like --cpu and unlike --nic and --updates, an unlisted value WARNS rather
# than being refused -- only a string that cannot be written into a plist
# is refused, because that produces a failure about our edit rather than
# about the guest.
smbios=$MQG_SMBIOS_DEFAULT
ram=4096
smp=2
disk_gb=60
qemu_bin=${MQG_QEMU:-qemu-system-x86_64}
ssh_port=2222
ssh_key=
ssh_user=mavsuser
# docs/open-questions.md Q1 asks whether images should carry Apple's
# post-10.9.5 updates and names P4 as its deadline. This pipeline does not
# answer it. What it does is leave the question answerable: a switch with
# one value implemented, rather than the absence of a switch.
updates=none
UPDATES_CHOICES="none"
# THE NETWORK DEVICE IS A PARAMETER, AND WHICH ONE IS DEFAULT IS A
# MEASUREMENT.
#
# See docs/open-questions.md Q2 and docs/decisions/0008. `usb-net` was
# inherited from the UTM bundle in P1 because it demonstrably booted; it
# was measured on 2026-09-21 and it is CDC-ECM at 10 Mbit/s. The default
# below is the one the measurement chose; the others stay reachable
# because an image is not only built here.
#
# A NIC is not a runtime knob. 10.9 records the interfaces it has seen in
# /Library/Preferences/SystemConfiguration, and an image installed with
# one NIC does not configure a different one when it is swapped in later
# -- measured, both directions. So the device belongs to the build, and
# the manifest records which one the image was made with.
nic=e1000-82545em
NIC_CHOICES="usb-net e1000-82545em virtio-net-pci"
# THE GUEST'S OWN OPENSSH, ON BY DEFAULT.
#
# Goal #1 is a guest that is usable for development work, and SSH is the
# entire interface to it. A stock 10.9 guest answers on OpenSSH 6.2p2,
# which cannot read an Ed25519 authorized_keys line and offers only host
# keys a 2026 client refuses -- so the default has to be the one where the
# thing works when you try it. --no-openssh still builds the stock image,
# and the manifest says which you got.
openssh=1
describe=0
dry_run=0
freshness=0
force=0
from_stage=
only_stage=
install_timeout=${MQG_INSTALL_TIMEOUT:-3600}
generate_key=0
keep_running=0

usage() {
    cat <<EOF
usage: $(basename "$0") [options]

  --name NAME          Image name (default: mavericks-<UTC date>)
  --accel kvm|tcg      Accelerator (default: $accel). P6 uses tcg.
  --machine TYPE       QEMU machine type (default: $machine)
  --cpu MODEL          QEMU CPU model (default: $cpu)
                       Any QEMU -cpu string works. --cpu-models lists the
                       ones this project has evidence for, and an unlisted
                       one warns rather than refuses (lib/cpu.sh).
  --smbios MODEL       SMBIOS SystemProductName OpenCore gives the guest
                       (default: $smbios). Changes that ONE field; the
                       serial, board serial, ROM and UUID are left alone
                       and OpenCore derives the board id from the model.
                       --smbios-models lists what has been tried.
  --ram MB             Guest memory (default: $ram)
  --smp N              Guest CPUs (default: $smp). Not 1: 10.9's first boot
                       after install is reported to fail without SMP.
  --disk-gb N          Target disk size (default: $disk_gb)
  --qemu BINARY        QEMU to run (default: $qemu_bin)
  --ssh-port N         Host port forwarded to the guest's 22 (default: $ssh_port)
  --ssh-key PATH       Public key to authorize (default: ~/.ssh/id_*.pub)
  --generate-ssh-key   If no key is found, create one under
                       \$MQG_IMAGE_DIR/keys. Opt-in: this pipeline does not
                       invent secrets unless asked.
  --openssh            Install the family's OpenSSH in the guest (default)
  --no-openssh         Leave the guest on stock OpenSSH 6.2. An Ed25519 key
                       is then refused at build time, and reaching the guest
                       needs a client that still speaks ssh-rsa.
  --updates WHICH      Post-10.9.5 updates to include ($UPDATES_CHOICES)
  --nic DEVICE         Guest network device (default: $nic)
                       Choices: $NIC_CHOICES
                       virtio-net-pci has no driver in 10.9 and produces an
                       image with no network -- see docs/open-questions.md Q2.
  --from STAGE         Start at this stage, skipping earlier ones
  --stage STAGE        Run only this stage
  --force              Redo stages whose outputs already exist
  --keep-running       Leave the VM running after the install stage
  --install-timeout S  Give up on the install after S seconds (default: $install_timeout)
  --describe           Print the plan and exit. Touches nothing.
  --freshness          Say, for each stage, whether it would run and why,
                       and exit. Touches nothing. This is the question
                       "will my next build rebuild the firmware, and what
                       moved?" asked in a second rather than in 14 minutes.
  --dry-run            Print the QEMU command line and exit. Starts nothing.
  --manifest-fields    List what the manifest records, and exit.
  --cpu-models         List the guest CPU lines this project has tried, the
                       status of each and the evidence behind it, and exit.
  --smbios-models      List the SMBIOS models this project has tried, the
                       status of each and the evidence behind it, and exit.

Stages, in order:
$(printf '%s\n' "$STAGES" | while IFS='|' read -r s d; do printf '  %-9s %s\n' "$s" "$d"; done)
EOF
}

stage_names() { printf '%s\n' "$STAGES" | cut -d'|' -f1; }

is_stage() {
    local want=$1 s
    for s in $(stage_names); do [ "$s" = "$want" ] && return 0; done
    return 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --name) name=$2; shift ;;
        --accel) accel=$2; shift ;;
        --machine) machine=$2; shift ;;
        --cpu) cpu=$2; shift ;;
        --smbios) smbios=$2; shift ;;
        --ram) ram=$2; shift ;;
        --smp) smp=$2; shift ;;
        --disk-gb) disk_gb=$2; shift ;;
        --qemu) qemu_bin=$2; shift ;;
        --ssh-port) ssh_port=$2; shift ;;
        --ssh-key) ssh_key=$2; shift ;;
        --ssh-user) ssh_user=$2; shift ;;
        --generate-ssh-key) generate_key=1 ;;
        --openssh) openssh=1 ;;
        --no-openssh) openssh=0 ;;
        --updates) updates=$2; shift ;;
        --nic) nic=$2; shift ;;
        --from) from_stage=$2; shift ;;
        --stage) only_stage=$2; shift ;;
        --force) force=1 ;;
        --keep-running) keep_running=1 ;;
        --install-timeout) install_timeout=$2; shift ;;
        --describe) describe=1 ;;
        --freshness) freshness=1 ;;
        --dry-run) dry_run=1 ;;
        --cpu-models)
            cpu_models | while IFS='	' read -r m st ev; do
                printf '%-32s %s\n' "$m" "$st"
                printf '%s\n' "$ev" | fold -s -w 68 | sed 's/^/    /'
            done
            printf '\ndefault: %s\n' "$(cpu_default_text)"
            exit 0 ;;
        --smbios-models)
            smbios_models | while IFS='	' read -r m st ev; do
                printf '%-32s %s\n' "$m" "$st"
                printf '%s\n' "$ev" | fold -s -w 68 | sed 's/^/    /'
            done
            printf '\ndefault: %s\n' "$(smbios_default_text)"
            exit 0 ;;
        --manifest-fields)
            printf '%s\n' "$MANIFEST_FIELDS" \
                | while IFS='|' read -r f d; do printf '%-9s %s\n' "$f" "$d"; done
            exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

# Validated before anything else, so a typo costs nothing. An unknown
# accelerator used to be discovered by QEMU, fifteen minutes in.
case $accel in
    kvm|tcg) : ;;
    *) die "unknown accel '$accel': use kvm or tcg" ;;
esac
case " $UPDATES_CHOICES " in
    *" $updates "*) : ;;
    *) die "unknown --updates '$updates': choose one of $UPDATES_CHOICES." \
           "See docs/open-questions.md Q1 -- the switch exists so that" \
           "question stays answerable without rewriting this pipeline." ;;
esac
case " $NIC_CHOICES " in
    *" $nic "*) : ;;
    *) die "unknown --nic '$nic': choose one of $NIC_CHOICES." \
           "See docs/open-questions.md Q2 for what each one measured." ;;
esac
# REFUSED HERE, AND ONLY FOR THIS REASON. An UNKNOWN model is allowed
# through with a warning further down (lib/smbios.sh) -- a user on hardware
# this project has never met must not be blocked by our ignorance. A string
# that cannot be written into a plist is a different thing: it would build
# firmware for fourteen minutes and then fail in a way that is about our
# edit rather than about the guest, which is the most expensive kind of
# failure because it looks like a result.
smbios_wellformed "$smbios" \
    || die "unusable --smbios '$smbios': letters, digits, comma, dot, dash" \
           "and underscore only, 64 characters at most. The value becomes" \
           "PlatformInfo > Generic > SystemProductName in the guest's" \
           "config.plist. --smbios-models lists the ones with evidence."
[ -z "$from_stage" ] || is_stage "$from_stage" \
    || die "no such stage '$from_stage'; stages are: $(stage_names | tr '\n' ' ')"
[ -z "$only_stage" ] || is_stage "$only_stage" \
    || die "no such stage '$only_stage'; stages are: $(stage_names | tr '\n' ' ')"

name=${name:-mavericks-$(date -u +%Y%m%d)}

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
export MQG_IMAGE_DIR
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
export MQG_BUILD_DIR

images_dir=$MQG_IMAGE_DIR/images
work_dir=$MQG_IMAGE_DIR/work/build-$name
media_img=$MQG_IMAGE_DIR/media/installer-linux.img
esd_dmg=$MQG_IMAGE_DIR/media/InstallESD.dmg
efi_img=$MQG_IMAGE_DIR/work/opencore-p3.img
firmware_dir=$MQG_BUILD_DIR/firmware
payload_pkg=$MQG_IMAGE_DIR/payload/mqg-firstboot.pkg
config_plist=$MQG_REPO_ROOT/boot/config/config.plist
out_qcow2=$images_dir/$name.qcow2
manifest=$images_dir/$name.manifest
vars_fd=$work_dir/OVMF_VARS.fd
monitor=$work_dir/monitor.sock
qemu_log=$work_dir/qemu.log
installed_stamp=$work_dir/installed

# --- the QEMU command line -------------------------------------------------
#
# Built here rather than read from vm/profiles/, because the point of this
# script is that the hardware is a parameter. The profiles stay what they
# are for: one-variable-at-a-time experiments, where the diff IS the
# experiment. This is the other kind of thing, and it references nothing in
# the Tier 2 quarantine -- every path below is built from pinned source.
# The one line that differs between the NIC choices. usb-net is a USB
# device and hangs off the EHCI controller; everything else is PCI and
# QEMU places it itself.
nic_device() {
    case $nic in
        usb-net) printf '%s\n' "usb-net,bus=usb.0,netdev=net0" ;;
        *)       printf '%s\n' "$nic,netdev=net0" ;;
    esac
}

# qemu_args <with-media|without-media>
#
# The installer media is attached only while installing. The verify stage
# boots without it on purpose: an image that only boots with its installer
# next to it is not the deliverable, and OpenCore choosing the right volume
# with the media present is not evidence that it would without.
qemu_args() {
    local with_media=${1:-with-media}
    printf '%s\n' \
        -accel "$accel" \
        -machine "$machine,vmport=off" \
        -cpu "$cpu" \
        -m "$ram" \
        -smp "$smp" \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$firmware_dir/OVMF_CODE.fd" \
        -drive "if=pflash,format=raw,unit=1,file=$vars_fd" \
        -device "ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on" \
        -device "ich9-usb-uhci1,masterbus=usb.0,firstport=0,bus=pcie.0,addr=0x1d.0,multifunction=on" \
        -device "ich9-usb-uhci2,masterbus=usb.0,firstport=2,bus=pcie.0,addr=0x1d.1" \
        -device "ich9-usb-uhci3,masterbus=usb.0,firstport=4,bus=pcie.0,addr=0x1d.2" \
        `# snapshot=on: the guest may write to the OpenCore image, and the` \
        `# file must not change when it does. Without it, EVERY boot rewrote` \
        `# the bootloader image -- build ba9eab36, then 7f4ce3aa, 0ad83718,` \
        `# 11c5ca9a -- so the manifest recorded a different "opencore" for` \
        `# two builds that used the same one, and P3's pinned checksum for` \
        `# the boot stack stopped matching the file on disk after the first` \
        `# run. QEMU keeps the writes in a temporary overlay and throws them` \
        `# away at exit. Found by image/compare-images.sh, which is what it` \
        `# is for.` \
        -drive "id=opencore,if=none,format=raw,snapshot=on,file=$efi_img" \
        -device "usb-storage,bus=usb.0,drive=opencore" \
        -drive "id=target,if=none,format=qcow2,file=$out_qcow2" \
        -device "ide-hd,bus=ide.0,drive=target" \
        -netdev "user,id=net0,hostfwd=tcp::$ssh_port-:22" \
        -device "$(nic_device)" \
        -device "usb-kbd,bus=usb.0" \
        -device "usb-mouse,bus=usb.0" \
        -device "VGA,vgamem_mb=64" \
        -display none \
        -monitor "unix:$monitor,server,nowait"
    if [ "$with_media" = with-media ]; then
        # snapshot=on here too, and for the same reason as the OpenCore
        # image above: the guest writes to the installer media. It mounts
        # it read-write long enough for mds to create a .Spotlight-V100
        # store on it, with a fresh UUID in the directory name -- which is
        # why two builds from one ESD recorded different `mediacontent`
        # digests even though every installed file matched. The media is an
        # input; an input that the run modifies is not one.
        printf '%s\n' \
            -drive "id=installer,if=none,format=raw,snapshot=on,file=$media_img" \
            -device "ide-hd,bus=ide.1,drive=installer"
    fi
}

if [ "$describe" -eq 1 ]; then
    cat <<EOF
image pipeline
  name                $name
  output              $out_qcow2
  manifest            $manifest
  work area           $work_dir

  accel               $accel
  machine             $machine
  cpu                 $cpu
                      $(cpu_line_manifest "$cpu")
                      (--cpu-models lists the table; an unlisted line warns
                      rather than refuses -- docs/decisions/0009)
  smbios              $smbios
                      $(smbios_manifest "$smbios")
                      (--smbios-models lists the table; an unlisted model
                      warns rather than refuses -- docs/decisions/0010)
  memory              $ram MB, $smp vCPUs
  target disk         $disk_gb GB
  qemu                $qemu_bin
  ssh                 localhost:$ssh_port -> guest 22, user $ssh_user
  openssh             $([ "$openssh" -eq 1 ] && cat "$MQG_REPO_ROOT/components/openssh/version" || echo "none (stock OpenSSH 6.2)")
  nic                 $nic -> -device $(nic_device)
                      (choices: $NIC_CHOICES; docs/open-questions.md Q2)
  --updates           $updates (choices: $UPDATES_CHOICES)
                      docs/open-questions.md Q1 is not answered here; the
                      switch is what keeps it answerable.

  stages, in order (each skipped when the inputs it recorded still match --
  ask --freshness which ones those are today)
EOF
    printf '%s\n' "$STAGES" | while IFS='|' read -r s d; do
        printf '    %-9s %s\n' "$s" "$d"
    done
    cat <<EOF

  manifest fields
EOF
    printf '%s\n' "$MANIFEST_FIELDS" | while IFS='|' read -r f d; do
        printf '    %-9s %s\n' "$f" "$d"
    done
    exit 0
fi

if [ "$dry_run" -eq 1 ]; then
    # `while read` rather than `mapfile`, which is bash 4 -- see
    # bin/bash32-check.sh.
    qargs=()
    while IFS= read -r qarg; do
        [ -n "$qarg" ] || continue
        qargs+=("$qarg")
    done < <(qemu_args with-media)
    printf '%q ' "$qemu_bin" "${qargs[@]}"
    printf '\n'
    exit 0
fi

# --- helpers ---------------------------------------------------------------

started_at=$SECONDS
stage_times=

# A stage runs unless --stage names another one, or --from names a later
# one. Reported either way: "skipped" that is silent is indistinguishable
# from "ran and did nothing".
skip_before=0
[ -n "$from_stage" ] && skip_before=1

should_run() {
    local s=$1
    if [ -n "$only_stage" ]; then
        [ "$s" = "$only_stage" ]
        return
    fi
    if [ "$skip_before" -eq 1 ]; then
        if [ "$s" = "$from_stage" ]; then
            skip_before=0
        else
            return 1
        fi
    fi
    return 0
}

run_stage() {
    local s=$1 t0
    shift
    if ! should_run "$s"; then
        log "stage $s: skipped (--from/--stage)"
        return 0
    fi
    log "=== stage $s ==="
    t0=$SECONDS
    "$@"
    stage_times="$stage_times$s $((SECONDS - t0))s
"
    log "=== stage $s done in $((SECONDS - t0))s ==="
}

# "There is a file there." Used only by the target stage, whose outputs are
# an empty qcow2 and a copy of a variable-store template: neither has
# inputs worth hashing, and both are recreated in a second when absent.
# Every other stage asks stage_freshness below.
have() { [ -s "$1" ] && [ "$force" -eq 0 ]; }

# --- stage freshness -------------------------------------------------------
#
# A STAGE IS STALE WHEN ITS INPUTS MOVED, NOT WHEN ITS OUTPUT IS MISSING.
#
# This pipeline used to skip a stage whenever its output file was present.
# That is wrong in exactly the case this project built machinery to
# prevent: Renovate bumps the OpenCore or EDK II pin in vendor/sources.tsv,
# the opencore stage sees its .efi sitting there, skips, and we ship an
# image built from stale firmware without a word. bin/image-staleness.sh
# catches that afterwards, per image, from the manifest -- the pipeline
# itself never asked. ADR 0007 named this as the reason to wire
# INGREDIENTS.md up early.
#
# So each stage records what it consumed, in a `<output>.inputs` file
# beside its output, and reruns when that record stops matching. The
# listing comes from bin/ingredient-fingerprint.sh --stage: the repository
# half from the script, the pipeline half (checksums of earlier stages'
# outputs, the parameters of this run) passed in as key=value. One hashing
# scheme, one place to read what a stage depends on.
#
# WHY THE STAMP HOLDS THE LIST AND NOT THE DIGEST. Same reason the manifest
# holds both: a digest answers "did anything move", a list answers "what
# moved". A rebuild nobody can explain is barely better than a skip nobody
# can see -- build-image.sh's own comment about silent skips applies in
# both directions.

# The principal output of each stage: the file whose presence used to be
# the whole check, and the file the .inputs stamp sits beside.
stage_output_file() {
    case $1 in
        esd)      printf '%s\n' "$esd_dmg" ;;
        opencore) printf '%s\n' "$MQG_BUILD_DIR/artifacts/SHA256SUMS" ;;
        ovmf)     printf '%s\n' "$firmware_dir/OVMF_CODE.fd" ;;
        efi)      printf '%s\n' "$efi_img" ;;
        payload)  printf '%s\n' "$payload_pkg" ;;
        media)    printf '%s\n' "$media_img" ;;
        install)  printf '%s\n' "$installed_stamp" ;;
        *)        printf '\n' ;;
    esac
}

# sha256_or <file> <fallback> -- the checksum of an artifact an earlier
# stage produced, or a word saying it is not there. "absent" is a value
# like any other: a stage whose input disappeared has had an input change.
sha256_or() {
    if [ -s "$1" ]; then sha256_file "$1"; else printf '%s\n' "${2:-absent}"; fi
}

# The EFI image's checksum AS BUILT, not as it is now. The guest writes to
# that image and QEMU's snapshot=on throws the writes away, but the file
# has been rewritten in the past (see the snapshot=on comment above), so
# boot/build-efi-image.sh records the real one beside it.
efi_built_sha() {
    if [ -s "$efi_img.sha256" ]; then
        cut -d' ' -f1 < "$efi_img.sha256"
    else
        sha256_or "$efi_img"
    fi
}

ssh_key_fingerprint() {
    if [ -n "$ssh_key" ] && [ -f "$ssh_key" ] \
       && command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -lf "$ssh_key" | awk '{print $2}'
    else
        printf 'none\n'
    fi
}

# The half of a stage's inputs that only this pipeline knows: what earlier
# stages actually produced, and the parameters of this run.
stage_extra_inputs() {
    case $1 in
        efi)
            # The SMBIOS model belongs here and not only in the manifest:
            # it changes the config.plist that goes ONTO the image, and a
            # stage that skipped because its artifacts had not moved would
            # otherwise hand the next run somebody else's SMBIOS. The
            # install stage inherits the change through `efi=`, which is
            # the checksum of the image this produces.
            printf '%s\n' \
                "opencore-artifacts=$(sha256_or "$MQG_BUILD_DIR/artifacts/SHA256SUMS")" \
                "smbios=$smbios"
            ;;
        payload)
            printf '%s\n' \
                "sshkey=$(ssh_key_fingerprint)" \
                "openssh-enabled=$openssh"
            ;;
        media)
            printf '%s\n' \
                "payload=$(sha256_or "$payload_pkg")" \
                "openssh-enabled=$openssh"
            ;;
        install)
            # media is named by the digest of ITS inputs, not by the
            # checksum of the media file. Two builds from one ESD never
            # produce the same file -- mkfs.hfsplus stamps the clock into
            # the volume header (see the `mediacontent` note in the
            # manifest) -- so hashing the file here would reinstall a
            # guest every time the media was rebuilt from inputs that had
            # not changed. The firmware and the EFI image ARE byte-stable
            # and are named by their checksums.
            printf '%s\n' \
                "media=$(stage_digest media)" \
                "efi=$(efi_built_sha)" \
                "firmware=$(sha256_or "$firmware_dir/OVMF_CODE.fd")" \
                "accel=$accel" "machine=$machine" "cpu=$cpu" \
                "ram=$ram" "smp=$smp" "disk=${disk_gb}G" "nic=$nic"
            ;;
        *) : ;;
    esac
}

# stage_inputs <stage> [--digest] -- the whole listing, or a digest of it.
stage_inputs() {
    local s=$1 arg
    local -a extra=() listflag=(--list)
    [ "${2:-}" != --digest ] || listflag=()
    while IFS= read -r arg; do
        [ -n "$arg" ] || continue
        extra+=("$arg")
    done < <(stage_extra_inputs "$s")
    "$MQG_REPO_ROOT/bin/ingredient-fingerprint.sh" --stage "$s" \
        ${listflag[@]+"${listflag[@]}"} ${extra[@]+"${extra[@]}"}
}

stage_digest() { stage_inputs "$1" --digest; }

# stage_freshness <stage> -- "skip\t<reason>" or "run\t<reason>".
#
# Every branch returns a reason. A stage that reran without saying why is
# the same class of bug as a stage that skipped without saying why.
stage_freshness() {
    local s=$1 out moved
    out=$(stage_output_file "$s")
    [ -n "$out" ] || { printf 'run\tthis stage records no inputs\n'; return 0; }
    if [ "$force" -eq 1 ]; then
        printf 'run\t--force\n'
        return 0
    fi
    if [ ! -s "$out" ]; then
        printf 'run\tno output at %s yet\n' "$out"
        return 0
    fi
    if [ ! -s "$out.inputs" ]; then
        # "I cannot tell" is a different answer from "it is fine", and
        # conflating them is how a stale artifact gets trusted -- the same
        # distinction bin/image-staleness.sh makes about a manifest with no
        # ingredient lines. An output whose inputs were never recorded is
        # rebuilt once, and then it has a record.
        printf 'run\tno input record beside %s (built before stages recorded their inputs)\n' \
            "$(basename "$out")"
        return 0
    fi
    moved=$(LC_ALL=C comm -3 <(LC_ALL=C sort "$out.inputs") \
                             <(stage_inputs "$s") \
            | awk -F'\t' '{ print ($1 == "" ? $2 : $1) }' \
            | LC_ALL=C sort -u | tr '\n' ' ')
    moved=${moved% }
    if [ -z "$moved" ]; then
        printf 'skip\tinputs unchanged\n'
    else
        printf 'run\tinputs changed (%s)\n' "$moved"
    fi
}

# Ask, report, and answer "may I skip this stage?".
stage_is_fresh() {
    local s=$1 v tab verdict reason
    tab=$(printf '\t')
    v=$(stage_freshness "$s")
    verdict=${v%%"$tab"*}
    reason=${v#*"$tab"}
    if [ "$verdict" = skip ]; then
        log "$s: up to date ($reason)"
        return 0
    fi
    log "$s: $reason"
    return 1
}

# Write the stamp, after the stage has succeeded. Recomputed rather than
# reused from the freshness check: a stage that reran may have changed the
# very things a later stage reads, and the record has to describe what was
# actually consumed.
stage_record() {
    local s=$1 out
    out=$(stage_output_file "$s")
    [ -n "$out" ] || return 0
    if [ ! -s "$out" ]; then
        warn "$s: no output at $out; not recording its inputs"
        return 0
    fi
    mkdir -p "$(dirname "$out")"
    stage_inputs "$s" > "$out.inputs"
    log "$s: recorded $(wc -l < "$out.inputs" | tr -d ' ') inputs in" \
        "$(basename "$out").inputs"
}

qemu_monitor() {
    [ -S "$monitor" ] || return 1
    python3 - "$monitor" "$1" <<'PY'
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX)
sock.connect(sys.argv[1])
sock.settimeout(5)
time.sleep(0.3)
try:
    sock.recv(65536)
except Exception:
    pass
sock.sendall((sys.argv[2] + "\n").encode())
time.sleep(0.5)
PY
}

# --- stages ----------------------------------------------------------------

stage_esd() {
    stage_is_fresh esd && return 0
    "$MQG_REPO_ROOT/media/fetch-installesd.sh"
    stage_record esd
}

stage_opencore() {
    stage_is_fresh opencore && return 0
    "$MQG_REPO_ROOT/boot/fetch-edk2.sh"
    "$MQG_REPO_ROOT/boot/fetch-opencorepkg.sh"
    "$MQG_REPO_ROOT/boot/fetch-kexts.sh"
    "$MQG_REPO_ROOT/boot/build-opencore.sh"
    stage_record opencore
}

stage_ovmf() {
    stage_is_fresh ovmf && return 0
    "$MQG_REPO_ROOT/boot/build-ovmf.sh"
    stage_record ovmf
}

stage_efi() {
    stage_is_fresh efi && return 0
    MQG_SMBIOS=$smbios "$MQG_REPO_ROOT/boot/build-efi-image.sh"
    stage_record efi
}

# Resolved once, before any stage runs, because the verify stage needs it
# too -- and --from install or --stage verify does not run the payload
# stage. Finding the key only where it is first used is how "no key" turns
# into a confusing SSH failure twenty minutes later.
#
# `resolve_ssh_key soft` warns instead of dying. --freshness needs the
# fingerprint to report the payload stage honestly, and it must not refuse
# to answer a question about the build on a host that has no key yet.
resolve_ssh_key() {
    local mode=${1:-strict}
    if [ -z "$ssh_key" ]; then
        for candidate in "$HOME"/.ssh/id_*.pub "$MQG_IMAGE_DIR"/keys/*.pub; do
            [ -f "$candidate" ] || continue
            ssh_key=$candidate
            break
        done
    fi
    # `soft` never generates, even with --generate-ssh-key: --freshness
    # says it touches nothing, and inventing a secret is not nothing.
    if [ -z "$ssh_key" ] && [ "$generate_key" -eq 1 ] && [ "$mode" != soft ]; then
        # Opt-in only. A pipeline that quietly invents a key produces images
        # whose access is controlled by a file nobody knows exists.
        mkdir -p "$MQG_IMAGE_DIR/keys"
        chmod 700 "$MQG_IMAGE_DIR/keys"
        # RSA, not Ed25519. The guest is OpenSSH 6.2 and Ed25519 arrived
        # in 6.5; an Ed25519 key in authorized_keys is a line 10.9's sshd
        # cannot parse, and the symptom is an unexplained "Permission
        # denied (publickey)".
        ssh-keygen -q -t rsa -b 4096 -N '' \
            -C "mavericks-qemu-guest build host" \
            -f "$MQG_IMAGE_DIR/keys/mqg_rsa" </dev/null
        ssh_key=$MQG_IMAGE_DIR/keys/mqg_rsa.pub
        log "generated $ssh_key (private half beside it; never in the repo)"
    fi
    if [ -z "$ssh_key" ]; then
        [ "$mode" = soft ] || die "no SSH public key found. Pass --ssh-key PATH," \
            "or --generate-ssh-key to create one under $MQG_IMAGE_DIR/keys." \
            "This pipeline will not put a key it invented into an image without" \
            "being asked."
        warn "no SSH public key found; reporting the payload stage as if" \
            "there were none"
        return 0
    fi
    log "authorizing $ssh_key"
}

# The guest's OpenSSH packages, once fetched. Empty when --no-openssh, and
# also on a resumed run that skips this stage -- which is why the payload
# and media stages ask for them again rather than assuming.
openssh_tag=
openssh_base_pkg=
openssh_replace_pkg=

resolve_openssh() {
    [ "$openssh" -eq 1 ] || return 0
    [ -z "$openssh_base_pkg" ] || return 0
    openssh_tag=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' \
        "$MQG_REPO_ROOT/components/openssh/version" | grep -v '^$' | head -1)
    # `while read` rather than `mapfile`, which is bash 4 -- see
    # bin/bash32-check.sh.
    local line paths=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        paths+=("$line")
    done < <("$MQG_REPO_ROOT/image/fetch-openssh.sh")
    [ "${#paths[@]}" -eq 2 ] \
        || die "image/fetch-openssh.sh did not name two packages"
    openssh_base_pkg=${paths[0]}
    openssh_replace_pkg=${paths[1]}
}

stage_openssh() {
    if [ "$openssh" -eq 0 ]; then
        log "--no-openssh: the guest keeps its stock OpenSSH 6.2"
        return 0
    fi
    resolve_openssh
    log "guest OpenSSH $openssh_tag: $(basename "$openssh_base_pkg")," \
        "$(basename "$openssh_replace_pkg")"
}

# openssh_args <--openssh-pkg|--extra-pkg> -- one flag per package, or
# nothing at all when the image is a stock one.
openssh_args() {
    [ "$openssh" -eq 1 ] || return 0
    resolve_openssh
    printf '%s\n' "$1" "$openssh_base_pkg" "$1" "$openssh_replace_pkg"
}

stage_payload() {
    local arg
    local -a extra=()
    # Until stages recorded their inputs this one had no "already done"
    # check at all and rebuilt on every run -- which bin/triangulate.sh
    # had to know about and say so in a comment. It costs a second, so the
    # rebuild was never the problem; the missing answer to "why" was.
    stage_is_fresh payload && return 0
    # Called here, in this shell, and not left to openssh_args below.
    # openssh_args runs inside `< <(...)`, which is a subshell, so every
    # variable resolve_openssh sets there -- openssh_tag included -- is
    # discarded when it exits. In a full run that went unnoticed because
    # stage_openssh had already resolved them in this shell; `--stage
    # payload` on its own died with "--openssh-pkg needs --openssh-tag"
    # about a tag that had been fetched twice and thrown away both times.
    # Found by bin/triangulate.sh, which runs one stage per process.
    resolve_openssh
    while IFS= read -r arg; do
        [ -n "$arg" ] || continue
        extra+=("$arg")
    done < <(openssh_args --openssh-pkg)
    [ "$openssh" -eq 0 ] || extra+=(--openssh-tag "$openssh_tag")
    "$MQG_REPO_ROOT/image/payload/build-firstboot-pkg.sh" \
        --ssh-key "$ssh_key" --out "$payload_pkg" \
        ${extra[@]+"${extra[@]}"} >/dev/null
    stage_record payload
}

stage_media() {
    stage_is_fresh media && return 0
    local arg
    local -a extra=()
    # Same reason as stage_payload: openssh_args resolves inside a
    # subshell, so this stage cannot rely on it having happened.
    resolve_openssh
    while IFS= read -r arg; do
        [ -n "$arg" ] || continue
        extra+=("$arg")
    done < <(openssh_args --extra-pkg)
    "$MQG_REPO_ROOT/media/build-installer-img.sh" --force --autoinstall \
        --firstboot-pkg "$payload_pkg" ${extra[@]+"${extra[@]}"} >/dev/null
    stage_record media
}

stage_target() {
    mkdir -p "$images_dir" "$work_dir"
    if have "$out_qcow2"; then
        log "target disk is already here ($(qemu-img info "$out_qcow2" \
            | awk '/virtual size/ {print $3, $4}'))"
    else
        rm -f "$out_qcow2" "$installed_stamp"
        qemu-img create -f qcow2 "$out_qcow2" "${disk_gb}G" >/dev/null \
            || die "cannot create $out_qcow2"
        log "created $out_qcow2 (${disk_gb} GB, empty)"
    fi
    # This VM's own EFI variable store, copied from the build's template.
    # Copy, never share: two VMs writing one variable store trample each
    # other's boot order, and writing to the template invalidates the
    # checksum of a build artifact.
    if ! have "$vars_fd"; then
        cp "$firmware_dir/OVMF_VARS.fd" "$vars_fd" \
            || die "cannot copy the EFI variable template to $vars_fd"
        log "created $vars_fd from the firmware build's template"
    fi
}

# The running VM, if there is one. Set by boot_vm, cleared by power_down_vm.
vm_pid=

# Boot the guest and wait for it to answer SSH. Used both by the install
# stage (with the media attached) and by the verify stage on a resumed run,
# where the install already happened and the VM is not running.
boot_vm() {
    local with_media=$1 elapsed=0 shot deadline=$2
    mkdir -p "$work_dir"
    rm -f "$monitor"

    log "booting: $qemu_bin, accel $accel, $ram MB, $smp vCPU"
    # `while read` rather than `mapfile`, which is bash 4 -- see
    # bin/bash32-check.sh.
    qargs=()
    while IFS= read -r qarg; do
        [ -n "$qarg" ] || continue
        qargs+=("$qarg")
    done < <(qemu_args "$with_media")
    run_log "build-image($name): $(printf '%q ' "$qemu_bin" "${qargs[@]}")"
    "$qemu_bin" "${qargs[@]}" > "$qemu_log" 2>&1 &
    vm_pid=$!
    # Whatever happens below -- a timeout, a failed test, a Ctrl-C -- the VM
    # must not be left running. A stray QEMU holding a qcow2 open is how the
    # next run gets a corrupted image and an inexplicable failure.
    if [ "$keep_running" -eq 0 ]; then
        trap 'kill '"$vm_pid"' 2>/dev/null || true' EXIT INT TERM
    fi

    log "waiting for the guest to answer SSH on localhost:$ssh_port"
    while [ "$elapsed" -lt "$deadline" ]; do
        if ! kill -0 "$vm_pid" 2>/dev/null; then
            tail -20 "$qemu_log" >&2
            die "QEMU exited after ${elapsed}s -- see $qemu_log"
        fi
        if ssh_ready; then
            log "SSH answered after ${elapsed}s"
            printf '%s\n' "$elapsed" > "$work_dir/ssh-seconds"
            return 0
        fi
        sleep 20
        elapsed=$((elapsed + 20))
        # Every two minutes, say what is on screen. vm/screenshot.sh's
        # verdict is the honest one: a colour count of 2 is white-on-black
        # TEXT, not a blank screen, and reading that wrong cost an hour
        # earlier in this project.
        if [ $((elapsed % 120)) -eq 0 ]; then
            # `sed -n 1p`, not `head -1`, and `|| true` besides. head closes
            # the pipe after the first line, screenshot.sh takes SIGPIPE,
            # `set -o pipefail` reports 141, and a failing command
            # substitution in an assignment is fatal under `set -e`. That
            # killed a 20-minute install at the two-minute mark, and killed
            # QEMU with it via the cleanup trap. Progress reporting must not
            # be able to end the thing it is reporting on.
            shot=$(MQG_MONITOR="$monitor" "$MQG_REPO_ROOT/vm/screenshot.sh" \
                "$name-t$elapsed" 2>&1 | sed -n 1p) || shot="(no screenshot)"
            log "  ${elapsed}s: $shot"
        fi
    done

    MQG_MONITOR="$monitor" "$MQG_REPO_ROOT/vm/screenshot.sh" \
        "$name-timeout" >/dev/null 2>&1 || true
    die "no SSH after ${deadline}s. The VM is still running as pid" \
        "$vm_pid; look at $work_dir and at the screenshots before killing it."
}

# Stop the guest.
#
# THERE IS NO CLEAN WAY TO DO THIS FROM OUTSIDE, AND THAT IS A FINDING.
#
# QEMU's ACPI power button does nothing at all at 10.9's login window --
# tested, with a screenshot either side: no dialog, no shutdown, sixty
# seconds later the same login window. With a session logged in it raises a
# modal "Are you sure you want to shut down?" and waits for a mouse nobody
# is driving. And `shutdown` needs root, which the guest account does not
# have without a password this pipeline deliberately does not set.
#
# So: `sync` in the guest, ask nicely, and then terminate QEMU. That is a
# power cut, and it is survivable by construction: the volume is journalled
# HFS+ (docs/install-log.md step 8), QEMU flushes and closes the qcow2 on
# SIGTERM, and macOS replays the journal on the next mount. The
# `image/compare-images.sh` runs boot these images again afterwards, every
# time, which is a standing check that this is true.
power_down_vm() {
    local elapsed=0
    [ -n "$vm_pid" ] || return 0
    log "stopping the guest"
    ssh_guest "sync" >/dev/null 2>&1 || true
    qemu_monitor system_powerdown || true
    while kill -0 "$vm_pid" 2>/dev/null && [ "$elapsed" -lt 60 ]; do
        sleep 5
        elapsed=$((elapsed + 5))
    done
    if kill -0 "$vm_pid" 2>/dev/null; then
        log "  ACPI did nothing in ${elapsed}s (expected on 10.9); syncing" \
            "and terminating QEMU"
        ssh_guest "sync" >/dev/null 2>&1 || true
        kill "$vm_pid" 2>/dev/null || true
    fi
    wait "$vm_pid" 2>/dev/null || true
    vm_pid=
    trap - EXIT INT TERM
    log "guest is off; $out_qcow2 is $(stat -c %s "$out_qcow2") bytes"
}

# Boot the media, let Apple's installer install, let the payload's
# LaunchDaemon run, and wait for SSH. The whole point of P4 is that nothing
# in this function needs a human.
#
# The guest is LEFT RUNNING. The verify stage needs it, and booting it twice
# costs a minute for nothing. Whoever finishes with it calls power_down_vm.
stage_install() {
    if stage_is_fresh install; then
        log "already installed on $(cat "$installed_stamp")"
        return 0
    fi
    log "  (install is ~15 min; first boot and the payload add a few more)"
    boot_vm with-media "$install_timeout"
    wait_for_firstboot
    date -u +%Y-%m-%dT%H:%M:%SZ > "$installed_stamp"
    stage_record install
}

# SSH ANSWERING IS NOT THE SAME AS THE FIRST BOOT BEING FINISHED.
#
# firstboot.sh turns Remote Login on part-way through. After that come the
# sleep settings, the hostname, auto-login, and only then the .done marker
# and the removal of its own LaunchDaemon. So there has always been a
# window in which the guest is reachable and not yet finished.
#
# The window used to be accidentally wide enough not to matter: Apple's
# /usr/libexec/sshd-keygen-wrapper generates three host keys on the FIRST
# connection, which takes several seconds, and firstboot always won the
# race. Once the guest started installing the family's OpenSSH -- whose
# wrapper we write, and whose host keys firstboot generates up front --
# the first connection became instant and the window closed to about one
# second. The verify stage promptly reported "the first-boot LaunchDaemon
# did not remove itself" about an image where it removed itself a second
# later. A race that was being won by an accident is a race, and finding
# it this way is the whole argument for running the pipeline rather than
# reasoning about it.
#
# Bounded and non-fatal. An image whose payload never finishes is a real
# failure, but it is one for the verify stage to report with the log in
# hand, not one to hang the build on.
wait_for_firstboot() {
    local waited=0 limit=${MQG_FIRSTBOOT_WAIT:-300}
    while [ "$waited" -lt "$limit" ]; do
        if ssh_guest test -e /private/var/db/.mqg-firstboot/.done \
            >/dev/null 2>&1; then
            log "the first-boot payload finished after ${waited}s"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    warn "the first-boot payload has not finished after ${limit}s;" \
        "carrying on, so the verify stage can say what state it is in"
    return 0
}

# A DEFAULT IMAGE NEEDS NO LEGACY SSH OPTIONS, AND A STOCK ONE STILL DOES.
#
# Until the guest carried its own OpenSSH, every connection here had to
# re-enable algorithms a 2026 client retired: 10.9's sshd offers ssh-rsa
# and ssh-dss host keys and a modern client refuses both outright --
#
#   Unable to negotiate with 127.0.0.1 port 2222: no matching host key type
#   found. Their offer: ssh-rsa,ssh-dss
#
# -- and it would only offer its own RSA key with an rsa-sha2 signature
# that OpenSSH 6.2 cannot verify. The guest's OpenSSH removes both, so the
# default path connects with nothing special, which is the point: the
# workaround is not kept beside its fix.
#
# --no-openssh is the one shape that still needs it, because that image
# really is running OpenSSH 6.2. PubkeyAcceptedAlgorithms was called
# PubkeyAcceptedKeyTypes before OpenSSH 8.5 and an unknown -o is fatal, so
# ask this ssh which one it has -- `ssh -G` parses the config and connects
# to nothing.
ssh_opts() {
    printf '%s\n' \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=10
    if [ "$openssh" -eq 0 ]; then
        printf '%s\n' -o HostKeyAlgorithms=+ssh-rsa,ssh-dss
        if ssh -o PubkeyAcceptedAlgorithms=+ssh-rsa -G localhost \
               >/dev/null 2>&1; then
            printf '%s\n' -o PubkeyAcceptedAlgorithms=+ssh-rsa
        elif ssh -o PubkeyAcceptedKeyTypes=+ssh-rsa -G localhost \
               >/dev/null 2>&1; then
            printf '%s\n' -o PubkeyAcceptedKeyTypes=+ssh-rsa
        fi
    fi
    printf '%s\n' -p "$ssh_port"
}

ssh_guest() {
    local key=${ssh_key%.pub} opt
    local -a idopt=() opts=()
    [ -f "$key" ] && idopt=(-i "$key" -o IdentitiesOnly=yes)
    # `while read` rather than `mapfile`, which is bash 4 -- see
    # bin/bash32-check.sh.
    while IFS= read -r opt; do
        [ -n "$opt" ] || continue
        opts+=("$opt")
    done < <(ssh_opts)
    # The command is sent to the guest as written: it expands there, not
    # here, which is what we want -- these are commands about the guest.
    # shellcheck disable=SC2029
    # `${idopt[@]+...}`: idopt is empty when there is no key file, and
    # before bash 4.4 expanding an empty array under `set -u` is an
    # "unbound variable" error. See bin/bash32-check.sh.
    ssh "${opts[@]}" ${idopt[@]+"${idopt[@]}"} "$ssh_user@localhost" "$@"
}

ssh_ready() { ssh_guest true >/dev/null 2>&1; }

# Ask the guest what it is. Boots it first if it is not already up, which is
# what happens on a resumed run: --from verify, or a second invocation after
# the install stage was skipped.
#
# The installer media is NOT attached here. An image that only boots with
# the media next to it is not the deliverable.
stage_verify() {
    local out
    if [ -z "$vm_pid" ]; then
        log "the guest is not running; booting it without the installer media"
        boot_vm without-media 600
    fi
    # Single-quoted: this expands in the GUEST, which is the point.
    #
    # diskbus is here for ledger entry G16, which claims `-device ide-hd`
    # on q35 presents as SATA/AHCI rather than legacy IDE. That was read off
    # Disk Utility by hand once; asking the guest every build makes it a
    # measurement, and gives bin/triangulate.sh something to report from
    # another host.
    #
    # THE CPU LINES ARE THE SAME KIND OF THING, AND THEY ARE NEW.
    #
    # --cpu names a QEMU model; machdep.cpu.* is what the GUEST decided it
    # got. Those are two different facts and only the second one settles
    # "does 10.9 need SSE4.1" (docs/decisions/0009, lib/cpu.sh). A boot
    # that reaches SSH is not by itself evidence about a feature set --
    # the image has to say which features it saw. brand_string also
    # catches a model that QEMU accepted and then quietly did not provide.
    #
    # sha256-64MiB is the "and it computed something correct" half. 64 MiB
    # of zeros has exactly one right answer --
    # 3b6a07d0d404fab4e23b6d34bc6696a6a312dd92821332385e5af7c01c421351 --
    # OpenSSL's sha256 takes the SSSE3 path on this
    # vintage, and a CPU model that boots but miscomputes would otherwise
    # look identical to one that works. It costs about a second.
    # shellcheck disable=SC2016
    out=$(ssh_guest '
        sw_vers
        echo "hostname=$(hostname)"
        echo "id=$(id)"
        echo "hw=$(sysctl -n hw.model) $(sysctl -n hw.ncpu)cpu $(sysctl -n hw.memsize)"
        echo "cpubrand=$(sysctl -n machdep.cpu.brand_string)"
        echo "cpufeatures=$(sysctl -n machdep.cpu.features)"
        echo "cpuextfeatures=$(sysctl -n machdep.cpu.extfeatures)"
        echo "cpuleaf7=$(sysctl -n machdep.cpu.leaf7_features 2>/dev/null)"
        echo "sha256-64MiB=$(dd if=/dev/zero bs=1m count=64 2>/dev/null | openssl dgst -sha256)"
        echo "sshd=$(launchctl list | grep -c com.openssh.sshd) job(s)"
        echo "ssh=$(ssh -V 2>&1)"
        echo "hostkeys=$(ls /usr/local/etc/ssh_host_*_key /etc/ssh_host_*_key 2>/dev/null | xargs -n1 basename | xargs echo)"
        echo "setupdone=$([ -e /var/db/.AppleSetupDone ] && echo yes || echo no)"
        echo "firstboot-daemon=$([ -e /Library/LaunchDaemons/com.mqg.firstboot.plist ] && echo STILL-THERE || echo removed)"
        echo "firstboot-ran=$(cat /private/var/db/.mqg-firstboot/.done 2>&1)"
        echo "autologin=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>&1)"
        echo "diskbus=$(diskutil info disk0 2>/dev/null | grep -i Protocol | sed -e "s/.*: *//")"
    ') || die "SSH connected but the guest would not answer"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    printf '%s\n' "$out" > "$work_dir/verify.txt"
    case $out in
        *STILL-THERE*)
            warn "the first-boot LaunchDaemon did not remove itself." \
                 "It will run again on every boot. See NOTES.md." ;;
    esac
    power_down_vm
}

stage_manifest() {
    local commit dirty
    commit=$(git -C "$MQG_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
    if git -C "$MQG_REPO_ROOT" diff --quiet 2>/dev/null &&
       git -C "$MQG_REPO_ROOT" diff --cached --quiet 2>/dev/null; then
        dirty=clean
    else
        dirty=DIRTY
    fi
    mkdir -p "$images_dir"
    {
        printf '# mavericks-qemu-guest image manifest\n'
        printf '#\n'
        printf '# Every input that affects what this image contains. Two builds\n'
        printf '# from identical inputs are NOT byte-identical -- installs write\n'
        printf '# timestamps, UUIDs and seeds -- and that is not the claim. See\n'
        printf '# docs/decisions/0006-image-pipeline-reproducibility.md for what\n'
        printf '# the claim is and how it is checked.\n'
        printf 'name\t%s\n' "$name"
        printf 'commit\t%s (%s)\n' "$commit" "$dirty"
        printf 'built\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'esd\t%s\n' "$(sha256_file "$esd_dmg")"
        printf 'media\t%s\n' "$(sha256_file "$media_img")"
        # What is ON the media, as distinct from the bytes of the file that
        # holds it. Two builds from one ESD never produce the same file --
        # mkfs.hfsplus stamps the clock into the volume header and mounting
        # rewrites it -- but they must produce the same contents, and this
        # is the number that says whether they did. About a minute.
        printf 'mediacontent\t%s\n' \
            "$("$MQG_REPO_ROOT/media/content-digest.sh" "$media_img" 2>/dev/null)"
        # The checksum the EFI image had WHEN IT WAS BUILT, not now. Until
        # snapshot=on was added above, "now" meant "after the last VM ran",
        # which is not an input to anything. boot/build-efi-image.sh writes
        # the .sha256 beside it; prefer that, and fall back to the file for
        # an image built before this existed.
        if [ -s "$efi_img.sha256" ]; then
            printf 'opencore\t%s\n' "$(cut -d' ' -f1 < "$efi_img.sha256")"
        else
            printf 'opencore\t%s\n' "$(sha256_file "$efi_img")"
        fi
        printf 'ovmf\t%s\n' "$(sha256_file "$firmware_dir/OVMF_CODE.fd")"
        printf 'config\t%s\n' "$(sha256_file "$config_plist")"
        printf 'payload\t%s\n' "$(sha256_file "$payload_pkg")"
        if [ -n "$ssh_key" ] && [ -f "$ssh_key" ]; then
            printf 'sshkey\t%s\n' "$(ssh-keygen -lf "$ssh_key" | awk '{print $2, $4}')"
        fi
        printf 'openssh\t%s\n' \
            "$([ "$openssh" -eq 1 ] && echo "${openssh_tag:-$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$MQG_REPO_ROOT/components/openssh/version" | grep -v '^$' | head -1)}" || echo none)"
        printf 'updates\t%s\n' "$updates"
        printf 'nic\t%s\n' "$nic"
        printf 'accel\t%s machine=%s cpu=%s ram=%s smp=%s disk=%sG\n' \
            "$accel" "$machine" "$cpu" "$ram" "$smp" "$disk_gb"
        # The line above says WHICH -cpu line; this one says what the
        # project knew about that line when the image was made. Same
        # relationship as `compiler` and `compilerrange`, and for the same
        # reason: the table in lib/cpu.sh moves as measurements arrive and
        # the image does not, so an image built on an untested model has to
        # carry its own "this was untested" or it silently becomes a
        # supported build the day somebody else tests that model.
        printf 'cpuline\t%s\n' "$(cpu_line_manifest "$cpu")"
        # WHICH SMBIOS the guest was told it was, and whether the project
        # had evidence for it at the time. Beside the -cpu line because it
        # is the same kind of claim: an image built on an untested model
        # must still say so in a year, when the table has moved and the
        # image has not.
        printf 'smbios\t%s -- %s\n' "$smbios" "$(smbios_manifest "$smbios")"
        printf 'qemu\t%s\n' "$("$qemu_bin" --version | head -1)"
        # THE ONE INPUT THAT IS RECORDED BUT NOT PINNED.
        #
        # Every source above is pinned by commit and checksum. The compiler
        # that turned them into the OpenCore and OVMF binaries is not, and
        # it is not neutral: OpenCorePkg 1.0.7 does not compile at all under
        # a C23-default gcc, and OvmfPkg compiles but comes out with
        # different bytes. boot/build-opencore.sh now states the dialect it
        # wants; the compiler itself is still whatever the host has.
        #
        # So this line is not a pin, it is an admission -- and it is here so
        # that two manifests that differ can say whether the compiler was
        # one of the reasons. See docs/decisions/0004, "The compiler is not
        # pinned", and docs/host-profile.md G22.
        printf 'compiler\t%s\n' \
            "$("$MQG_REPO_ROOT/boot/build-opencore.sh" --compiler 2>/dev/null || echo unknown)"
        # ... AND WHAT WE THOUGHT OF IT AT THE TIME.
        #
        # The line above says which compiler; this one says whether the
        # project claimed to support it when this image was made. They are
        # not the same fact and the second one cannot be reconstructed
        # later: the range moves as evidence arrives (lib/compiler.sh), the
        # image does not, so an image built above the ceiling has to carry
        # its own "this was untested territory" or it silently becomes a
        # supported build the day the ceiling is raised. It also records an
        # MQG_COMPILER override, which is the one way a below-floor
        # compiler can get this far.
        printf 'compilerrange\t%s\n' \
            "$("$MQG_REPO_ROOT/boot/build-opencore.sh" --compiler-range 2>/dev/null || echo unknown)"
        # ... AND WHETHER A CACHE STOOD BETWEEN THEM.
        #
        # ccache is a build-time tool whose whole claim is that it does not
        # change the output. It is recorded anyway, and for the same reason
        # `compiler` is recorded although it is not pinned: the claim is not
        # verified on every host, and an unverified claim that leaves no
        # trace is an unverifiable one. If a ccache build ever does produce
        # different bytes, these lines are what say which images were built
        # that way. Off by default -- see lib/ccache.sh.
        printf 'ccache\t%s\n' \
            "$("$MQG_REPO_ROOT/boot/build-opencore.sh" --ccache 2>/dev/null || echo unknown)"
        printf 'image\t%s %s bytes\n' \
            "$(sha256_file "$out_qcow2")" "$(stat -c %s "$out_qcow2")"
        # EVERY PIN, ONE LINE EACH, AND A DIGEST OVER THE LOT.
        #
        # We ship a recipe, not an artifact, so an ingredient bump cannot
        # obsolete anything published -- it silently invalidates the golden
        # images already on disk instead. These lines are what makes that
        # visible: bin/image-staleness.sh compares them against the
        # checkout, and image/compare-images.sh's manifest diff names the
        # ingredient that differs between two images for free. See
        # INGREDIENTS.md.
        printf 'ingredients\t%s\n' \
            "$("$MQG_REPO_ROOT/bin/ingredient-fingerprint.sh")"
        "$MQG_REPO_ROOT/bin/ingredient-fingerprint.sh" --list \
            | sed 's/^/ingredient./' 
    } > "$manifest"
    log "wrote $manifest"
    sed 's/^/    /' "$manifest" >&2
}

# --- run -------------------------------------------------------------------

# WOULD THE NEXT BUILD REBUILD ANYTHING, AND WHY?
#
# Asked in a second instead of in fourteen minutes. This is also how the
# freshness rules are tested: every branch of stage_freshness is reachable
# from here without building anything (tests/image.bats).
if [ "$freshness" -eq 1 ]; then
    resolve_ssh_key soft
    for s in $(stage_names); do
        out=$(stage_output_file "$s")
        if [ -z "$out" ]; then
            printf '%s\t-\tno recorded inputs (it runs whenever it is reached)\n' "$s"
            continue
        fi
        printf '%s\t%s\n' "$s" "$(stage_freshness "$s")"
    done
    exit 0
fi

require_cmd qemu-img ssh ssh-keygen python3 sha256sum
command -v "$qemu_bin" >/dev/null 2>&1 || die "no such QEMU: $qemu_bin"

# EDK II refuses to build when the path to a debug symbol exceeds 255
# bytes, and it says so about 10 minutes into compiling:
#
#   ERROR: Debug symbol path exceeds maximum allowed range of 255 bytes!
#
# The deepest module path under $MQG_BUILD_DIR is about 125 characters
# (MdeModulePkg/Bus/Isa/Ps2MouseDxe/...), so the build directory itself has
# to be comfortably shorter than that. Found the first time this pipeline
# was run from a fresh clone with $MQG_IMAGE_DIR under a long scratch path.
# Checked here, in a millisecond, rather than there.
MAX_BUILD_DIR=120
if [ "${#MQG_BUILD_DIR}" -gt "$MAX_BUILD_DIR" ]; then
    die "MQG_BUILD_DIR is ${#MQG_BUILD_DIR} characters, and EDK II cannot" \
        "build under a path longer than about $MAX_BUILD_DIR (it enforces a" \
        "255-byte limit on debug symbol paths, and its own module paths use" \
        "the rest). Point MQG_IMAGE_DIR or MQG_BUILD_DIR somewhere shorter:" \
        "$MQG_BUILD_DIR"
fi

resolve_ssh_key
# Warns, never refuses -- see lib/cpu.sh for why this one is not a gate.
cpu_line_check "$cpu"
# Warns, never refuses -- see lib/smbios.sh. The refusal for this parameter
# already happened, above, and it was about the string and not the model.
smbios_check "$smbios"
log "building $name (accel $accel, machine $machine, cpu $cpu, smbios $smbios, ${ram}MB)"
mkdir -p "$images_dir" "$work_dir" "$(dirname "$payload_pkg")"

run_stage esd stage_esd
run_stage opencore stage_opencore
run_stage ovmf stage_ovmf
run_stage efi stage_efi
run_stage openssh stage_openssh
run_stage payload stage_payload
run_stage media stage_media
run_stage target stage_target
run_stage install stage_install
run_stage verify stage_verify
# The manifest checksums the qcow2, so the guest must be off first --
# otherwise the recorded checksum is of a file still being written. If
# --stage install ran alone, this is what stops the VM.
power_down_vm
run_stage manifest stage_manifest

log "total $((SECONDS - started_at))s"
printf '%s' "$stage_times" | sed 's/^/    /' >&2
run_log "build-image: $name in $((SECONDS - started_at))s"
printf '%s\n' "$out_qcow2"
