#!/usr/bin/env bash
# =============================================================================
# mister_capture_pair.sh -- pair each HW savestate (your Alt+F1) with screenshots
# of the displayed frame, so we get the GARBLED VRAM and the GARBLED OUTPUT together.
#
# WHY: a .ss freezes VRAM (the rendered framebuffer + machine state) but NOT the
# final scaled video output, and the headless capture tool kept hitting blank /
# transition frames. With YOU pressing Alt+F1 when you actually SEE garble, the
# savestate's displayed buffer will contain the garble -- and the paired screenshot
# settles whether the bug is in RENDERING (VRAM garbled) or the DISPLAY path
# (VRAM fine, output garbled).
#
# HOW: this runs on the Mac. It continuously auto-triggers a screenshot (rolling
# buffer of the last 3) and watches /media/fat/savestates for a NEW .ss. When you
# press Alt+F1 and a new .ss appears, it pulls the .ss + the 3 surrounding
# screenshots as a labelled pair into ./local/. The garbled frame is among the 3
# (the black "save pause" shots are tiny PNGs, easy to skip).
#
# USAGE (you play on the MiSTer; this harvests):
#   tools/mister_capture_pair.sh [PREFIX] [MAX_PAIRS]
#     PREFIX     local file prefix          (default: garble)
#     MAX_PAIRS  stop after N savestates    (default: 30)
#   Then on the MiSTer: play hyperbbc and press Alt+F1 EACH TIME you see clear
#   garble. Ctrl-C here when done. Outputs: local/<PREFIX>_<n>.ss +
#   local/<PREFIX>_<n>_shot{A,B,C}.png
#
# Reads local/mister.env. Cleans up the screenshots it pulls off the SD.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"
OUT="$ROOT/local"; mkdir -p "$OUT"
PFX="${1:-garble}"; MAXN="${2:-30}"
SHOT_DIR="${MISTER_SHOT_DIR:-/media/fat/screenshots}"
SS_DIR="/media/fat/savestates"

KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
SSH=(ssh -o ConnectTimeout=8 -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:-mister}")
# fall back to a bare host alias if the keyed form fails
"${SSH[@]}" true 2>/dev/null || SSH=(ssh -o ConnectTimeout=8 mister)

echo "== baselining existing savestates (only NEW ones get paired) =="
"${SSH[@]}" "find $SS_DIR -name '*.ss' 2>/dev/null" | sort > /tmp/cp_seen.txt
echo
echo ">>> READY. On the MiSTer: play hyperbbc and press Alt+F1 EVERY TIME you see clear garble."
echo ">>> I auto-screenshot continuously and pair each savestate with the frames around it."
echo ">>> Ctrl-C here when you're done (stops automatically after $MAXN savestates)."
echo

n=0; ri=0
RS=("$OUT/.cp_s0.png" "$OUT/.cp_s1.png" "$OUT/.cp_s2.png")
while [ "$n" -lt "$MAXN" ]; do
  # rolling screenshot: trigger, wait, pull newest, delete it off the SD
  "${SSH[@]}" "echo screenshot > /dev/MiSTer_cmd" 2>/dev/null || true
  sleep 1
  newshot="$("${SSH[@]}" "ls -t $SHOT_DIR/*/*.png $SHOT_DIR/*.png 2>/dev/null | head -1" 2>/dev/null || true)"
  if [ -n "$newshot" ]; then
    "${SSH[@]}" "cat '$newshot'" > "${RS[$ri]}" 2>/dev/null || true
    "${SSH[@]}" "rm -f '$newshot'" 2>/dev/null || true
    ri=$(( (ri + 1) % 3 ))
  fi
  # new savestate?
  "${SSH[@]}" "find $SS_DIR -name '*.ss' 2>/dev/null" | sort > /tmp/cp_now.txt
  newss="$(comm -13 /tmp/cp_seen.txt /tmp/cp_now.txt || true)"
  if [ -n "$newss" ]; then
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      n=$((n + 1))
      "${SSH[@]}" "cat '$s'" > "$OUT/${PFX}_${n}.ss" 2>/dev/null || true
      cp -f "${RS[0]}" "$OUT/${PFX}_${n}_shotA.png" 2>/dev/null || true
      cp -f "${RS[1]}" "$OUT/${PFX}_${n}_shotB.png" 2>/dev/null || true
      cp -f "${RS[2]}" "$OUT/${PFX}_${n}_shotC.png" 2>/dev/null || true
      sz=$(wc -c < "$OUT/${PFX}_${n}.ss" 2>/dev/null || echo 0)
      echo "  [pair $n] $(basename "$s") -> ${PFX}_${n}.ss (${sz} B) + 3 screenshots"
    done <<< "$newss"
    cp -f /tmp/cp_now.txt /tmp/cp_seen.txt
  fi
done
echo
echo "== done: $n pairs in $OUT/ (each = <prefix>_<n>.ss + _shotA/B/C.png) =="
