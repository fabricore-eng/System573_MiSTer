#!/usr/bin/env bash
# =============================================================================
# mister_boot573.sh -- first-boot bring-up of the Konami System 573 core.
#
# Our emu.sv is a clone of the PSX_MiSTer core, so it identifies as "PSX" in its
# CONF_STR and auto-loads its BIOS from the MiSTer console convention path
# /media/fat/games/PSX/boot.rom at HPS ioctl_index 0 (emu.sv: bios_download <=
# ioctl_index[5:0]==0). To boot the Konami 573 BIOS we therefore TEMPORARILY
# place a 573 BIOS at that path. The board already has a real PlayStation BIOS
# there, so this script backs it up first and restores it on `--restore`.
#
# First boot target: gchgchmp (700a01(gchgchmp).22g) -- a game-in-BIOS that
# needs no CD and no security cart (see docs/PHASE4_HARDWARE.md).
#
# Usage:
#   tools/mister_boot573.sh [path/to/core.rbf] [path/to/bios]   # swap BIOS, load core
#   tools/mister_boot573.sh --restore                           # restore the real PSX BIOS
#   tools/mister_boot573.sh --shot [out.png]                    # just pull a screenshot
#
# Defaults: .rbf = output_files/Konami_System_573.rbf
#           bios = dumps/bios/700a01(gchgchmp).22g
# Reads local/mister.env (git-ignored) for the board if `ssh mister` is unset.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"

PSX_DIR="/media/fat/games/PSX"
BOOT="$PSX_DIR/boot.rom"
BAK="$PSX_DIR/boot.rom.real-psx.bak"     # backup of the genuine PlayStation BIOS
SHOT_DIR="${MISTER_SHOT_DIR:-/media/fat/screenshots}"

# Prefer the `ssh mister` alias; fall back to env (key + host).
if ssh -o ConnectTimeout=6 -o BatchMode=yes "${MISTER_ALIAS:-mister}" true 2>/dev/null; then
  SSH=(ssh "${MISTER_ALIAS:-mister}"); SCP_PFX="${MISTER_ALIAS:-mister}:"
else
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_id_ed25519}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}")
  SCP_PFX="${MISTER_USER:-root}@${MISTER_HOST}:"
fi
sshq() { "${SSH[@]}" "$@" 2>/dev/null; }
push() { # local-file remote-path  (scp with cat fallback)
  scp -q "$1" "${SCP_PFX}$2" 2>/dev/null || sshq "cat > '$2'" < "$1"; }

pull_shot() {
  local out="${1:-$ROOT/local/mister_573_$(date +%s 2>/dev/null || echo latest).png}"
  mkdir -p "$(dirname "$out")"
  sshq "echo screenshot > /dev/MiSTer_cmd 2>/dev/null || true; sleep 2"
  local newest; newest="$(sshq "ls -t $SHOT_DIR/*/*.png $SHOT_DIR/*.png 2>/dev/null | head -1")"
  [ -n "$newest" ] || { echo "No screenshot yet under $SHOT_DIR. Take one on the board and re-run --shot." >&2; return 2; }
  sshq "cat '$newest'" > "$out"
  echo "Saved $out ($(wc -c < "$out") bytes)."
}

case "${1:-}" in
  --restore)
    if sshq "test -f '$BAK'"; then
      sshq "cp -f '$BAK' '$BOOT' && rm -f '$BAK' && echo restored"
      echo "Restored the real PlayStation BIOS to $BOOT."
    else
      echo "No backup at $BAK -- nothing to restore (did you run a swap?)." >&2; exit 1
    fi
    exit 0 ;;
  --shot)
    pull_shot "${2:-}"; exit $? ;;
esac

RBF="${1:-$ROOT/output_files/Konami_System_573.rbf}"
BIOS="${2:-$ROOT/dumps/bios/700a01(gchgchmp).22g}"
[ -f "$RBF" ]  || { echo "error: .rbf not found: $RBF (build it first)" >&2; exit 1; }
[ -f "$BIOS" ] || { echo "error: BIOS not found: $BIOS" >&2; exit 1; }

echo "== back up the real PSX BIOS (once) =="
sshq "test -f '$BAK' || cp -f '$BOOT' '$BAK'; ls -l '$BAK' '$BOOT'"

echo "== install 573 BIOS as $BOOT =="
push "$BIOS" "$BOOT"
sshq "md5sum '$BOOT'"

DEST="/media/fat/_Console/$(basename "$RBF")"
echo "== scp $(basename "$RBF") -> $DEST =="
sshq "mkdir -p /media/fat/_Console"
push "$RBF" "$DEST"

echo "== load_core $DEST =="
sshq "echo 'load_core $DEST' > /dev/MiSTer_cmd && echo loaded"
echo "Core loading -- the 573 BIOS auto-loads at index 0. Give it a few seconds."
echo "Then:  tools/mister_boot573.sh --shot      (grab the boot screen)"
echo "After: tools/mister_boot573.sh --restore   (put the real PSX BIOS back)"
