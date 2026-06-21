#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ss_garble_probe.sh -- STAGE-0 board-free graphics-garble probe.
#
# Takes a HW savestate (.ss, frozen at a garbled scene) + a MAME VRAM reference,
# carves our FROZEN VRAM out of the .ss, renders both VRAMs full-frame, and emits
# a PER-REGION byte-diff NUMBER (+heatmap+json) localizing WHERE our VRAM diverges
# from MAME's. This is the cheapest rung of the garble hunt (no sim, no FPGA
# build) and the first thing to run once a real .ss is in hand.
#
# The garble theory is "wrong palette/data reaching the GPU at draw time." Because
# TEXTURE pages in VRAM are largely scene-INDEPENDENT (the atlas is uploaded once
# and persists), a region-diff vs ANY MAME frame with the same textures loaded
# tells the truth about the texture/CLUT regions even if the FRAMEBUFFER region
# (scene-dependent) differs. Read the heatmap as: framebuffer cells differing =
# expected if scenes differ; TEXTURE/CLUT cells differing = the data bug.
#
# Usage:
#   tools/ss_garble_probe.sh STATE.ss MAME_VRAM.bin [GRID] [OUTDIR]
#     STATE.ss      a HW savestate (Alt-F1 on the MiSTer, copied off the SD)
#     MAME_VRAM.bin a MAME VRAM dump (>=1 MiB; first 1024x512 RGB555 is used)
#     GRID          region grid RxC for the diff (default 16x16)
#     OUTDIR        output dir (default local/ss_garble)
#
# Exit: frame_diff_regions' verdict -- 0 = MATCH, 1 = MISMATCH, 2 = usage/load.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HUB="${HUB:-$HOME/Dev/tools}"

if [ $# -lt 2 ]; then
  sed -n '23,33p' "$0"; exit 2
fi
SS="$1"; MAME="$2"; GRID="${3:-16x16}"; OUT="${4:-$REPO/local/ss_garble}"
mkdir -p "$OUT"

echo "[1/3] carving our frozen VRAM out of $SS"
python3 "$HERE/ss_vram_extract.py" "$SS" --vram "$OUT/ss_vram.bin"

echo "[2/3] rendering both VRAMs full-frame (1024x512)"
python3 "$HERE/hw_display_frame.py" "$OUT/ss_vram.bin" --window 0,0,1024,512 --out "$OUT/ss_vram.png"
python3 "$HERE/hw_display_frame.py" "$MAME"            --window 0,0,1024,512 --out "$OUT/mame_vram.png"

echo "[3/3] per-region byte-diff (grid $GRID) vs MAME -> $OUT/verdict.json"
set +e
python3 "$HUB/tools/frame_diff_regions.py" "$OUT/mame_vram.png" "$OUT/ss_vram.png" \
    --grid "$GRID" --heatmap "$OUT/vram_heat.png" --json | tee "$OUT/verdict.json"
rc=${PIPESTATUS[0]}
set -e
echo
echo "artifacts in $OUT/ : ss_vram.png  mame_vram.png  vram_heat.png  verdict.json"
echo "verdict exit=$rc (0=MATCH 1=MISMATCH)"
exit "$rc"
