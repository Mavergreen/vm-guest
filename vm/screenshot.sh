#!/usr/bin/env bash
# Capture the guest's screen via the QEMU monitor socket.
#
# Works while someone is using the GTK window, so an interactive session can
# be recorded without anyone transcribing screens by hand. Shots land outside
# the repo: they are large, numerous, and the repo is on NFS.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}
MONITOR=${MQG_MONITOR:-$MQG_IMAGE_DIR/work/monitor.sock}
SHOT_DIR=${MQG_SHOT_DIR:-$MQG_IMAGE_DIR/screenshots}

[ -S "$MONITOR" ] || die "no monitor socket at $MONITOR -- is the VM running with one?"
require_cmd python3

label=${1:-shot}
mkdir -p "$SHOT_DIR"
stamp=$(date -u +%Y%m%d-%H%M%S)
base="$SHOT_DIR/${stamp}-${label}"

python3 - "$MONITOR" "$base.ppm" <<'PY'
import socket, sys, time
mon, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.connect(mon)
s.settimeout(5)
time.sleep(0.3)
try:
    s.recv(65536)
except Exception:
    pass
s.sendall(("screendump %s\n" % out).encode())
time.sleep(1.0)
PY

[ -f "$base.ppm" ] || die "screendump produced nothing at $base.ppm"

# THE VERDICT IS COMPUTED FROM THE RAW PPM, WITH THE STANDARD LIBRARY ONLY.
#
# It used to live inside an `if python3 -c 'import PIL'` block, so a host
# without python3-pil printed "python3-pil not installed; leaving PPM"
# instead of saying what was on the screen. On ap-juicer, 2026-09-21, that
# happened every four minutes for an hour -- during the one run whose
# entire question was whether the guest had panicked. The diagnostic went
# missing exactly when it was the only thing anyone wanted, because it had
# been tied to a package that has nothing to do with the answer.
#
# A PPM is a short header and a block of RGB bytes. Reading it is thirty
# lines, and those thirty lines are worth more than the PNG.
python3 - "$base.ppm" <<'PY'
import sys

d = open(sys.argv[1], "rb").read()

# P6 header: magic, width, height, maxval, whitespace-separated, then the
# binary pixels. '#' comments are legal between fields.
i = 0
fields = []
while len(fields) < 4:
    while i < len(d) and d[i:i + 1].isspace():
        i += 1
    if d[i:i + 1] == b"#":
        while i < len(d) and d[i:i + 1] != b"\n":
            i += 1
        continue
    j = i
    while j < len(d) and not d[j:j + 1].isspace():
        j += 1
    fields.append(d[i:j])
    i = j
i += 1

if fields[0] != b"P6":
    sys.stderr.write("  not a P6 PPM (%s) -- no verdict\n" % fields[0].decode())
    sys.exit(0)

w, h = int(fields[1]), int(fields[2])
px = d[i:i + w * h * 3]

# Lit pixels, not just the colour count.
#
# Counting distinct colours is a trap, and it cost an hour of P3: a screen
# of white-on-black text has exactly TWO colours, which reads as "black
# screen" if you treat a low colour count as blank. A genuinely blank
# screen has ONE. The difference between "the bootloader menu is rendering
# fine" and "nothing is on screen" was a single integer, in the wrong
# direction from the intuitive reading.
colours = set()
lit = 0
for j in range(0, len(px) - 2, 3):
    c = px[j:j + 3]
    colours.add(c)
    # Rec. 601 luma, which is what PIL's "L" conversion did before.
    if (c[0] * 299 + c[1] * 587 + c[2] * 114) // 1000 > 20:
        lit += 1

total = w * h
pct = 100.0 * lit / total if total else 0.0

# BOTH numbers, because either one alone gets it wrong.
#
# Lit percentage alone misreads a panic: OS X's panic screen is white text
# on black, 2 colours, and about 9.6% lit -- which is over the old 5%
# threshold, so it was classified "graphical", the one word that would
# make a reader think the guest was fine. Measured on ap-juicer and on
# this host; a Finder desktop is 185799 colours at 99.78%.
#
# Colour count alone misreads in the other direction, which cost an hour
# in P3: 2 colours reads as "black screen" when it is white-on-black TEXT.
# A genuinely blank screen has ONE colour.
#
# So: a handful of distinct colours means something is drawing text, at
# any density. Many colours and almost nothing lit means a dark desktop
# rather than an empty one.
if len(colours) <= 1 or pct < 0.01:
    verdict = "blank"
elif len(colours) <= 8:
    verdict = "text (a console, a menu, or a panic)"
elif pct < 5:
    verdict = "mostly dark, but many colours -- look at it"
else:
    verdict = "graphical"
sys.stderr.write(
    "  %dx%d  %d colours  %d lit px (%.2f%%) -- %s\n"
    % (w, h, len(colours), lit, pct, verdict)
)
PY

# PNG is the convenience, and only the convenience needs PIL.
if python3 -c 'import PIL' 2>/dev/null; then
    python3 - "$base" <<'PY'
import sys
from PIL import Image
base = sys.argv[1]
Image.open(base + ".ppm").save(base + ".png")
PY
    rm -f "$base.ppm"
    log "saved $base.png"
    printf '%s\n' "$base.png"
else
    log "saved $base.ppm (no python3-pil, so no PNG; the verdict above is unaffected)"
    printf '%s\n' "$base.ppm"
fi
