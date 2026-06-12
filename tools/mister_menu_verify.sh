#!/usr/bin/env bash
# =============================================================================
# mister_menu_verify.sh -- ONE-COMMAND objective garble verdict, no human.
#
# The established 573 debug workflow (the human's spec, 2026-06-09):
#   load the core on the board -> wait through self-tests into attract ->
#   headlessly press TEST (R) -> the operator MAIN MENU appears (STATIC =
#   the scene of record; its text is drawn by the same 320 CLUT-row-491 quads
#   that garble) -> screenshot -> frame_diff against the clean MAME menu
#   reference -> print the NUMBERS and a MATCH/MISMATCH verdict.
#
# The MAME half of the comparison already exists: tools/mame_main_menu.lua
# produced local/mame_service/05_main_menu.png (boot -> attract -> test btn).
#
# Verdict semantics:
#   MATCH    (SSIM>=0.95, %diff<=2)  -> the menu renders clean = garble FIXED.
#   MISMATCH                         -> garble (or another render bug) present.
#   Known garbled baselines for context: DE10 SSIM~0.69 / SS SSIM~0.71 vs MAME.
#
# Usage:
#   tools/mister_menu_verify.sh [HOST] [REF_PNG]
#     HOST     ssh alias of the board (default: de10)
#     REF_PNG  reference frame (default: local/mame_service/05_main_menu.png)
#   Env:
#     SKIP_REBOOT=1   skip the warm reboot (NOT de-confounded; default reboots
#                     via the hub devlock tool, project key 573)
#     BOOT_WAIT=90    seconds from load_core to the TEST press
#
# Exit: 0 on MATCH, 1 on MISMATCH, 2 on harness failure (no static menu etc).
# Requires: tools/mister_press.sh (the headless TEST-press primitive).
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
HOST="${1:-de10}"
REF="${2:-$ROOT/local/mame_service/05_main_menu.png}"
BOOT_WAIT="${BOOT_WAIT:-90}"
HUB_COORD="$HOME/Dev/mister-dev-hub/tools/dell_coord.sh"
FRAME_DIFF="$HOME/Dev/mister-dev-hub/tools/frame_diff.py"
MRA="/media/fat/_Arcade/hyperbbc573.mra"
SHOTDIR="/media/fat/screenshots/hyperbbc573"
OUT="$ROOT/local/verify_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$OUT"

[ -f "$REF" ] || { echo "error: reference frame not found: $REF" >&2; exit 2; }
[ -x "$HERE/mister_press.sh" ] || { echo "error: tools/mister_press.sh missing (the headless TEST-press primitive)" >&2; exit 2; }

say() { echo "[verify] $*"; }

# --- 1. de-confounded warm reboot (hub devlock protocol; reboot wipes the lock) ---
if [ "${SKIP_REBOOT:-0}" != "1" ]; then
  say "warm-rebooting $HOST via hub devlock (de-confounded protocol)"
  "$HUB_COORD" devlock "$HOST" reboot 573
  sleep 45
  for i in $(seq 1 12); do
    ssh -o ConnectTimeout=4 "$HOST" true 2>/dev/null && break
    [ "$i" = 12 ] && { echo "error: $HOST did not come back after reboot" >&2; exit 2; }
    sleep 10
  done
  "$HUB_COORD" devlock "$HOST" acquire 573 || true
  UP=$(ssh "$HOST" 'cut -d. -f1 /proc/uptime')
  say "board back, uptime ${UP}s"
fi

# --- 2. ONE load_core, wait into attract ---
say "load_core $MRA; waiting ${BOOT_WAIT}s through self-tests"
ssh "$HOST" "echo 'load_core $MRA' > /dev/MiSTer_cmd"
sleep "$BOOT_WAIT"

# --- 3. headless TEST press -> menu (retry once: a press can land mid-transition) ---
for attempt in 1 2; do
  say "pressing TEST (attempt $attempt)"
  # NB: mister_press.sh targets the de10 alias internally (its [extra args] are
  # --hold/--pre/--post passthroughs, NOT a host)
  "$HERE/mister_press.sh" test
  sleep 4
  ssh "$HOST" "rm -f $SHOTDIR/*.png 2>/dev/null; echo screenshot > /dev/MiSTer_cmd; sleep 4; echo screenshot > /dev/MiSTer_cmd; sleep 2"
  # static test: the two shots must be byte-identical (attract never is, 4s apart)
  if ssh "$HOST" "cd $SHOTDIR && a=\$(ls -t *.png | sed -n 2p) && b=\$(ls -t *.png | sed -n 1p) && cmp -s \"\$a\" \"\$b\""; then
    say "static screen confirmed"
    break
  fi
  [ "$attempt" = 2 ] && { echo "error: no static menu after 2 TEST presses" >&2; exit 2; }
  sleep 6
done

# --- 4. pull the frame ---
scp -q "$HOST:$SHOTDIR/$(ssh "$HOST" "ls -t $SHOTDIR | head -1")" "$OUT/menu.png"
say "menu frame -> $OUT/menu.png"

# --- 5. the NUMBER ---
say "frame_diff vs $(basename "$REF")"
python3 "$FRAME_DIFF" "$REF" "$OUT/menu.png" | tee "$OUT/frame_diff.txt"
if grep -q 'VERDICT: MATCH' "$OUT/frame_diff.txt"; then
  say "VERDICT: MATCH — menu renders clean (garble not present)"
  exit 0
else
  say "VERDICT: MISMATCH — garble (or another render divergence) present; see $OUT"
  exit 1
fi
