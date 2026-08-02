#!/usr/bin/env bash
# =============================================================================
# mame573.sh -- 573-specific thin wrapper over the SHARED hub MAME-on-dell runner
# (~/Dev/tools/tools/mame_dell.sh). Runs reference MAME (hyperbbc)
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
#
# ROMSET is selectable (2026-07-31): the MP3 work needs ddrsbm as a BEHAVIOURAL
# oracle, not just hyperbbc as a boot reference. Override with MAME573_SET, e.g.
#   MAME573_SET=ddrsbm tools/mame573.sh tools/mame_dio_regs.lua 180 dio_regs.log
# ddrsbm needs its CD (dumps/mame573/ddrsbm/894jaa02.chd) and boots past the
# installer only because dell already holds an installed flash in
# ~/.mame/nvram/ddrsbm/ (29f016a.*) -- do not wipe that, it is the reason the
# oracle reaches gameplay at all.
set -euo pipefail
LUA="${1:?usage: [MAME573_SET=ddrsbm] mame573.sh <local_lua> <seconds> [outfiles...]}"; SECS="${2:-6}"; shift 2 || true
SET="${MAME573_SET:-hyperbbc}"
# The hub lives in the fabricore workspace; the old default (~/Dev/tools) predates it.
HUB="${MISTER_HUB:-$HOME/Dev/fabricore/tools}/tools/mame_dell.sh"
[ -x "$HUB" ] || { echo "error: hub runner not found/executable: $HUB" >&2; exit 1; }
echo "== MAME oracle: romset=$SET, ${SECS}s emulated =="
exec "$HUB" System573_MiSTer "$SET" "dumps/mame573;dumps;dumps/mame573/ddrsbm" "$LUA" "$SECS" "$@"
