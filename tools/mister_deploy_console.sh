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
#   games/System573/<game>.u1           <- security cassette (ioctl 4) -- see CASSETTES below
# (573bios.bin + the game .chd are assumed already staged under games/System573/.)
#
# SECURITY CASSETTES (.u1) ARE TREATED LIKE THE BIOS. The AUTHENTIC cassette dump (e.g.
# hypbbc2p's gx908ja.u1, crc 8900eaff) is a copyright-restricted, user-supplied artifact kept
# ONLY under the gitignored dumps/ tree -- NEVER committed. The tracked games/System573/<game>.u1
# is a SYNTHETIC stub (so the repo stays self-contained + copyright-clean) that satisfies the
# in-game X76F100 check but NOT the BIOS boot-signature check (the on-screen "-11N" wall), so it
# must never overwrite a board's authentic cassette and silently re-break the game. This deploy
# therefore (a) PREFERS dumps/games/System573/<game>.u1 over the tracked synthetic, and (b)
# REFUSES to clobber a board .u1 it cannot prove is our own synthetic stub.
# See memory/cassette-data-staging-board-vs-oracle.md + cassette-bootcheck-signature.md.
#
# Usage: tools/mister_deploy_console.sh [--dry-run|-n] [path/to/Konami_System_573.rbf]
#   --dry-run  resolve + print what WOULD be deployed (incl. which .u1 source wins) WITHOUT
#              contacting the board -- use it to confirm the authentic .u1 is selected.
#   default rbf: output_files/Konami_System_573.rbf (fetch it from dell first, e.g.
#   scp dell:System573_MiSTer/output_files/Konami_System_573.rbf output_files/).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DRY=0; RBF=""
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    *)            RBF="$a" ;;
  esac
done
RBF="${RBF:-$ROOT/output_files/Konami_System_573.rbf}"

ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"
HOST="${MISTER_ALIAS:-${MISTER_HOST:-mister}}"
GAMES=/media/fat/games/System573
CONSOLE=/media/fat/_Console

# CD-install / security-cassette titles whose .u1 (ioctl 4) we manage on the board.
# Append a basename here when you wire a new cassette title's .mgl (e.g. a future DDR title);
# each entry no-ops cleanly if it has no source on disk yet. (Region-variant stubs like
# hypbbc2p_kaa.u1 are intentionally NOT listed -- no .mgl references them.)
CASSETTES="hypbbc2p konam80s"

mac_crc32() { python3 -c "import zlib,sys;print('%08x'%(zlib.crc32(open(sys.argv[1],'rb').read())&0xffffffff))" "$1"; }
mac_md5()   { python3 -c "import hashlib,sys;print(hashlib.md5(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }

push() {  # push LOCAL_FILE REMOTE_PATH   (dry-run aware; mirrors the original scp behavior)
  if [ "$DRY" = 1 ]; then echo "DRY-RUN: scp $1 -> $HOST:$2"; else scp "$1" "$HOST:$2"; fi
}

# Resolve + safely deploy one security cassette .u1, BIOS-style:
#   * prefer the authentic dump (dumps/games/System573/<name>.u1) over the tracked synthetic;
#   * skip if the board already holds a byte-identical copy;
#   * REFUSE to overwrite a board cassette that is NOT our synthetic stub (it is probably the
#     authentic dump someone staged by hand) when all we have to push is the synthetic.
deploy_cassette() {
  local name="$1"
  local auth="$ROOT/dumps/games/System573/$name.u1"   # authentic dump (gitignored, like a BIOS)
  local synth="$ROOT/games/System573/$name.u1"          # synthetic stub (tracked, repo-clean)
  local src kind
  if   [ -f "$auth"  ]; then src="$auth";  kind="authentic"
  elif [ -f "$synth" ]; then src="$synth"; kind="SYNTHETIC stub (will NOT pass the BIOS -11N boot check)"
  else
    echo "   $name.u1: no source on disk -- skip (stage the authentic dump as dumps/games/System573/$name.u1 to deploy it)"
    return 0
  fi
  local src_crc; src_crc="$(mac_crc32 "$src")"
  if [ "$DRY" = 1 ]; then
    echo "   $name.u1: would push $kind  src=${src#$ROOT/}  crc=$src_crc"
    return 0
  fi
  local src_md5; src_md5="$(mac_md5 "$src")"
  local board_md5; board_md5="$(ssh "$HOST" "md5sum '$GAMES/$name.u1' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)"
  if [ -n "$board_md5" ] && [ "$board_md5" = "$src_md5" ]; then
    echo "   $name.u1: board already matches $kind (crc=$src_crc) -- skip"
    return 0
  fi
  if [ "$src" = "$synth" ] && [ -n "$board_md5" ]; then
    echo "!! $name.u1: board holds a cassette we did NOT put there (md5 ${board_md5:0:12}...) and all we have is the SYNTHETIC stub." >&2
    echo "   Refusing to overwrite -- it is probably the AUTHENTIC dump. Stage the real .u1 as dumps/games/System573/$name.u1 to manage it from here." >&2
    return 0
  fi
  echo "   $name.u1: pushing $kind (crc=$src_crc)"
  push "$src" "$GAMES/$name.u1"
}

if [ "$DRY" = 1 ]; then
  echo "== DRY-RUN (no board contact); HOST=$HOST =="
else
  ssh "$HOST" "mkdir -p $GAMES $CONSOLE"
fi

# blank (0xFF = erased NOR) images: generated, not committed (a 16 MB 0xFF blob).
# (Skip the local generation under --dry-run so a dry run has no side effects.)
if [ "$DRY" != 1 ]; then
  mkdir -p "$ROOT/dumps/hyperbbc"
  [ -f "$ROOT/dumps/hyperbbc/flash16m_blank.bin" ] || \
    python3 -c "open('$ROOT/dumps/hyperbbc/flash16m_blank.bin','wb').write(b'\xff'*0x1000000)"
  [ -f "$ROOT/dumps/hyperbbc/nvram8k_blank.bin" ] || \
    python3 -c "open('$ROOT/dumps/hyperbbc/nvram8k_blank.bin','wb').write(b'\xff'*0x2000)"
fi

# blank images (build-independent; safe to re-push)
echo "== staging blank flash + nvram =="
push "$ROOT/dumps/hyperbbc/flash16m_blank.bin" "$GAMES/flash16m_blank.bin"
push "$ROOT/dumps/hyperbbc/nvram8k_blank.bin"  "$GAMES/nvram8k_blank.bin"

# security cassettes (.u1, ioctl 4) -- authentic-preferred, never clobbering a real dump
echo "== staging security cassettes (.u1) =="
for c in $CASSETTES; do deploy_cassette "$c"; done

# .mgl launchers
echo "== staging .mgl launchers -> $CONSOLE =="
push "$ROOT/mgl/hyperbbc_console.mgl"  "$CONSOLE/hyperbbc (573, console).mgl"
push "$ROOT/mgl/hypbbc2p_console.mgl"  "$CONSOLE/Hyper Bishi Bashi Champ 2P (573).mgl"

# the core itself (last, so a launcher never points at a stale/absent rbf)
if [ -f "$RBF" ]; then
  echo "== deploying core -> $CONSOLE/Konami_System_573.rbf =="
  push "$RBF" "$CONSOLE/Konami_System_573.rbf"
else
  echo "!! rbf not found: $RBF -- staged images+mgls only; deploy the rbf when the build lands:" >&2
  echo "   scp dell:System573_MiSTer/output_files/Konami_System_573.rbf $ROOT/output_files/ && $0" >&2
fi
echo "== done. De-confounded test: warm-reboot the MiSTer, /proc/uptime<60s, then ONE launch via the .mgl. =="
