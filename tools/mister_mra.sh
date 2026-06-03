#!/usr/bin/env bash
# =============================================================================
# mister_mra.sh -- package a 573 game as a MiSTer .mra and load it over SSH,
# autonomously (no OSD button-presses).
#
# A MiSTer .mra, when `load_core`d, loads the core's .rbf and then streams its
# <rom index="N"> parts to the core as HPS ioctl_index-N downloads. Our emu.sv
# consumes index 0 = BIOS, 2 = 16 MB onboard flash, 3 = M48T58 NVRAM. So this
# bundles those three files into a zip + .mra and loads it -- the whole game comes
# up from one `load_core`, which is what makes hands-off HW testing possible.
#
# Pairs with tools/mister_filmstrip.sh to watch the boot:
#   tools/mister_mra.sh --film
#
# Usage:
#   tools/mister_mra.sh [--film] [NAME] [BIOS] [FLASH] [NVRAM]
#     NAME   set/zip/mra basename     (default hyperbbc573)
#     BIOS   ioctl 0  (default dumps/bios/573.bin)
#     FLASH  ioctl 2  (default dumps/hyperbbc/flash16m.bin)
#     NVRAM  ioctl 3  (default dumps/hyperbbc/nvram8k.bin)
#   --film   after loading, capture a filmstrip of the boot (mister_filmstrip.sh)
#
# Deploys: rbf -> _Arcade/cores, zip -> games/mame, mra -> _Arcade. Reads
# local/mister.env for the board. The core's .rbf is taken from
# output_files/Konami_System_573.rbf (build/pull it first).
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"

FILM=0; [ "${1:-}" = "--film" ] && { FILM=1; shift; }
NAME="${1:-hyperbbc573}"
BIOS="${2:-$ROOT/dumps/bios/573.bin}"
FLASH="${3:-$ROOT/dumps/hyperbbc/flash16m.bin}"
NVRAM="${4:-$ROOT/dumps/hyperbbc/nvram8k.bin}"
RBF="$ROOT/output_files/Konami_System_573.rbf"
RBFNAME="Konami_System_573"

for f in "$BIOS" "$FLASH" "$NVRAM" "$RBF"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done

if ssh -o ConnectTimeout=6 -o BatchMode=yes mister true 2>/dev/null; then
  SSH=(ssh mister); SCP_HOST=mister
else
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}")
  SCP_HOST="${MISTER_USER:-root}@${MISTER_HOST}"
fi

WD="$(mktemp -d)"; trap 'rm -rf "$WD"' EXIT
cp "$BIOS" "$WD/bios.bin"; cp "$FLASH" "$WD/flash.bin"; cp "$NVRAM" "$WD/nvram.bin"

# CRC32s for the .mra parts (MiSTer verifies parts against the zip).
read -r CB CF CN < <(python3 - "$WD" <<'PY'
import sys, zlib, os
wd = sys.argv[1]
print(*[f"{zlib.crc32(open(os.path.join(wd,f),'rb').read())&0xffffffff:08x}"
        for f in ("bios.bin","flash.bin","nvram.bin")])
PY
)

( cd "$WD" && zip -q -X "$NAME.zip" bios.bin flash.bin nvram.bin )

cat > "$WD/$NAME.mra" <<MRA
<misterromdescription>
	<name>$NAME (System 573, flash)</name>
	<setname>$NAME</setname>
	<rbf>$RBFNAME</rbf>
	<rom index="0" zip="$NAME.zip"><part name="bios.bin" crc="$CB"/></rom>
	<rom index="2" zip="$NAME.zip"><part name="flash.bin" crc="$CF"/></rom>
	<rom index="3" zip="$NAME.zip"><part name="nvram.bin" crc="$CN"/></rom>
</misterromdescription>
MRA

echo "== deploy ($NAME): rbf -> _Arcade/cores, zip -> games/mame, mra -> _Arcade =="
scp -q "$RBF"           "$SCP_HOST:/media/fat/_Arcade/cores/$RBFNAME.rbf"
scp -q "$WD/$NAME.zip"  "$SCP_HOST:/media/fat/games/mame/$NAME.zip"
scp -q "$WD/$NAME.mra"  "$SCP_HOST:/media/fat/_Arcade/$NAME.mra"

echo "== load_core /media/fat/_Arcade/$NAME.mra (BIOS+flash+NVRAM auto-load) =="
"${SSH[@]}" "echo 'load_core /media/fat/_Arcade/$NAME.mra' > /dev/MiSTer_cmd && echo loaded" 2>/dev/null

if [ "$FILM" = "1" ]; then
  echo "== filming the boot =="
  "$HERE/mister_filmstrip.sh" 16 3 "${NAME}_boot"
fi
echo "Done. (Watch the boot: tools/mister_filmstrip.sh)"
