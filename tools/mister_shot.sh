#!/usr/bin/env bash
# =============================================================================
# mister_shot.sh -- pull the newest MiSTer screenshot back to the Mac to inspect.
#
# MiSTer saves screenshots (user hotkey, default F12 / the OSD "Screenshot") to
# /media/fat/screenshots/<Core>/<timestamp>.png. This script tries to trigger a
# screenshot over the command pipe (best-effort; not all MiSTer builds accept
# it), waits, then scp's the newest PNG under the screenshots dir into ./local/.
#
# Usage:  tools/mister_shot.sh [out.png]
# If no new screenshot appears, take one on the board (screenshot hotkey) and
# re-run -- it grabs the newest file regardless of how it was triggered.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"
SHOT_DIR="${MISTER_SHOT_DIR:-/media/fat/screenshots}"
OUT="${1:-$ROOT/local/mister_shot_$(date +%s 2>/dev/null || echo latest).png}"
mkdir -p "$(dirname "$OUT")"

# CAPTURE-CARD FIRST (cockpit's silent HDMI tap; never pokes the MiSTer): for a carded
# board, grab_card.sh decodes the live HLS feed to a FRESH PNG. It exits non-zero when
# the board isn't carded / the daemon is down / the de10 is dark -> we fall back to the
# MiSTer screenshot path below. The board KEY (e.g. de10) is the testsources key, default
# = MISTER_ALIAS. See memory/de10-vram-observability-broken.md (RESOLVED). The capture
# daemon runs ONLY from a camera-permissioned Terminal (NOT here); grab_card just reads it.
BOARD="${MISTER_BOARD:-${MISTER_ALIAS:-mister}}"
GRAB_CARD="${HUB:-$HOME/Dev/mister-dev-hub}/tools/grab_card.sh"
if [ -x "$GRAB_CARD" ]; then
  if card_png="$("$GRAB_CARD" "$BOARD" 2>/dev/null)" && [ -n "$card_png" ] && [ -f "$card_png" ]; then
    cp "$card_png" "$OUT"
    echo "== capture-card grab ($BOARD) -> $OUT ($(wc -c < "$OUT") bytes) =="
    exit 0
  fi
  echo "== no live capture-card feed for '$BOARD' (grab_card non-zero) -- falling back to MiSTer screenshot ==" >&2
fi

SSH=(ssh "${MISTER_ALIAS:-mister}")
ssh -o ConnectTimeout=5 -o BatchMode=yes "${MISTER_ALIAS:-mister}" true 2>/dev/null || {
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}"); }

echo "== requesting screenshot (best-effort) =="
"${SSH[@]}" "echo screenshot > /dev/MiSTer_cmd 2>/dev/null || true; sleep 2"

newest="$("${SSH[@]}" "ls -t $SHOT_DIR/*/*.png $SHOT_DIR/*.png 2>/dev/null | head -1")"
if [ -z "$newest" ]; then
  echo "No screenshot found under $SHOT_DIR." >&2
  echo "Take one on the board (screenshot hotkey / OSD), then re-run this script." >&2
  exit 2
fi
echo "== newest: $newest -> $OUT =="
"${SSH[@]}" "cat '$newest'" > "$OUT"
echo "Saved $OUT ($(wc -c < "$OUT") bytes). Open it to inspect the boot screen."
