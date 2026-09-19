#!/usr/bin/env bash
# Diff Linux-built installer media against the Mac-produced reference.
#
# A finished rsync proves nothing. The reference -- InstallMavericks.iso,
# made by get.sh on a real Mac, and the media that actually installed the
# system this project already has -- exists so that "did Linux build
# working media?" is a question with an answer instead of an opinion.
#
# Both images are read with `7z l`, which understands HFS+ and needs
# neither root nor a mount. The reference is an ISO with an Apple partition
# map and the build is GPT, so what gets compared is the *contents of the
# volume*, never the raw layout.
#
# Three things about that comparison are not obvious, and each one would
# otherwise produce a page of false differences:
#
#   * HFS+ stores filenames decomposed (NFD) and 7z hands them back
#     composed (NFC), while find hands back what is on disk. Every
#     localized filename differs until both sides are normalized.
#   * 7z renders HFS+ hardlinks as an inode file under "[HFS+ Private
#     Data]" and reports the linked names as zero bytes. Linux resolves
#     them, so the same files look both missing and resized.
#   * The reference has a .Trashes directory because it was written by OS
#     X. It is not content.
#
# Exit status is non-zero if a required file is missing or the wrong size,
# or if anything else in the reference is absent from the build.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# What an install cannot proceed without: the bootloader, the installer
# package, the disk image the installer lays down and the chunklist it
# verifies that image against, and every one of the sixteen files in
# Packages -- fifteen packages and the machine list that says which Macs
# they may be installed on.
REQUIRED=(
    "System/Library/CoreServices/boot.efi"
    "System/Installation/BaseSystem.dmg"
    "System/Installation/BaseSystem.chunklist"
    "System/Installation/Packages/OSInstall.mpkg"
    "System/Installation/Packages/OSInstall.pkg"
    "System/Installation/Packages/OSUpgrade.pkg"
    "System/Installation/Packages/AdditionalEssentials.pkg"
    "System/Installation/Packages/AdditionalSpeechVoices.pkg"
    "System/Installation/Packages/AsianLanguagesSupport.pkg"
    "System/Installation/Packages/BaseSystemBinaries.pkg"
    "System/Installation/Packages/BaseSystemResources.pkg"
    "System/Installation/Packages/BSD.pkg"
    "System/Installation/Packages/Essentials.pkg"
    "System/Installation/Packages/InstallableMachines.plist"
    "System/Installation/Packages/JavaEssentials.pkg"
    "System/Installation/Packages/JavaTools.pkg"
    "System/Installation/Packages/MediaFiles.pkg"
    "System/Installation/Packages/OxfordDictionaries.pkg"
    "System/Installation/Packages/X11redirect.pkg"
)

# Apple's own checksums for the sixteen files in Packages. The file's
# header says why they are pinned rather than measured from the ESD.
APPLE_PACKAGES=$MQG_REPO_ROOT/media/apple-packages.sha256

# Check one directory of Apple's packages against that constant. The media
# build calls this twice -- on the ESD's Packages as converted and read,
# and on the finished media from a fresh mount -- so that a bad conversion
# and a bad copy are told apart by which call fails.
check_apple_packages() {
    local where=$1 bad n
    [ -d "$where" ] || die "no such directory: $where"
    [ -f "$APPLE_PACKAGES" ] || die "missing $APPLE_PACKAGES"
    n=$(grep -cv '^#' "$APPLE_PACKAGES" || true)
    bad=$(
        cd "$where" || exit 1
        # `|| true` on the grep, not on the subshell: sha256sum exits
        # non-zero on a mismatch, which is the case to REPORT, and grep
        # exits non-zero when everything is fine.
        sha256sum -c "$APPLE_PACKAGES" 2>&1 | grep -v ': OK$' || true
    )
    if [ -n "$bad" ]; then
        printf '%s\n' "$bad" | sed 's/^/    /' >&2
        warn "$where does not hold what Apple shipped"
        return 1
    fi
    log "all $n of Apple's packages match, in $where"
}

usage() {
    cat <<EOF
usage: $(basename "$0") [--built <img>] [--reference <img>]
       $(basename "$0") --compare-trees <a> <b>
       $(basename "$0") --check-packages <dir>
       $(basename "$0") --required

  --built/--reference  Override the images to compare.
  --compare-trees      Compare two directory trees instead of two images.
  --check-packages     Check a directory holding Apple's Packages against
                       media/apple-packages.sha256 -- what Apple shipped,
                       as a constant. Needs no image and no reference.
  --required           Print the files an install cannot proceed without.
EOF
}

mode=images
built=
reference=
tree_a=
tree_b=
pkg_dir=
while [ $# -gt 0 ]; do
    case $1 in
        --required) mode=required ;;
        --check-packages)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            mode=packages; pkg_dir=$2; shift ;;
        --compare-trees)
            mode=trees
            [ $# -ge 3 ] || { usage >&2; exit 2; }
            tree_a=$2; tree_b=$3; shift 2 ;;
        --built) [ $# -ge 2 ] || { usage >&2; exit 2; }; built=$2; shift ;;
        --reference) [ $# -ge 2 ] || { usage >&2; exit 2; }; reference=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$mode" = required ]; then
    printf '%s\n' "${REQUIRED[@]}"
    exit 0
fi

if [ "$mode" = packages ]; then
    require_cmd sha256sum
    check_apple_packages "$pkg_dir"
    exit $?
fi

require_cmd python3
MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}

if [ "$mode" = images ]; then
    require_cmd 7z
    built=${built:-$MQG_IMAGE_DIR/media/installer-linux.img}
    reference=${reference:-$MQG_IMAGE_DIR/media/InstallMavericks.iso}
    [ -f "$built" ] || die "no built image at $built --" \
        "run media/build-installer-img.sh first"
    [ -f "$reference" ] || die "no reference image at $reference"
    a=$reference
    b=$built
else
    [ -d "$tree_a" ] || die "no such directory: $tree_a"
    [ -d "$tree_b" ] || die "no such directory: $tree_b"
    a=$tree_a
    b=$tree_b
fi

# The comparison itself is Python: it needs Unicode normalization, which
# shell does not have, and set arithmetic over fifty thousand paths, which
# shell has but slowly.
# The required-file list is a statement about installer media, so it is
# only checked when installer media is what we are looking at.
# --compare-trees is the general instrument, used by the tests and by hand
# on two mounted volumes; holding two arbitrary directories to it would
# say nothing true.
MQG_REQUIRED=
if [ "$mode" = images ]; then
    MQG_REQUIRED=$(printf '%s\n' "${REQUIRED[@]}")
fi
export MQG_REQUIRED
rc=0
python3 - "$a" "$b" <<'PYTHON' || rc=$?
import os
import stat
import subprocess
import sys
import unicodedata
from collections import defaultdict

reference, build = sys.argv[1], sys.argv[2]
required = [p for p in os.environ.get("MQG_REQUIRED", "").splitlines() if p]

# Differences that are how the two tools describe the same volume, not
# differences in what is on it. Kept deliberately short: an allowlist is a
# place for real findings to hide.
ARTIFACT_PREFIXES = ("[HFS+ Private Data]", ".Trashes")


def norm(path):
    # HFS+ stores NFD; 7z composes. Compare in one normal form or every
    # localized name on the volume looks missing.
    return unicodedata.normalize("NFC", path)


def strip_volume(path):
    # 7z prefixes everything with the volume name, which is the same on
    # both images but is not part of any path we care about.
    _, sep, rest = path.partition("/")
    return rest if sep else ""


def from_image(path):
    """{path: (is_dir, size, packed)} plus the alternate streams."""
    # check=False deliberately. 7z exits 2 on the reference ISO: its Apple
    # partition map declares a physical size 6144 bytes past the end of the
    # file, so 7z says "Unexpected end of archive" -- after listing the
    # whole volume correctly. An exit status is not the evidence here; the
    # listing is. An empty listing is the failure worth raising.
    proc = subprocess.run(
        ["7z", "l", "-slt", "-ba", "-sns", path],
        capture_output=True, text=True, check=False,
    )
    out = proc.stdout
    entries, streams, modes = {}, {}, {}
    for block in out.split("\n\n"):
        d = {}
        for line in block.splitlines():
            key, sep, value = line.partition(" = ")
            if sep:
                d[key.strip()] = value.strip()
        if "Path" not in d:
            continue
        p = strip_volume(d["Path"])
        if not p:
            continue
        size = int(d["Size"]) if d.get("Size") else 0
        packed = int(d["Packed Size"]) if d.get("Packed Size") else 0
        if d.get("Alternate Stream") == "+" or ":" in os.path.basename(p):
            streams[norm(p)] = size
            continue
        entries[norm(p)] = (d.get("Folder") == "+", size, packed)
        modes[norm(p)] = d.get("Mode", "")
    if not entries:
        sys.stderr.write(proc.stderr)
        raise SystemExit("7z listed nothing in %s (exit %d)"
                         % (path, proc.returncode))
    if proc.returncode != 0:
        print("note: 7z exited %d listing %s; %d entries were read anyway"
              % (proc.returncode, os.path.basename(path), len(entries)))
    return entries, streams, modes


def from_tree(root):
    entries, modes = {}, {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            st = os.lstat(full)
            modes[norm(rel)] = stat.filemode(st.st_mode)
            if os.path.islink(full):
                entries[norm(rel)] = (False, len(os.readlink(full)), st.st_size)
            elif os.path.isdir(full):
                entries[norm(rel)] = (True, 0, 0)
            else:
                entries[norm(rel)] = (False, st.st_size, st.st_blocks * 512)
    return entries, {}, modes


def load(path):
    if os.path.isdir(path):
        return from_tree(path)
    return from_image(path)


def is_artifact(path):
    return any(path == p or path.startswith(p + "/") for p in ARTIFACT_PREFIXES)


def totals(entries):
    files = sum(1 for is_dir, _, _ in entries.values() if not is_dir)
    dirs = len(entries) - files
    size = sum(s for is_dir, s, _ in entries.values() if not is_dir)
    packed = sum(p for is_dir, _, p in entries.values() if not is_dir)
    return files, dirs, size, packed


def top_level(entries):
    per = defaultdict(lambda: [0, 0])
    for path, (is_dir, size, _) in entries.items():
        if is_dir:
            continue
        top = path.split("/")[0] if "/" in path else "(root)"
        per[top][0] += 1
        per[top][1] += size
    return per


ref, ref_streams, ref_modes = load(reference)
new, new_streams, new_modes = load(build)

print("== what is being compared ==")
print("reference: %s" % reference)
print("build:     %s" % build)
print()

rf, rd, rs, rp = totals(ref)
bf, bd, bs, bp = totals(new)
print("== totals ==")
print("%-10s %10s %8s %16s %16s" % ("", "files", "dirs", "bytes", "allocated"))
print("%-10s %10d %8d %16d %16d" % ("reference", rf, rd, rs, rp))
print("%-10s %10d %8d %16d %16d" % ("build", bf, bd, bs, bp))
print()

print("== per top-level directory ==")
rtop, btop = top_level(ref), top_level(new)
print("%-40s %8s %14s %8s %14s" % ("path", "ref n", "ref bytes", "n", "bytes"))
for name in sorted(set(rtop) | set(btop)):
    r = rtop.get(name, [0, 0])
    b = btop.get(name, [0, 0])
    flag = "" if (r[0] == b[0] and r[1] == b[1]) else "   <-- differs"
    print("%-40s %8d %14d %8d %14d%s" % (name, r[0], r[1], b[0], b[1], flag))
print()

missing = sorted(p for p in ref if p not in new)
unexplained = [p for p in missing if not is_artifact(p)]
explained = [p for p in missing if is_artifact(p)]
extra = sorted(p for p in new if p not in ref)

print("== in the reference, not in the build ==")
if not unexplained:
    print("(none)")
else:
    for p in unexplained:
        print("MISSING  %s" % p)
print()
if explained:
    print("(%d further paths differ only in how 7z and Linux describe the same"
          % len(explained))
    print(" volume -- HFS+ hardlink inodes and OS X's .Trashes -- not counted"
          " as missing)")
    print()

print("== in the build, not in the reference ==")
if not extra:
    print("(none)")
else:
    for p in extra[:40]:
        print("EXTRA    %s" % p)
    if len(extra) > 40:
        print("... and %d more" % (len(extra) - 40))
print()

print("== required files ==")
required_bad = 0
if not required:
    print("(not checked: two directories were compared, not installer media)")
for p in required:
    q = norm(p)
    if q not in new:
        print("MISSING  %s" % p)
        required_bad += 1
        continue
    rsize = ref[q][1] if q in ref else None
    bsize = new[q][1]
    if rsize is None:
        print("ok       %s  %d bytes (not in the reference)" % (p, bsize))
    elif rsize != bsize:
        print("SIZE     %s  reference %d, build %d" % (p, rsize, bsize))
        required_bad += 1
    else:
        print("ok       %s  %d bytes" % (p, bsize))
print()

print("== sizes that differ ==")
# Both directions matter, for different reasons. A file that is bigger in
# the build is the HFS+ compression signal the design asks about: a
# decompressed copy of a compressed file is larger. A file that is smaller
# is content that did not survive the copy.
bigger, smaller, hardlink_shaped = [], [], []
for p, (is_dir, size, _) in ref.items():
    if is_dir or p not in new or new[p][0]:
        continue
    bsize = new[p][1]
    if bsize == size:
        continue
    if size == 0 and bsize > 0:
        # 7z reports an HFS+ hardlink as zero bytes; Linux reports the
        # file it points at. Same file, two descriptions.
        hardlink_shaped.append((p, size, bsize))
    elif bsize > size:
        bigger.append((p, size, bsize))
    else:
        smaller.append((p, size, bsize))

def show(label, rows, limit=25):
    print("%s: %d" % (label, len(rows)))
    for p, r, b in rows[:limit]:
        print("    size  %s  reference %d, build %d" % (p, r, b))
    if len(rows) > limit:
        print("    ... and %d more" % (len(rows) - limit))

show("larger in the build (HFS+ compression not preserved?)", bigger)
show("smaller in the build (content lost)", smaller)
show("zero in the reference, present in the build (7z's hardlink rendering)",
     hardlink_shaped, limit=10)
print()

print("== HFS+ compression ==")
# A file stored compressed occupies less space than its logical size. If
# the reference has such files and the build does not, the copy
# decompressed them.
def compressed(entries):
    return [(p, s, k) for p, (is_dir, s, k) in entries.items()
            if not is_dir and 0 < k < s]
rc_, bc_ = compressed(ref), compressed(new)
print("files stored smaller than their logical size: reference %d, build %d"
      % (len(rc_), len(bc_)))
print("allocated bytes: reference %d, build %d (%+d)" % (rp, bp, bp - rp))
if not rc_ and not bc_:
    print("Neither image stores any file compressed, so there is no HFS+")
    print("compression here for a Linux rsync to lose.")
print()

print("== permission bits ==")
# Ownership cannot survive this pipeline: udisks mounts hfsplus
# uid=<you>,gid=<you>, so every file written is the invoking user's and the
# reference's root:wheel is not reproducible. Mode bits are a different
# question, and a more interesting one -- a setuid binary that lost its
# setuid bit is an installer that fails in a way nobody enjoys debugging --
# so they get measured rather than assumed.
mode_diff = sorted(p for p in ref
                   if p in new and p in ref_modes and p in new_modes
                   and ref_modes[p] != new_modes[p])
def special(modes, entries):
    return [p for p, m in modes.items()
            if len(m) == 10 and ("s" in m[3] + m[6] or "t" == m[9])
            and p in entries]
# Two of the three kinds of mode difference are about how each writer
# spells something rather than what it means:
#   * Linux creates every symlink 0777; OS X wrote them 0755. Neither
#     system consults a symlink's own permission bits.
#   * An HFS+ hard link's *directory entry* is a stub whose mode is not the
#     file's -- the reference spells those -r--r--r--, Linux spells them
#     0---------, and both are ignored in favour of the inode under [HFS+
#     Private Data], which carries -rwxr-xr-x on both images.
# Anything left over is a real difference in what the media says about a
# file, so it gets listed in full.
symlinks = [p for p in mode_diff if ref_modes[p].startswith("l")]
hardlinks = [p for p in mode_diff
             if not ref_modes[p].startswith("l") and new_modes[p].startswith("0")]
other = [p for p in mode_diff if p not in set(symlinks) | set(hardlinks)]
print("files whose mode differs: %d" % len(mode_diff))
print("  symlinks (0777 here, 0755 there; nobody reads them): %d" % len(symlinks))
print("  hard link stubs (the inode carries the real mode): %d" % len(hardlinks))
print("  everything else: %d" % len(other))
for p in other[:40]:
    print("    mode  %s  reference %s, build %s" % (p, ref_modes[p], new_modes[p]))
if len(other) > 40:
    print("    ... and %d more" % (len(other) - 40))
ref_special, new_special = set(special(ref_modes, ref)), set(special(new_modes, new))
print("setuid/setgid/sticky entries: reference %d, build %d"
      % (len(ref_special), len(new_special)))
for p in sorted(ref_special - new_special):
    print("    only in the reference: %s (%s)" % (p, ref_modes[p]))
for p in sorted(new_special - ref_special):
    print("    only in the build:     %s (%s)" % (p, new_modes[p]))
print("(ownership is not compared: every file here is owned by whoever ran")
print(" the build, because that is the only thing udisks will mount as)")
print()

print("== alternate streams (resource forks, ACLs) ==")
print("reference %d streams, %d bytes" % (len(ref_streams), sum(ref_streams.values())))
print("build     %d streams, %d bytes" % (len(new_streams), sum(new_streams.values())))
lost = sorted(p for p in ref_streams if p not in new_streams)
kinds = defaultdict(int)
for p in lost:
    kinds[p.rsplit(":", 1)[1]] += 1
for kind, n in sorted(kinds.items()):
    print("  not in the build: %d x :%s" % (n, kind))
print()

print("== verdict ==")
failed = bool(unexplained) or required_bad
if failed:
    if unexplained:
        print("FAIL: %d paths in the reference are missing from the build"
              % len(unexplained))
    if required_bad:
        print("FAIL: %d required files are missing or the wrong size"
              % required_bad)
else:
    print("PASS: every path in the reference is in the build, and every")
    print("      required file is present at the reference's size.")
sys.exit(1 if failed else 0)
PYTHON

if [ "$mode" = images ]; then
    echo
    echo "== dmesg, hfsplus ==="
    echo "(timestamps are seconds since boot: check them against the build,"
    echo " because this log outlives it)"
    if dmesg >/dev/null 2>&1; then
        if dmesg | tail -n 200 | grep -i hfsplus; then
            warn "the kernel logged hfsplus messages -- read them above"
        else
            echo "(no hfsplus messages in the last 200 kernel log lines)"
        fi
    else
        echo "(dmesg is not readable here)"
    fi
fi

exit "$rc"
