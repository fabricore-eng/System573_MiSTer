#!/usr/bin/env bash
# =============================================================================
# mister_load.sh -- scp the built .rbf to the MiSTer and load it over SSH.
#
# Reads local/mister.env (git-ignored) for the board: MISTER_HOST/USER/SSH_KEY,
# MISTER_CORE_DIR, CORE_RBF. Uses the `ssh mister` alias if no key/host given.
#
# Usage:  tools/mister_load.sh [path/to/core.rbf]
#   default .rbf: output_files/$CORE_RBF (the Quartus build output).
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

RBF="${1:-$ROOT/output_files/${CORE_RBF:-Konami_System_573.rbf}}"
[ -f "$RBF" ] || { echo "error: .rbf not found: $RBF (build it first -- see docs/PHASE4_HARDWARE.md)" >&2; exit 1; }

CORE_DIR="${MISTER_CORE_DIR:-/media/fat/_Arcade}"
DEST="$CORE_DIR/$(basename "$RBF")"

# Prefer the `ssh mister` alias (key + host from ~/.ssh/config); fall back to env.
if ssh -o ConnectTimeout=5 -o BatchMode=yes "${MISTER_ALIAS:-mister}" true 2>/dev/null; then
  SSH=(ssh "${MISTER_ALIAS:-mister}"); SCP_TGT="${MISTER_ALIAS:-mister}"
else
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}")
  SCP_TGT="-i $KEY ${MISTER_USER:-root}@${MISTER_HOST}"
fi

echo "== scp $(basename "$RBF") -> $DEST =="
scp ${SSH[*]:1} 2>/dev/null "$RBF" "mister:$DEST" 2>/dev/null \
  || scp $SCP_TGT "$RBF" "$SCP_TGT:$DEST" 2>/dev/null \
  || { "${SSH[@]}" "cat > '$DEST'" < "$RBF"; }

echo "== load_core $DEST =="
"${SSH[@]}" "echo 'load_core $DEST' > /dev/MiSTer_cmd && echo loaded"
echo "Loaded. Give it a few seconds to boot, then: tools/mister_shot.sh"
