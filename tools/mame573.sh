#!/usr/bin/env bash
# =============================================================================
# mame573.sh -- 573-specific thin wrapper over the SHARED hub MAME-on-dell runner
# (~/Dev/mister-dev-hub/tools/mame_dell.sh). Runs reference MAME (hyperbbc)
# HEADLESS on dell, off the Mac (MAME on the Mac steals focus + competes with
# the human's workstation use). Generic runner lives in the hub so every core shares
# it; this just fills in the 573 specifics (romset hyperbbc, our rompath).
#
# dell has MAME 0.285 + the dumps at dell:~/System573_MiSTer/dumps/{mame573/
# hyperbbc.zip, sys573.zip} (0.285 loads the romset identically to the Mac's
# 0.288; the lua GPU/VRAM API is unchanged).
#
# Usage:  tools/mame573.sh <local_lua> <emulated_seconds> [/tmp_outfile ...]
#   -> runs MAME on dell with the lua, pulls each /tmp/<outfile> into ./local/.
# =============================================================================
set -euo pipefail
LUA="${1:?usage: mame573.sh <local_lua> <seconds> [outfiles...]}"; SECS="${2:-6}"; shift 2 || true
HUB="${MISTER_HUB:-$HOME/Dev/mister-dev-hub}/tools/mame_dell.sh"
[ -x "$HUB" ] || { echo "error: hub runner not found/executable: $HUB" >&2; exit 1; }
exec "$HUB" System573_MiSTer hyperbbc "dumps/mame573;dumps" "$LUA" "$SECS" "$@"
