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

SSH=(ssh mister)
ssh -o ConnectTimeout=5 -o BatchMode=yes mister true 2>/dev/null || {
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_id_ed25519}"; KEY="${KEY/#\~/$HOME}"
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
