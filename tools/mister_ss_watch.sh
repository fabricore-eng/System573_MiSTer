#!/usr/bin/env bash
# =============================================================================
# mister_ss_watch.sh -- watch the MiSTer for savestates YOU capture (Alt+F1..F4)
# and, for each, pull the .ss AND render its EXACT displayed frame.
#
# A .ss freezes VRAM + the GPU display registers, so the displayed image is fully
# determined by the savestate. ss_render_display.py reconstructs that exact frame
# (correct double-buffer via vramRange) -- so each capture is a .ss + a screenshot
# of the SAME frame, by construction (no timing mismatch).
#
# IMPORTANT: Alt+F1 reuses slot 1 (overwrites). This polls fast and pulls each
# save the instant its mtime changes -- so SPACE your presses ~3s apart, or use
# Alt+F1..F4 for four independent slots.
#
# USAGE (you play on the MiSTer; this harvests):
#   tools/mister_ss_watch.sh [PREFIX] [MAX]
# Outputs per capture: local/<PREFIX>_<HHMMSS>_slotN.ss + ..._slotN.display.png
# Ctrl-C when done (auto-stops after MAX). Reads local/mister.env.
# Bash 3.2 compatible (macOS) -- no associative arrays.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"
OUT="$ROOT/local"; mkdir -p "$OUT"
PFX="${1:-garb}"; MAXN="${2:-40}"
SS_DIR="/media/fat/savestates/Arcade"
KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
SSH=(ssh -o ConnectTimeout=8 -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:-192.168.1.40}")
"${SSH[@]}" true 2>/dev/null || SSH=(ssh -o ConnectTimeout=8 mister)

list_states() { "${SSH[@]}" "for f in $SS_DIR/*.ss; do [ -e \"\$f\" ] && stat -c '%Y %n' \"\$f\"; done" 2>/dev/null; }

# baseline: only saves with mtime AFTER this start the harvest (don't re-pull old)
last_max=$(list_states | awk '{if($1>m)m=$1}END{print m+0}')
echo ">>> READY. On the MiSTer: play hyperbbc and press Alt+F1 each time you SEE clear garble."
echo ">>> Space presses ~3s apart (Alt+F1 overwrites). Each is pulled + rendered. Ctrl-C when done."
echo
n=0
while [ "$n" -lt "$MAXN" ]; do
  new_max="$last_max"
  while read -r mt path; do
    [ -n "${path:-}" ] || continue
    if [ "$mt" -gt "$last_max" ]; then
      slot="$(basename "$path" .ss | sed 's/.*_//')"
      ts="$(date +%H%M%S 2>/dev/null || echo "$mt")"
      dst="$OUT/${PFX}_${ts}_slot${slot}.ss"
      "${SSH[@]}" "cat '$path'" > "$dst" 2>/dev/null
      sz=$(wc -c < "$dst" 2>/dev/null || echo 0)
      if [ "$sz" -eq 4194304 ]; then
        n=$((n + 1))
        png="${dst%.ss}.display.png"
        python3 "$HERE/ss_render_display.py" "$dst" --out "$png" 2>/dev/null \
          && echo "  [$n] caught slot$slot @${ts} -> $(basename "$dst") + $(basename "$png")" \
          || echo "  [$n] caught slot$slot @${ts} -> $(basename "$dst") (render failed)"
      else
        rm -f "$dst"
      fi
    fi
    [ "$mt" -gt "$new_max" ] && new_max="$mt"
  done < <(list_states)
  last_max="$new_max"
  sleep 1.5
done
echo
echo "== done: $n captures in $OUT/ (each .ss + its exact-frame .display.png) =="
