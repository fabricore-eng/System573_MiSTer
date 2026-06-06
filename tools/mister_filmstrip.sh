#!/usr/bin/env bash
# =============================================================================
# mister_filmstrip.sh -- capture a BURST of MiSTer screenshots over time.
#
# A single screenshot rarely catches what matters (boot POST sequences, a
# flashing "HARDWARE ERROR" loop, a game's attract loop). This triggers the
# MiSTer `screenshot` command N times at a fixed interval and pulls every frame
# back to local/, numbered in capture order, so the whole sequence is visible.
#
# Usage:
#   tools/mister_filmstrip.sh [COUNT] [INTERVAL_SEC] [PREFIX]
#     COUNT        number of frames           (default 12)
#     INTERVAL_SEC seconds between frames      (default 3)
#     PREFIX       local/<PREFIX>_NN.png       (default film)
#
# Frames land in local/<PREFIX>_01.png (earliest) .. _NN.png (latest).
# Reads local/mister.env (git-ignored) for the board if `ssh mister` is unset.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"

N="${1:-12}"; IVAL="${2:-3}"; PREFIX="${3:-film}"
SHOT_DIR="${MISTER_SHOT_DIR:-/media/fat/screenshots}"
OUT="$ROOT/local"; mkdir -p "$OUT"

# Prefer the `ssh mister` alias; fall back to env (key + host).
if ssh -o ConnectTimeout=6 -o BatchMode=yes mister true 2>/dev/null; then
  SSH=(ssh mister)
else
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}")
fi

echo "Capturing $N frames every ${IVAL}s (~$((N * IVAL))s total)..."

# One SSH session does the whole burst: trigger a screenshot, wait (the PNG takes
# ~1-2s to write AND this spaces the frames), copy the newest PNG into a temp dir
# numbered in order; finally tar the temp dir to stdout. We untar locally.
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
"${SSH[@]}" "
  d=/tmp/mister_filmstrip; rm -rf \$d; mkdir -p \$d
  for i in \$(seq 1 $N); do
    echo screenshot > /dev/MiSTer_cmd 2>/dev/null || true
    sleep $IVAL
    f=\$(ls -t $SHOT_DIR/*/*.png $SHOT_DIR/*.png 2>/dev/null | head -1)
    [ -n \"\$f\" ] && cp \"\$f\" \"\$d/\$(printf %02d \$i).png\"
  done
  tar -C \$d -cf - . 2>/dev/null
" | tar -C "$tmpd" -xf - 2>/dev/null || true

i=0
for f in "$tmpd"/*.png; do
  [ -e "$f" ] || continue
  i=$((i+1))
  out="$(printf '%s/%s_%02d.png' "$OUT" "$PREFIX" "$i")"
  cp "$f" "$out"
done
echo "Pulled $i frames -> $OUT/${PREFIX}_01.png .. ${PREFIX}_$(printf %02d "$i").png"
[ "$i" -gt 0 ] || { echo "No frames captured (is a core running + the screenshot dir writable?)." >&2; exit 2; }
