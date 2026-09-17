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
PY
    rm -f "$base.ppm"
    log "saved $base.png"
    printf '%s\n' "$base.png"
else
    warn "python3-pil not installed; leaving PPM"
    printf '%s\n' "$base.ppm"
fi
