#!/usr/bin/env bash
# =============================================================================
# play_ddrsbm_mac.sh -- run DDR Solo Bass Mix in MAME ON THE MAC, windowed, so
# the behaviour can be judged by eye and ear instead of by my measurements.
#
# The hub's other MAME tooling deliberately runs HEADLESS ON DELL (it steals
# focus and competes with the workstation). This one is the opposite on purpose:
# it is for a human to sit in front of.
#
# WHY THE EXPLICIT -nvram_directory: MAME's `nvram_directory` default is the
# RELATIVE path `nvram`, resolved against the working directory -- so without
# this the installed flash is silently ignored and the game boots to
# "DO YOU WANT TO INITIALIZE FLASH-ROM?" instead of the game. (dell's Ubuntu
# build defaults to $HOME/.mame/nvram, which is why this only bites on the Mac.)
# ~/.mame/nvram/ddrsbm holds a REAL completed install; ddrsbm.golden is a backup
# of it -- if a session ever corrupts the flash, restore from that rather than
# sitting through the ~16 minute installer again.
#
# Usage:  tools/play_ddrsbm_mac.sh            # play it
#         tools/play_ddrsbm_mac.sh -restore   # put the golden nvram back first
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NVRAM="$HOME/.mame/nvram"
GOLDEN="$NVRAM/ddrsbm.golden"

if [ "${1:-}" = "-restore" ]; then
  [ -d "$GOLDEN" ] || { echo "no golden nvram at $GOLDEN" >&2; exit 1; }
  rm -rf "$NVRAM/ddrsbm"
  cp -a "$GOLDEN" "$NVRAM/ddrsbm"
  echo "restored the installed flash from $GOLDEN"
  shift || true
fi

command -v mame >/dev/null || { echo "mame not on PATH" >&2; exit 1; }

exec mame ddrsbm \
  -rompath   "$ROOT/dumps/mame573;$ROOT/dumps;$ROOT/dumps/mame573/ddrsbm" \
  -nvram_directory "$NVRAM" \
  -skip_gameinfo -window -resolution 960x720 \
  "$@"
