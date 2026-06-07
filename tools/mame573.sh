#!/usr/bin/env bash
# =============================================================================
# mame573.sh -- run REFERENCE MAME (hyperbbc) HEADLESS on the dell box.
#
# WHY: MAME on the Mac steals input/focus and competes with the human's own use of
# the workstation; dell is a headless server (no GUI to interrupt) and already
# the shared build box. This keeps the reference-emulator oracle OFF the Mac.
#
# SETUP (done 2026-06-06): dell has MAME 0.285 (apt) + the dumps at
# dell:~/System573_MiSTer/dumps/{mame573/hyperbbc.zip, sys573.zip}. 0.285 loads
# the hyperbbc romset identically to the Mac's 0.288 (only the no-dump H8 MCU is
# missing, same as our core) and the lua GPU/VRAM API (:gpu, items['0/p_vram'],
# install_write_tap) is unchanged from 0.288, so our forensics lua ports as-is.
#
# Usage:
#   tools/mame573.sh <local_lua> <emulated_seconds> [remote_/tmp_outfile ...]
#     - scp's <local_lua> to dell:/tmp, runs MAME headless for <emulated_seconds>,
#       then pulls each named /tmp/<outfile> back into ./local/.
# Example:
#   tools/mame573.sh /tmp/cap.lua 6 dell_vram.bin gp0log.txt
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
LUA="${1:?usage: mame573.sh <local_lua> <seconds> [outfiles...]}"
SECS="${2:-6}"; shift 2 || true
[ -f "$LUA" ] || { echo "error: lua not found: $LUA" >&2; exit 1; }

RL="/tmp/mame573_$(basename "$LUA")"
scp -q "$LUA" "dell:$RL"
echo "== MAME (dell, headless): hyperbbc, ${SECS}s, $(basename "$LUA") =="
ssh dell "cd ~/System573_MiSTer && timeout $((SECS*20+60)) mame hyperbbc \
  -rompath 'dumps/mame573;dumps' -skip_gameinfo -video none -sound none \
  -seconds_to_run $SECS -autoboot_script '$RL' 2>&1 | grep -vE 'ALSA|seq_hw|snd_seq'"

mkdir -p "$ROOT/local"
for f in "$@"; do
  if scp -q "dell:/tmp/$f" "$ROOT/local/$f" 2>/dev/null; then
    echo "pulled -> local/$f ($(wc -c < "$ROOT/local/$f") bytes)"
  else
    echo "WARN: dell:/tmp/$f not produced" >&2
  fi
done
