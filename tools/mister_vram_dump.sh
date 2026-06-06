#!/usr/bin/env bash
# =============================================================================
# mister_vram_dump.sh -- dump the running core's RAW PSX VRAM off the MiSTer,
# full-resolution, no scaling, and render it to a PNG for objective inspection.
#
# WHY THIS EXISTS / THE KEY INSIGHT: the only thing that normally comes off a
# running core is the SCALED video output (lossy -- downscaling aliases dense
# texture data into moire stripes, which is indistinguishable from real
# corruption). But the PSX core stores its 1024x512 16-bit VRAM in DDR3 at
# FPGA addr 0x30000000, the f2h bridge maps it 1:1 to HPS physical 0x30000000,
# and it is readable from Linux. CRITICAL: read it with mmap(), NOT a dd/read()
# of /dev/mem -- STRICT_DEVMEM ZEROES read() of that region but ALLOWS mmap()
# (which is how MiSTer's own Main process reads its DDR buffers). So:
#   - `dd if=/dev/mem skip=...`  -> all zeros (the trap that looked "blocked")
#   - python mmap of /dev/mem    -> the real VRAM bytes
# This is a GENERIC MiSTer core-debugging capability (read any core's DDR
# framebuffer/VRAM region from the HPS via mmap), not 573-specific.
#
# Usage: tools/mister_vram_dump.sh [out_prefix]   (default: local/vram)
#   -> <prefix>.bin (raw 1 MB), <prefix>.png (1024x512), + left/right crops.
# Reads local/mister.env for the board if `ssh mister` is unset.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"
PREFIX="${1:-$ROOT/local/vram}"; mkdir -p "$(dirname "$PREFIX")"

SSH=(ssh mister)
ssh -o ConnectTimeout=6 -o BatchMode=yes mister true 2>/dev/null || {
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}"); }

VRAM_PHYS="${VRAM_PHYS:-0x30000000}"   # PSX VRAM base in HPS phys (f2h 1:1)
echo "== mmap-dump 1 MB VRAM @ $VRAM_PHYS on the board =="
"${SSH[@]}" "python3 - <<PY
import mmap, os
fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
length = 1024*512*2
m = mmap.mmap(fd, length, mmap.MAP_SHARED, mmap.PROT_READ, offset=$VRAM_PHYS)
open('/tmp/vram.bin','wb').write(m.read(length))
m.close(); os.close(fd)
print('dumped', length, 'bytes')
PY" 2>/dev/null

"${SSH[@]}" "cat /tmp/vram.bin" > "$PREFIX.bin"
echo "== render full-res PNG (PSX 16bpp: b0-4=R b5-9=G b10-14=B) =="
python3 - "$PREFIX" <<'PY'
import sys, array
from PIL import Image
pfx = sys.argv[1]
raw = open(pfx + '.bin', 'rb').read()
W, H = 1024, 512
words = array.array('H'); words.frombytes(raw)
img = Image.new('RGB', (W, H)); px = img.load()
for y in range(H):
    for x in range(W):
        v = words[y*W + x]
        px[x, y] = ((v & 0x1F) << 3, ((v >> 5) & 0x1F) << 3, ((v >> 10) & 0x1F) << 3)
img.save(pfx + '.png')
img.crop((0, 0, 512, 512)).save(pfx + '_left.png')
img.crop((512, 0, 1024, 512)).save(pfx + '_right.png')
print('rendered', pfx + '.png', '(+ _left/_right crops)')
PY
echo "Done: $PREFIX.bin / .png / _left.png / _right.png"
