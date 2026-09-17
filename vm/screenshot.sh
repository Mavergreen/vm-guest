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

if python3 -c 'import PIL' 2>/dev/null; then
    python3 - "$base" <<'PY'
import sys
from PIL import Image
base = sys.argv[1]
im = Image.open(base + ".ppm")
im.save(base + ".png")

# Report lit pixels, not just the colour count.
#
# Counting distinct colours is a trap, and it cost an hour of P3: a screen
# of white-on-black text has exactly TWO colours, which reads as "black
# screen" if you are treating a low colour count as blank. A genuinely
# blank screen has ONE. The difference between "the bootloader menu is
# rendering fine" and "nothing is on screen" was a single integer, in the
# wrong direction from the intuitive reading.
#
# Lit-pixel percentage says what it means: ~0% is blank, a fraction of a
# percent is text, ~100% is a drawn desktop.
g = im.convert("L")
lit = sum(1 for px in g.getdata() if px > 20)
total = im.size[0] * im.size[1]
colours = len(set(im.convert("RGB").getdata()))
pct = 100.0 * lit / total
if pct < 0.01:
    verdict = "blank"
elif pct < 5:
    verdict = "text (a menu or console)"
else:
    verdict = "graphical"
sys.stderr.write(
    "  %dx%d  %d colours  %d lit px (%.2f%%) -- %s\n"
    % (im.size[0], im.size[1], colours, lit, pct, verdict)
)
PY
    rm -f "$base.ppm"
    log "saved $base.png"
    printf '%s\n' "$base.png"
else
    warn "python3-pil not installed; leaving PPM"
    printf '%s\n' "$base.ppm"
fi
