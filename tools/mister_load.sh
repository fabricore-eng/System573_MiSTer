#!/usr/bin/env bash
# =============================================================================
# mister_load.sh -- scp the built .rbf to the MiSTer and load it over SSH.
#
# Reads local/mister.env (git-ignored) for the board: MISTER_HOST/USER/SSH_KEY,
# MISTER_CORE_DIR, CORE_RBF. Uses the `ssh mister` alias if no key/host given.
#
# Usage:  tools/mister_load.sh [--with-main [path/to/MiSTer]] [path/to/core.rbf]
#   default .rbf: output_files/$CORE_RBF (the Quartus build output).
#
# --with-main ALSO replaces the MiSTer system binary (Decision A, 2026-07-29: the
# 573's MP3 audio needs HPS-side C, so the core ships a forked Main alongside the
# .rbf). This is deliberately OPT-IN and not part of a routine core load, because
# that binary is SYSTEM-WIDE, not per-core: a bad one takes out the menu for every
# core until you fix it from the SD card. So the script refuses anything that is
# not an ARM ELF, and keeps a one-time MiSTer.orig backup on the board.
#
# Build it first (on dell, where the cross-toolchain image lives):
#   cd ~/Main_MiSTer && ./build_arm.sh
# and confirm our half actually linked:
#   strings bin/MiSTer | grep s573mp3
#
# Loading uses MiSTer's command pipe (/dev/MiSTer_cmd): `load_core <path>`.
# NOTE: the BIOS still has to reach the core. For a PSX-style core the BIOS is
# an HPS index-0 ROM -- deliver it via an .mra or the OSD file picker (see
# docs/PHASE4_HARDWARE.md). This script only places + loads the .rbf.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"
[ -f "$ENVF" ] && . "$ENVF"

WITH_MAIN=0; MAIN_BIN=""
if [ "${1:-}" = "--with-main" ]; then
  WITH_MAIN=1; shift
  case "${1:-}" in -*|"") ;; *) if [ -f "${1}" ] && [ "${1##*.}" != "rbf" ]; then MAIN_BIN="$1"; shift; fi ;; esac
  MAIN_BIN="${MAIN_BIN:-${MISTER_MAIN_BIN:-$HOME/Dev/fabricore/Main_MiSTer/bin/MiSTer}}"
  [ -f "$MAIN_BIN" ] || { echo "error: Main binary not found: $MAIN_BIN (build it: cd ~/Main_MiSTer && ./build_arm.sh)" >&2; exit 1; }
fi

RBF="${1:-$ROOT/output_files/${CORE_RBF:-Konami_System_573.rbf}}"
[ -f "$RBF" ] || { echo "error: .rbf not found: $RBF (build it first -- see docs/PHASE4_HARDWARE.md)" >&2; exit 1; }

CORE_DIR="${MISTER_CORE_DIR:-/media/fat/_Arcade}"
DEST="$CORE_DIR/$(basename "$RBF")"

# Prefer the `ssh mister` alias (key + host from ~/.ssh/config); fall back to env.
if ssh -o ConnectTimeout=5 -o BatchMode=yes "${MISTER_ALIAS:-mister}" true 2>/dev/null; then
  SSH=(ssh "${MISTER_ALIAS:-mister}"); SCP_TGT="${MISTER_ALIAS:-mister}"
else
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_id_ed25519}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}")
  SCP_TGT="-i $KEY ${MISTER_USER:-root}@${MISTER_HOST}"
fi

echo "== scp $(basename "$RBF") -> $DEST =="
scp ${SSH[*]:1} 2>/dev/null "$RBF" "mister:$DEST" 2>/dev/null \
  || scp $SCP_TGT "$RBF" "$SCP_TGT:$DEST" 2>/dev/null \
  || { "${SSH[@]}" "cat > '$DEST'" < "$RBF"; }

# ---- optional: the forked MiSTer system binary -------------------------------
if [ "$WITH_MAIN" = 1 ]; then
  # Refuse anything that is not an ARM 32-bit ELF. Pushing an x86 build (easy to
  # do by accident on the dev Mac) would leave the board with no working menu.
  if ! file "$MAIN_BIN" 2>/dev/null | grep -q 'ELF 32-bit.*ARM'; then
    echo "error: $MAIN_BIN is not an ARM 32-bit ELF -- refusing to install it" >&2
    file "$MAIN_BIN" >&2 || true
    exit 1
  fi
  # Sanity: our service must actually be linked in, or this deploy is a no-op that
  # LOOKS fine (design risk #6 -- a stale binary silently disables MP3).
  if ! strings "$MAIN_BIN" 2>/dev/null | grep -q 's573mp3'; then
    echo "warning: $MAIN_BIN contains no s573mp3 strings -- the 573 MP3 service is NOT in this build" >&2
  fi
  echo "== install MiSTer system binary ($(stat -f%z "$MAIN_BIN" 2>/dev/null || stat -c%s "$MAIN_BIN") bytes) =="
  # one-time backup, then stage + atomic move (never truncate the live binary)
  "${SSH[@]}" "[ -f /media/fat/MiSTer.orig ] || cp -a /media/fat/MiSTer /media/fat/MiSTer.orig; echo 'backup: /media/fat/MiSTer.orig'"
  "${SSH[@]}" "cat > /media/fat/MiSTer.new && chmod +x /media/fat/MiSTer.new && mv -f /media/fat/MiSTer.new /media/fat/MiSTer && echo 'installed /media/fat/MiSTer'" < "$MAIN_BIN"
  # NOTE the revert MUST stage + mv, exactly like the install above. A plain
  # "cp -a MiSTer.orig MiSTer" fails with "Text file busy" because the binary is
  # running -- mv swaps the directory entry, cp writes into the live inode.
  echo "   (revert with: ssh ${MISTER_ALIAS:-mister} \"cp -a /media/fat/MiSTer.orig /media/fat/MiSTer.tmp && mv -f /media/fat/MiSTer.tmp /media/fat/MiSTer\")"
fi

echo "== load_core $DEST =="
"${SSH[@]}" "echo 'load_core $DEST' > /dev/MiSTer_cmd && echo loaded"
echo "Loaded. Give it a few seconds to boot, then: tools/mister_shot.sh"
if [ "$WITH_MAIN" = 1 ]; then
  echo
  echo "The load_core above re-execs Main (fpga_io app_restart), so the NEW binary is"
  echo "now running. Proof the 573 MP3 service is live -- it prints on first poll:"
  echo "   ssh ${MISTER_ALIAS:-mister} 'dmesg | tail; cat /tmp/MiSTer.log 2>/dev/null | grep s573mp3'"
  echo "and the real verdict is the game's 0xa8 frame counter ADVANCING, not this line."
fi
