#!/usr/bin/env bash
# Generate the CD-image $readmemh fixture for tb_atapi_cdread.v from the (gitignored,
# copyrighted) game CHD/CD dump. The fixture is the RAW 2352-byte sectors for a small
# LBA window (0..NSEC-1), one hex byte per line, so the end-to-end ATAPI READ(10) test
# can drive a real ISO9660 disc image through atapi.v + s573_cdimg and assert the
# returned PIO bytes are the disc's ACTUAL data (the ISO9660 PVD at LBA 16: "CD001").
#
#   sim/cddata/hypbbc2p_raw.hex   NSEC*2352 bytes, raw MODE1/2352 sectors of LBA 0..NSEC-1
#   sim/cddata/hypbbc2p.meta      "NSEC=<n>" so the tb knows how many sectors are present
#
# Source preference: an already-extracted /tmp/hypbbc2p.bin, else extract the CHD with
# chdman, else (fallback) a raw dumps/bishi/cd.bin. If NONE is present this exits 0
# WITHOUT writing the fixture -- tb_atapi_cdread.v then SKIPS the real-disc assertions
# and falls back to a SYNTHETIC ISO9660 sector it builds itself, so `make` stays green
# on machines without the CD dumps (the synthetic path still proves the full data flow).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/cddata"; mkdir -p "$OUT"
NSEC=64                 # raw sectors 0..63 -> covers the ISO9660 PVD (LBA 16)

CHD="$ROOT/dumps/mame573/hypbbc2p/908a02.chd"
BIN=""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -f /tmp/hypbbc2p.bin ]; then
  BIN=/tmp/hypbbc2p.bin
elif [ -f "$CHD" ] && command -v chdman >/dev/null 2>&1; then
  if chdman extractcd -f -i "$CHD" -o "$TMP/cd.cue" -ob "$TMP/cd.bin" >/dev/null 2>&1; then
    BIN="$TMP/cd.bin"
  fi
elif [ -f "$ROOT/dumps/bishi/cd.bin" ]; then
  BIN="$ROOT/dumps/bishi/cd.bin"     # also raw MODE1/2352 (different game, still real ISO9660)
fi

if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
  echo "gen_cddata: no CD dump found -- tb_atapi_cdread will use its SYNTHETIC ISO9660 sector"
  rm -f "$OUT/hypbbc2p_raw.hex" "$OUT/hypbbc2p.meta"
  exit 0
fi

python3 - "$BIN" "$OUT/hypbbc2p_raw.hex" "$NSEC" <<'PY'
import sys
src, dst, nsec = sys.argv[1], sys.argv[2], int(sys.argv[3])
RAW = 2352
data = open(src, 'rb').read()
n = min(nsec, len(data)//RAW)
with open(dst, 'w') as f:
    for b in data[:n*RAW]:
        f.write(f"{b:02x}\n")
print(f"gen_cddata: wrote {dst} ({n} raw sectors)")
open(dst.rsplit('/',1)[0] + '/hypbbc2p.meta', 'w').write(f"NSEC={n}\n")
PY
