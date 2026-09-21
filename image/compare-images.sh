#!/usr/bin/env bash
# Compare two images built by image/build-image.sh, and say precisely in
# what sense they are the same.
#
# THE CLAIM THIS TESTS
#
# Not that the two qcow2 files are byte-identical. They are not, and they
# cannot be: an OS X install writes timestamps, volume UUIDs, machine UUIDs,
# random seeds and caches, and a 60 GB sparse file records the order the
# installer happened to allocate blocks in. Comparing bytes would fail every
# time while telling you nothing.
#
# The claim is: the same inputs produce an image that BEHAVES the same. That
# is four things, and this script checks each of them separately so a
# failure names which one:
#
#   1. Both manifests list identical inputs (excluding the build's own name,
#      its clock, and the checksum of the output).
#   2. Both boot unattended and answer SSH with the key they were built for.
#   3. sw_vers, the account, and the machine's own idea of itself match.
#   4. The installed file sets match -- same paths, same sizes -- once the
#      things an install is *expected* to vary are excluded, and those
#      exclusions are listed below rather than hidden in a pipeline.
#
# An unstated comparison method is not reproducible either, which is why
# this is a script and not a paragraph in NOTES.md.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# Read at call time by log()/warn()/die() in lib/common.sh.
# shellcheck disable=SC2034
MQG_LOG_PREFIX=compare-images

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MQG_BUILD_DIR=${MQG_BUILD_DIR:-$MQG_IMAGE_DIR/build}
images_dir=$MQG_IMAGE_DIR/images
work_root=$MQG_IMAGE_DIR/work/compare

# What an install is allowed to vary. Each of these is a place the system
# writes on its own after (or during) installation, so a difference there is
# not evidence of a different image.
#
#   /private/var    logs, caches, receipts, dyld's shared cache, the ASL
#                   store, and the machine UUID
#   /Users          created at first boot, with a home directory copied
#                   from a template
#   /System/Library/Caches
#   /Library/Caches
#   /.Spotlight-V100, /.fseventsd
#                   indexes built after install, whose contents depend on
#                   when the indexer happened to run
#   /dev, /net, /home
#                   not files on the volume at all
#
# The four below were added after the first real comparison, which found
# exactly seven differing files out of 321,130 and nothing else. Each one is
# an identity the machine mints for itself, and listing them here is the
# difference between "reproducible" and "reproducible, and here is what
# varies":
#
#   /Library/Application Support/CrashReporter/
#                   AnonymousIdentifier_<UUID>.plist, a fresh UUID per
#                   machine, in the filename itself
#   /Library/Keychains/
#                   System.keychain and apsd.keychain carry the machine's
#                   own keys; they differed by 8 bytes
#   /Library/Preferences/SystemConfiguration/
#                   written at runtime by configd and pmset
#   /private/etc/ssh_host_
#                   host keys, generated the first time sshd starts. An
#                   image that shipped identical ones would be the defect.
#   /.mqg-logs/, /.mqg-autoinstall.log
#                   our own capture of the installer's logs, put there by
#                   image/autoinstall/autoinstall.sh so a failed unattended
#                   install can be read from the host
EXCLUDE_PREFIXES="\
/private/var/
/private/tmp/
/Users/
/System/Library/Caches/
/Library/Caches/
/Library/Logs/
/Library/Application Support/CrashReporter/
/Library/Keychains/
/Library/Preferences/SystemConfiguration/
/private/etc/ssh_host_
/.Spotlight-V100
/.fseventsd
/dev/
/net/
/home/
/.mqg-firstboot.log
/.mqg-autoinstall.log
/.mqg-logs/
/var/"

# Manifest fields that are expected to differ between two builds of the same
# inputs. Everything else must match exactly.
#
#   name, built, image   the build's own identity, its clock, and the
#                        checksum of its output. Differ by construction.
#   media                the checksum of the installer media FILE, which is
#                        not byte-reproducible and never will be:
#                        mkfs.hfsplus stamps the volume creation date from
#                        the clock, mounting an HFS+ volume rewrites its
#                        header, and catalog layout follows write order.
#                        What must match is the media's CONTENT, which
#                        media/content-digest.sh reports as one checksum
#                        over a sorted list of every file's own checksum.
#                        `mediacontent` below is that number, and it is NOT
#                        in this list: it has to match.
MANIFEST_VARIES="name built image media"

# The one line of the guest's self-description that is a clock reading: when
# the first-boot payload ran. Everything else in identity.txt must match.
IDENTITY_VARIES="firstbootmarker"

accel=kvm
machine=q35
cpu='Penryn,+ssse3,+sse4.1,+sse4.2'
ram=4096
smp=2
qemu_bin=${MQG_QEMU:-qemu-system-x86_64}
ssh_user=mavsuser
ssh_key=
base_port=2251
boot_timeout=${MQG_COMPARE_BOOT_TIMEOUT:-600}
collect_only=
reuse=0
describe=0

usage() {
    cat <<EOF
usage: $(basename "$0") [options] <image-a> <image-b>

Image names, not paths: both are looked for in $images_dir.

  --ssh-key PATH   Private or public key to authenticate with
                   (default: the first of ~/.ssh/id_*.pub or
                   \$MQG_IMAGE_DIR/keys/*.pub)
  --ssh-user NAME  (default: $ssh_user)
  --accel kvm|tcg  (default: $accel)
  --collect NAME   Only boot NAME and collect its fingerprint, then stop.
  --reuse          Compare fingerprints already collected, without booting
                   anything. For re-reading a comparison, not for making
                   one: it proves nothing about booting.
  --describe       Print the comparison method and exit.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --ssh-key) ssh_key=$2; shift ;;
        --ssh-user) ssh_user=$2; shift ;;
        --accel) accel=$2; shift ;;
        --collect) collect_only=$2; shift ;;
        --reuse) reuse=1 ;;
        --describe) describe=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) break ;;
    esac
    shift
done

if [ "$describe" -eq 1 ]; then
    cat <<EOF
comparison method

  Two images built from identical inputs are NOT byte-identical. An install
  writes timestamps, UUIDs and seeds, and a sparse qcow2 records allocation
  order. That is expected and is not the claim.

  What is compared instead, in this order, each reported separately:

  1. manifests      every field must match except: $MANIFEST_VARIES
                    ("media" is the checksum of the media FILE, which is
                     not byte-reproducible; "mediacontent" is a checksum of
                     what is ON it, and that one must match)
  2. boot           each image is booted headless with no installer media
                    attached, and must answer SSH within ${boot_timeout}s
                    using the key it was built for
  3. identity       sw_vers, hw.model, hw.ncpu, hw.memsize, the account's
                    uid/gid/groups, and whether Remote Login is on
  4. file sets      every regular file on the boot volume, as "<size> <path>",
                    sorted, with these prefixes excluded as things an
                    install is expected to vary:
$(printf '%s\n' "$EXCLUDE_PREFIXES" | sed 's/^/                      /')

  Collected with:
    find / -xdev -type f -exec stat -f '%z %N' {} +

  The file inventory is taken as the guest account, not as root, so a
  handful of root-only directories (/private/var/db/shadow and friends) are
  unreadable. They are all under excluded prefixes anyway; the count of
  unreadable paths is reported so that stops being an assumption.
EOF
    exit 0
fi

require_cmd ssh qemu-img python3

if [ -z "$ssh_key" ]; then
    for candidate in "$HOME"/.ssh/id_*.pub "$MQG_IMAGE_DIR"/keys/*.pub; do
        [ -f "$candidate" ] || continue
        ssh_key=$candidate
        break
    done
fi
[ -n "$ssh_key" ] || die "no SSH key found; pass --ssh-key"
priv_key=${ssh_key%.pub}
[ -f "$priv_key" ] || die "no private key at $priv_key"

# KEPT HERE, UNLIKE IN image/build-image.sh, AND FOR A REASON.
#
# Since the guest carries the family's own OpenSSH (image/fetch-openssh.sh,
# default on), build-image.sh connects with no algorithm overrides at all:
# the workaround was deleted along with the defect. This script cannot do
# that. It compares two images it did not build, either of which may have
# been built --no-openssh and really be running OpenSSH 6.2 -- and it has
# no argument that says which. The options below are additive (+), so a
# modern sshd is unaffected by them; a stock 10.9 one is unreachable
# without them.
#
# If this ever grows a "which image is this" question, read the manifest's
# `openssh` field rather than guessing.
ssh_legacy_opts=(-o 'HostKeyAlgorithms=+ssh-rsa,ssh-dss')
if ssh -o PubkeyAcceptedAlgorithms=+ssh-rsa -G localhost >/dev/null 2>&1; then
    ssh_legacy_opts+=(-o PubkeyAcceptedAlgorithms=+ssh-rsa)
elif ssh -o PubkeyAcceptedKeyTypes=+ssh-rsa -G localhost >/dev/null 2>&1; then
    ssh_legacy_opts+=(-o PubkeyAcceptedKeyTypes=+ssh-rsa)
fi

ssh_guest() {
    local port=$1
    shift
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=10 -o IdentitiesOnly=yes \
        "${ssh_legacy_opts[@]}" \
        -i "$priv_key" -p "$port" "$ssh_user@localhost" "$@"
}

# WHICH NIC THIS IMAGE NEEDS, ASKED RATHER THAN ASSUMED.
#
# This script used to hardcode usb-net, which was right while every image
# had one. It is not a runtime knob: 10.9 creates network services for the
# interfaces it saw during installation, so an image booted with a NIC it
# has never met comes up with no network and never answers SSH -- which
# this script would report as "never booted". Measured 2026-09-21, see
# docs/decisions/0008 and docs/open-questions.md Q2.
#
# The manifest says which, and this is the "which image is this" question
# the comment above anticipated. Images built before the field existed were
# all built with usb-net, so that is what a missing field means -- not a
# guess, a fact about when the field was added.
nic_device_for() {
    local manifest=$1 nic
    # No pipe and no `head`: a closed pipe under `set -o pipefail` is how
    # this project has killed a long-running boot before now.
    nic=$(awk -F'\t' '$1 == "nic" { print $2; exit }' "$manifest" 2>/dev/null)
    case ${nic:-usb-net} in
        usb-net) printf '%s\n' "usb-net,bus=usb.0,netdev=net0" ;;
        *)       printf '%s\n' "${nic},netdev=net0" ;;
    esac
}

# Boot one image on its own -- no installer media, nothing else attached --
# collect everything this comparison needs, and shut it down.
#
# Booting rather than reading the qcow2 offline is deliberate. "Both boot
# unattended" and "both answer SSH" are two of the four things being
# claimed, and an offline file listing cannot test either.
collect() {
    local name=$1 port=$2 out qcow2 vars pid elapsed=0 nic
    qcow2=$images_dir/$name.qcow2
    [ -f "$qcow2" ] || die "no image at $qcow2"
    out=$work_root/$name
    mkdir -p "$out"
    if [ "$reuse" -eq 1 ] && [ -s "$out/inventory.txt" ] \
       && [ -s "$out/identity.txt" ]; then
        log "$name: reusing the fingerprint already in $out (--reuse)"
        return 0
    fi
    # A stale marker from an earlier run would let a failed boot pass the
    # check below, which is exactly the kind of green that means nothing.
    rm -f "$out/boot-seconds"
    vars=$out/OVMF_VARS.fd
    [ -f "$vars" ] || cp "$MQG_BUILD_DIR/firmware/OVMF_VARS.fd" "$vars"

    nic=$(nic_device_for "$images_dir/$name.manifest")
    log "booting $name on port $port with -device $nic"
    "$qemu_bin" \
        -accel "$accel" -machine "$machine,vmport=off" -cpu "$cpu" \
        -m "$ram" -smp "$smp" \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$MQG_BUILD_DIR/firmware/OVMF_CODE.fd" \
        -drive "if=pflash,format=raw,unit=1,file=$vars" \
        -device "ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on" \
        -device "ich9-usb-uhci1,masterbus=usb.0,firstport=0,bus=pcie.0,addr=0x1d.0,multifunction=on" \
        -device "ich9-usb-uhci2,masterbus=usb.0,firstport=2,bus=pcie.0,addr=0x1d.1" \
        -device "ich9-usb-uhci3,masterbus=usb.0,firstport=4,bus=pcie.0,addr=0x1d.2" \
        -drive "id=opencore,if=none,format=raw,snapshot=on,file=$MQG_IMAGE_DIR/work/opencore-p3.img" \
        -device "usb-storage,bus=usb.0,drive=opencore" \
        -drive "id=target,if=none,format=qcow2,file=$qcow2" \
        -device "ide-hd,bus=ide.0,drive=target" \
        -netdev "user,id=net0,hostfwd=tcp::$port-:22" \
        -device "$nic" \
        -device "usb-kbd,bus=usb.0" -device "usb-mouse,bus=usb.0" \
        -device "VGA,vgamem_mb=64" -display none \
        -monitor "unix:$out/monitor.sock,server,nowait" \
        > "$out/qemu.log" 2>&1 &
    pid=$!
    trap 'kill '"$pid"' 2>/dev/null || true' EXIT INT TERM

    while [ "$elapsed" -lt "$boot_timeout" ]; do
        kill -0 "$pid" 2>/dev/null || die "$name: QEMU exited; see $out/qemu.log"
        if ssh_guest "$port" true >/dev/null 2>&1; then
            log "$name answered SSH after ${elapsed}s"
            printf '%s\n' "$elapsed" > "$out/boot-seconds"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    [ -s "$out/boot-seconds" ] \
        || die "$name never answered SSH in ${boot_timeout}s"

    log "$name: collecting identity"
    # Single-quoted on purpose: this is a script for the GUEST to expand,
    # not for this shell.
    # shellcheck disable=SC2016
    ssh_guest "$port" '
        sw_vers
        echo "hw.model=$(sysctl -n hw.model)"
        echo "hw.ncpu=$(sysctl -n hw.ncpu)"
        echo "hw.memsize=$(sysctl -n hw.memsize)"
        echo "id=$(id)"
        echo "groups=$(id -Gn)"
        echo "remotelogin=$(systemsetup -getremotelogin 2>&1)"
        echo "sleep=$(systemsetup -getsleep 2>&1 | tr "\n" ";")"
        echo "autologin=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>&1)"
        echo "setupdone=$([ -e /var/db/.AppleSetupDone ] && echo yes || echo no)"
        echo "firstbootdaemon=$([ -e /Library/LaunchDaemons/com.mqg.firstboot.plist ] && echo PRESENT || echo removed)"
        echo "firstbootmarker=$(cat /private/var/db/.mqg-firstboot/.done 2>&1)"
    ' > "$out/identity.txt" || die "$name: could not collect identity"

    log "$name: inventorying the boot volume (this takes a minute)"
    # shellcheck disable=SC2016
    ssh_guest "$port" \
        'find / -xdev -type f -exec stat -f "%z %N" {} + 2>/tmp/mqg-unreadable; \
         echo "UNREADABLE $(wc -l < /tmp/mqg-unreadable)" >&2' \
        > "$out/inventory.raw" 2> "$out/inventory.err" \
        || die "$name: could not inventory the volume"

    # There is no clean way to stop this guest from outside: 10.9 ignores
    # QEMU's ACPI power button at the login window entirely, raises a modal
    # dialog when a session is logged in, and `shutdown` needs a root this
    # account does not have. So: sync, ask anyway, then terminate QEMU. The
    # volume is journalled HFS+ and macOS replays the journal on the next
    # mount -- which is exactly what the NEXT run of this script does, every
    # time, so the assumption is under standing test. See the same comment
    # in image/build-image.sh.
    log "$name: stopping it"
    ssh_guest "$port" 'sync' >/dev/null 2>&1 || true
    python3 - "$out/monitor.sock" <<'PY' || true
import socket
import sys
import time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
time.sleep(0.3)
try:
    s.recv(65536)
except Exception:
    pass
s.sendall(b"system_powerdown\n")
time.sleep(0.5)
PY
    elapsed=0
    while kill -0 "$pid" 2>/dev/null && [ "$elapsed" -lt 30 ]; do
        sleep 5
        elapsed=$((elapsed + 5))
    done
    if kill -0 "$pid" 2>/dev/null; then
        ssh_guest "$port" 'sync' >/dev/null 2>&1 || true
        kill "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    trap - EXIT INT TERM
    log "$name: collected into $out"
}

if [ -n "$collect_only" ]; then
    collect "$collect_only" "$base_port"
    exit 0
fi

[ $# -eq 2 ] || { usage >&2; exit 2; }
a=$1
b=$2

for n in "$a" "$b"; do
    [ -f "$images_dir/$n.qcow2" ] || die "no image at $images_dir/$n.qcow2"
    [ -f "$images_dir/$n.manifest" ] || die "no manifest at $images_dir/$n.manifest"
done

failures=0
report() {
    local verdict=$1
    shift
    printf '%-6s %s\n' "$verdict" "$*"
    [ "$verdict" = "SAME" ] || failures=$((failures + 1))
}

echo "=== 1. inputs (manifests) ==="
strip_manifest() {
    local varies=" $MANIFEST_VARIES "
    grep -v '^#' "$1" | while IFS=$'\t' read -r field value; do
        case $varies in *" $field "*) continue ;; esac
        printf '%s\t%s\n' "$field" "$value"
    done
}
if diff -u <(strip_manifest "$images_dir/$a.manifest") \
           <(strip_manifest "$images_dir/$b.manifest"); then
    report SAME "every manifest field but $MANIFEST_VARIES"
else
    report DIFFER "the manifests list different inputs (above)"
fi
echo "  (the fields that are expected to differ: $MANIFEST_VARIES)"
grep -E '^(name|built|image)' "$images_dir/$a.manifest" | sed 's/^/  a: /'
grep -E '^(name|built|image)' "$images_dir/$b.manifest" | sed 's/^/  b: /'

echo
echo "=== 2. boot and SSH ==="
collect "$a" "$base_port"
collect "$b" "$((base_port + 1))"
report SAME "both booted unattended and accepted the key" 

echo
echo "=== 3. identity ==="
strip_identity() {
    local varies=" $IDENTITY_VARIES " line key
    while IFS= read -r line; do
        key=${line%%=*}
        case $varies in *" $key "*) continue ;; esac
        printf '%s\n' "$line"
    done < "$1"
}
if diff -u <(strip_identity "$work_root/$a/identity.txt") \
           <(strip_identity "$work_root/$b/identity.txt"); then
    report SAME "sw_vers, hardware, account, services"
else
    report DIFFER "the guests describe themselves differently (above)"
fi
echo "  (expected to differ, being a clock reading: $IDENTITY_VARIES)"
grep -h "^$IDENTITY_VARIES" "$work_root/$a/identity.txt" | sed 's/^/  a: /'
grep -h "^$IDENTITY_VARIES" "$work_root/$b/identity.txt" | sed 's/^/  b: /' 

echo
echo "=== 4. installed file sets ==="

# Filtering happens HERE, not at collection time. The exclusion list is the
# part of this comparison most likely to need changing -- the first real run
# found four kinds of per-machine identity nobody had thought of -- and
# re-collecting means booting two VMs for five minutes to learn nothing new.
# inventory.raw is what was observed; this is the reading of it.
filter_inventory() {
    python3 - "$1" "$2" "$EXCLUDE_PREFIXES" <<'FILTER'
import sys

excludes = tuple(p for p in sys.argv[3].split("\n") if p)
kept = []
dropped = 0
for line in open(sys.argv[1], errors="replace"):
    line = line.rstrip("\n")
    if " " not in line:
        continue
    size, path = line.split(" ", 1)
    if path.startswith(excludes):
        dropped += 1
        continue
    kept.append("%s %s" % (size, path))
kept.sort(key=lambda row: row.split(" ", 1)[1])
with open(sys.argv[2], "w") as fh:
    fh.write("\n".join(kept) + "\n")
sys.stderr.write("  %s: kept %d files, excluded %d\n"
                 % (sys.argv[2].split("/")[-2], len(kept), dropped))
FILTER
}
filter_inventory "$work_root/$a/inventory.raw" "$work_root/$a/inventory.txt"
filter_inventory "$work_root/$b/inventory.raw" "$work_root/$b/inventory.txt"
# LC_ALL=C throughout, on the sorts AND on comm itself. comm compares byte
# strings but checks its input's order using the locale's collation, so a
# C-sorted file handed to a UTF-8 comm is reported as "not in sorted order"
# -- comm then exits non-zero, and under `set -o pipefail` that killed this
# script mid-comparison. Both sides of that have to agree.
paths_of() { cut -d' ' -f2- "$1" | LC_ALL=C sort; }
only_a=$(LC_ALL=C comm -23 <(paths_of "$work_root/$a/inventory.txt") \
                           <(paths_of "$work_root/$b/inventory.txt") | wc -l)
only_b=$(LC_ALL=C comm -13 <(paths_of "$work_root/$a/inventory.txt") \
                           <(paths_of "$work_root/$b/inventory.txt") | wc -l)
# `diff` on 320,000-line files is slow when they differ a lot and `cmp` is
# instant when they do not, so ask the cheap question first.
if cmp -s "$work_root/$a/inventory.txt" "$work_root/$b/inventory.txt"; then
    size_diff=0
else
    size_diff=$(diff "$work_root/$a/inventory.txt" \
                     "$work_root/$b/inventory.txt" \
        | grep -c '^[<>]') || size_diff=0
fi
printf '  files in a only: %s\n  files in b only: %s\n' "$only_a" "$only_b"
printf '  lines differing (path or size): %s\n' "$size_diff"
printf '  a: %s files   b: %s files\n' \
    "$(wc -l < "$work_root/$a/inventory.txt")" \
    "$(wc -l < "$work_root/$b/inventory.txt")"
grep UNREADABLE "$work_root/$a/inventory.err" | sed 's/^/  a: /' || true
grep UNREADABLE "$work_root/$b/inventory.err" | sed 's/^/  b: /' || true
if [ "$only_a" -eq 0 ] && [ "$only_b" -eq 0 ] && [ "$size_diff" -eq 0 ]; then
    report SAME "identical paths and sizes outside the excluded prefixes"
else
    report DIFFER "see $work_root/*/inventory.txt"
    diff "$work_root/$a/inventory.txt" "$work_root/$b/inventory.txt" \
        | head -40 | sed 's/^/  /'
fi

echo
if [ "$failures" -eq 0 ]; then
    log "$a and $b are the same image by every check above"
    exit 0
fi
die "$failures of the four checks differ; read the output rather than rerunning"
