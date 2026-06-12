#!/usr/bin/env bash
# =============================================================================
# mame_render_ss.sh -- render a 573 savestate's EXACT frame through MAME's correct
# GPU (the trusted oracle), for a direct correct-vs-ours comparison (no image
# matching). Extracts RAM+VRAM+CPU-regs (ss_to_mame.py), injects them into a
# running MAME hyperbbc (mame_inject.lua), lets it re-render, pulls the snapshot.
#
# Usage:  tools/mame_render_ss.sh STATE.ss
# Output: local/mame_inj/<name>_*.png  (MAME's correct render of that frame)
# INJ_FRAME is set in mame_inject.lua (default 4200 = ~70s, MAME in attract).
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
SS="${1:?usage: mame_render_ss.sh STATE.ss}"
NAME="$(basename "$SS" .ss)"
INJF=4200; SECS=$(( (INJF+12)/60 + 3 ))

echo "== extract RAM/VRAM/regs from $SS =="
python3 "$HERE/ss_to_mame.py" "$SS" /tmp/ssm || exit 1
echo "== ship to dell =="
scp -q /tmp/ssm_ram.bin  dell:/tmp/mame_inj_ram.bin
scp -q /tmp/ssm_vram.bin dell:/tmp/mame_inj_vram.bin
scp -q /tmp/ssm_regs.bin dell:/tmp/mame_inj_regs.bin
ssh dell "rm -f ~/.mame/snap/hyperbbc/*.png" 2>/dev/null
echo "== run MAME ($SECS s) with the injector (inject@frame $INJF) =="
"$HERE/mame_capture.sh" "$SECS" "inj_$NAME" "$HERE/mame_inject.lua" > /tmp/mame_inj_run.log 2>&1
echo "-- injector log --"; grep -E 'INJECT' /tmp/mame_inj_run.log || echo "(no INJECT lines -- lua may have errored)"
echo "== pull snapshots =="
mkdir -p "$ROOT/local/mame_inj"
ssh dell "cd ~/.mame/snap/hyperbbc && tar cf - *.png 2>/dev/null" | tar xf - -C "$ROOT/local/mame_inj" 2>/dev/null
# rename to the savestate name for clarity
i=0; for p in $(ls "$ROOT/local/mame_inj"/[0-9]*.png 2>/dev/null); do
  mv "$p" "$ROOT/local/mame_inj/${NAME}_$(printf %02d $i).png"; i=$((i+1)); done
echo "== output:"; ls -la "$ROOT/local/mame_inj/${NAME}"_*.png 2>/dev/null | awk '{print $5,$9}'
