#!/usr/bin/env bash
# mister_deploy_console.sh -- deploy the 573 as a STANDALONE CONSOLE core (+ .mgl launchers)
#
# Why a console core (not the arcade .mra): a CD-installer game must be launched with its
# CD MOUNTED. The locked arcade .mra path (is_arcade_type=1) blocks the mount; a .mgl /
# console launch (is_arcade_type=0) mounts the S1 (CUECHD) slot normally. See
# mgl/*.mgl and the research in MEMORY (573-library-roadmap).
#
# Places:
#   _Console/Konami_System_573.rbf      <- the built core (so .mgl <rbf>_Console/...> resolves)
#   _Console/*.mgl                      <- the launchers (mgl/hyperbbc_console.mgl etc.)
#   games/System573/flash16m_blank.bin  <- blank (0xFF) 16 MB flash for installer games
#   games/System573/nvram8k_blank.bin   <- blank (0xFF) 8 KB NVRAM
# (573bios.bin + the game .chd are assumed already staged under games/System573/.)
#
# Usage: tools/mister_deploy_console.sh [path/to/Konami_System_573.rbf]
#   default rbf: output_files/Konami_System_573.rbf (fetch it from dell first, e.g.
#   scp dell:System573_MiSTer/output_files/Konami_System_573.rbf output_files/).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RBF="${1:-$ROOT/output_files/Konami_System_573.rbf}"
HOST="${MISTER_HOST:-mister}"
GAMES=/media/fat/games/System573
CONSOLE=/media/fat/_Console

ssh "$HOST" "mkdir -p $GAMES $CONSOLE"

# blank (0xFF = erased NOR) images: generated, not committed (a 16 MB 0xFF blob).
mkdir -p "$ROOT/dumps/hyperbbc"
[ -f "$ROOT/dumps/hyperbbc/flash16m_blank.bin" ] || \
  python3 -c "open('$ROOT/dumps/hyperbbc/flash16m_blank.bin','wb').write(b'\xff'*0x1000000)"
[ -f "$ROOT/dumps/hyperbbc/nvram8k_blank.bin" ] || \
  python3 -c "open('$ROOT/dumps/hyperbbc/nvram8k_blank.bin','wb').write(b'\xff'*0x2000)"

# blank images (build-independent; safe to re-push)
echo "== staging blank flash + nvram =="
scp "$ROOT/dumps/hyperbbc/flash16m_blank.bin" "$HOST:$GAMES/flash16m_blank.bin"
scp "$ROOT/dumps/hyperbbc/nvram8k_blank.bin"  "$HOST:$GAMES/nvram8k_blank.bin"

# .mgl launchers
echo "== staging .mgl launchers -> $CONSOLE =="
scp "$ROOT/mgl/hyperbbc_console.mgl"  "$HOST:$CONSOLE/hyperbbc (573, console).mgl"
scp "$ROOT/mgl/hypbbc2p_console.mgl"  "$HOST:$CONSOLE/Hyper Bishi Bashi Champ 2P (573).mgl"

# the core itself (last, so a launcher never points at a stale/absent rbf)
if [ -f "$RBF" ]; then
  echo "== deploying core -> $CONSOLE/Konami_System_573.rbf =="
  scp "$RBF" "$HOST:$CONSOLE/Konami_System_573.rbf"
else
  echo "!! rbf not found: $RBF -- staged images+mgls only; deploy the rbf when the build lands:" >&2
  echo "   scp dell:System573_MiSTer/output_files/Konami_System_573.rbf $ROOT/output_files/ && $0" >&2
fi
echo "== done. De-confounded test: warm-reboot the MiSTer, /proc/uptime<60s, then ONE launch via the .mgl. =="
