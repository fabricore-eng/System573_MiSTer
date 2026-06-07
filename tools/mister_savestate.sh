#!/usr/bin/env bash
# =============================================================================
# mister_savestate.sh -- HEADLESS savestate capture from the MiSTer + "know when"
# triggers. Injects the savestate hotkey (Alt+F1) via /dev/uinput on the board
# (no physical keypress), waits for the .ss to land, and pulls it to ./local/.
#
# A MiSTer savestate freezes the core's COMPLETE state (VRAM/RAM/regs) and is
# byte-identical HW<->our NVC sim -- so an auto-captured .ss is the entry point
# to the whole deterministic-forensics pipeline (tools/ss_vram_extract.py,
# ss_garble_probe.sh, the sim replay). This turns "ask a human to hit Alt+F1 at
# the right moment" into an automated net that captures bug-states by itself.
#
# MODES
#   mister_savestate.sh                       capture ONE now -> local/ss_<ts>.ss
#   mister_savestate.sh OUT.ss                capture ONE now -> OUT.ss
#   mister_savestate.sh --every N --count M [PFX]
#                                             M captures, N seconds apart (filmstrip)
#   mister_savestate.sh --watch [opts]        screenshot loop; CAPTURE WHEN it decides
#       --interval S    seconds between screenshot checks        (default 5)
#       --thresh PCT    %-pixels-changed that counts as a trigger (default 8)
#       --max N         stop after N captures                    (default 12)
#       --ref REF.png   trigger on divergence FROM a reference image (e.g. a MAME
#                       frame) instead of scene-CHANGE between consecutive shots
#       --mins M        stop after M minutes                     (default 30)
#   Common: --slot K  (1..4 -> Alt+F1..F4)   --name NAME (local file prefix)
#
# Requires on the board: python3 + /dev/uinput (both present on stock MiSTer).
# Uses the hub frame_diff.py for the --watch decision. Reads local/mister.env.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"
HUB="${HUB:-$HOME/Dev/mister-dev-hub}"
OUTDIR="$ROOT/local"; mkdir -p "$OUTDIR"
INJECT="$HERE/_mister_uinput_inject.py"
SHOT_DIR="/media/fat/screenshots"
SS_DIR="/media/fat/savestates"

# ---- ssh plumbing (prefer the `ssh mister` alias) ---------------------------
if ssh -o ConnectTimeout=6 -o BatchMode=yes mister true 2>/dev/null; then
  SSH=(ssh mister); HOST=mister
else
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}")
  HOST="${MISTER_USER:-root}@${MISTER_HOST}"
fi
shq() { "${SSH[@]}" "$@" 2>/dev/null; }

SLOT=1; NAME="ss"; MODE=one; EVERY=0; COUNT=1; INTERVAL=5; THRESH=8; MAX=12; MINS=30; REF=""
OUT=""
while [ $# -gt 0 ]; do case "$1" in
  --every) EVERY="$2"; MODE=every; shift 2;;
  --count) COUNT="$2"; shift 2;;
  --watch) MODE=watch; shift;;
  --interval) INTERVAL="$2"; shift 2;;
  --thresh) THRESH="$2"; shift 2;;
  --max) MAX="$2"; shift 2;;
  --mins) MINS="$2"; shift 2;;
  --ref) REF="$2"; shift 2;;
  --slot) SLOT="$2"; shift 2;;
  --name) NAME="$2"; shift 2;;
  -*) echo "unknown opt $1" >&2; exit 2;;
  *) OUT="$1"; shift;;
esac; done
FKEY=$((58 + SLOT))   # KEY_F1=59 (slot1) .. KEY_F4=62 (slot4)

ensure_injector() { scp -q "$INJECT" "$HOST:/tmp/_mister_uinput_inject.py" 2>/dev/null; }

# capture one savestate; echoes the pulled local path. arg1 = local out path.
capture_one() {
  local out="$1"
  local got
  got="$(shq 'M=/tmp/ssm.$$; touch "$M"; sleep 0.2
    python3 /tmp/_mister_uinput_inject.py 56 '"$FKEY"' >/dev/null
    for i in $(seq 1 12); do
      h=$(find '"$SS_DIR"' -name "*.ss" -newer "$M" 2>/dev/null | head -1)
      [ -n "$h" ] && { sleep 0.5; echo "$h"; exit 0; }
      sleep 1
    done; exit 1')" || { echo "  ! no .ss appeared (slot $SLOT trigger failed)" >&2; return 1; }
  shq "cat '$got'" > "$out"
  local sz; sz=$(wc -c < "$out")
  if [ "$sz" -ne 4194304 ]; then echo "  ! pulled $out is $sz B (expected 4194304)" >&2; fi
  echo "$out"
}

# pull a fresh MiSTer screenshot to arg1
shot() {
  local out="$1"
  shq "echo screenshot > /dev/MiSTer_cmd 2>/dev/null; sleep 1.5"
  local newest; newest="$(shq "ls -t $SHOT_DIR/*/*.png $SHOT_DIR/*.png 2>/dev/null | head -1")"
  [ -n "$newest" ] || return 1
  shq "cat '$newest'" > "$out"
}

# %pixels-differing between two PNGs (via hub frame_diff.py --json). frame_diff
# exits 1 on MISMATCH which is EXPECTED here, so capture its JSON separately
# (|| true) and parse it -- never let its exit code trip pipefail/the fallback.
pct_diff() {
  local j
  j="$(python3 "$HUB/tools/frame_diff.py" "$1" "$2" --json 2>/dev/null || true)"
  python3 - "$j" <<'PY' 2>/dev/null || echo 100
import sys, json
try:
    d = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
    print(round(float(d.get("pct_pixels_differing", 100)), 2))
except Exception:
    print(100)
PY
}

ensure_injector
ts() { date +%Y%m%d_%H%M%S; }

case "$MODE" in
  one)
    out="${OUT:-$OUTDIR/${NAME}_$(ts).ss}"
    echo "[capture] one savestate (slot $SLOT) -> $out"
    capture_one "$out" >/dev/null && echo "  saved $out ($(wc -c < "$out") B)"
    ;;
  every)
    echo "[filmstrip] $COUNT captures, ${EVERY}s apart (slot $SLOT)"
    for n in $(seq 1 "$COUNT"); do
      out="$OUTDIR/${NAME}_$(ts)_$n.ss"
      capture_one "$out" >/dev/null && echo "  [$n/$COUNT] $out"
      [ "$n" -lt "$COUNT" ] && sleep "$EVERY"
    done
    ;;
  watch)
    echo "[watch] screenshot every ${INTERVAL}s; trigger @ ${THRESH}% ${REF:+vs ref $REF}${REF:-(scene change)}; max $MAX, ${MINS}min"
    prev="$OUTDIR/.ss_watch_prev.png"; cur="$OUTDIR/.ss_watch_cur.png"
    baseline="${REF:-$prev}"
    shot "$prev" || { echo "  ! screenshot failed"; exit 1; }
    caps=0; end=$(( $(date +%s) + MINS*60 ))
    while [ "$caps" -lt "$MAX" ] && [ "$(date +%s)" -lt "$end" ]; do
      sleep "$INTERVAL"
      shot "$cur" || continue
      base="${REF:-$prev}"
      d=$(pct_diff "$base" "$cur")
      hit=$(python3 -c "print(1 if float('$d')>=float('$THRESH') else 0)" 2>/dev/null || echo 0)
      printf "  %s  diff=%.1f%%  %s\n" "$(date +%H:%M:%S)" "$d" "$([ "$hit" = 1 ] && echo TRIGGER || echo -)"
      if [ "$hit" = 1 ]; then
        out="$OUTDIR/${NAME}_$(ts).ss"
        capture_one "$out" >/dev/null && { caps=$((caps+1)); echo "    -> [$caps] captured $out"; }
        sleep 2; shot "$prev" || true        # re-baseline after the save-blackout
      else
        [ -z "$REF" ] && cp "$cur" "$prev"     # scene-change: advance baseline
      fi
    done
    echo "[watch] done: $caps savestate(s) captured to $OUTDIR/"
    ;;
esac
