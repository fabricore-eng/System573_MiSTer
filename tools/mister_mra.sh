#!/usr/bin/env bash
# =============================================================================
# mister_mra.sh -- package a 573 game as a MiSTer .mra and load it over SSH,
# autonomously (no OSD button-presses).
#
# A MiSTer .mra, when `load_core`d, loads the core's .rbf and then streams its
# <rom index="N"> parts to the core as HPS ioctl_index-N downloads. Our emu.sv
# consumes index 0 = BIOS, 2 = 16 MB onboard flash, 3 = M48T58 NVRAM,
# 4 = security-cart EEPROM (.u1: X76F041/X76F100/ZS01), 5 = DS2401 serial (.u6).
# So this bundles those files into a zip + .mra and loads it -- the whole game
# comes up from one `load_core`, which is what makes hands-off HW testing possible.
#
# The security-cart parts (4/5) are OPTIONAL: a flash-only game (hyperbbc) omits
# them; a security game (pnchmn2 = X76F041, gtrfrk5m = ZS01) passes them via
# --eeprom / --serial (or env EEPROM=/SERIAL=). The core infers the cart type from the
# .u1 SIZE (112 = X76F100, 548 = X76F041, 4116 = ZS01).
#
# Pairs with tools/mister_filmstrip.sh to watch the boot:
#   tools/mister_mra.sh --film
#
# Usage:
#   tools/mister_mra.sh [--film] [--eeprom FILE] [--serial FILE] \
#                       [NAME] [BIOS] [FLASH] [NVRAM]
#     NAME    set/zip/mra basename    (default hyperbbc573)
#     BIOS    ioctl 0  (default dumps/bios/573.bin)
#     FLASH   ioctl 2  (default dumps/hyperbbc/flash16m.bin)
#     NVRAM   ioctl 3  (default dumps/hyperbbc/nvram8k.bin)
#     --eeprom FILE   ioctl 4  security EEPROM .u1 (optional)
#     --serial FILE   ioctl 5  DS2401 serial .u6  (optional)
#   --film    after loading, capture a filmstrip of the boot (mister_filmstrip.sh)
#
#   pnchmn2 example (after `python3 tools/pack_pnchmn2.py`):
#     tools/mister_mra.sh --eeprom dumps/pnchmn2/eeprom.u1 \
#       --serial dumps/pnchmn2/serial.u6 pnchmn2_573 dumps/bios/573.bin \
#       dumps/pnchmn2/flash16m.bin dumps/hyperbbc/nvram8k.bin
#
#   gtrfrk5m ZS01 example (after `python3 tools/pack_gtrfrk5m.py`):
#     tools/mister_mra.sh --eeprom dumps/gtrfrk5m/eeprom.u1 \
#       --serial dumps/gtrfrk5m/serial.u6 gtrfrk5m_573 dumps/bios/573.bin \
#       dumps/gtrfrk5m/flash16m.bin dumps/hyperbbc/nvram8k.bin
#
# Deploys: rbf -> _Arcade/cores, zip -> games/mame, mra -> _Arcade. Reads
# local/mister.env for the board. The core's .rbf is taken from
# output_files/Konami_System_573.rbf (build/pull it first).
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/local/mister.env"; [ -f "$ENVF" ] && . "$ENVF"

FILM=0
EEPROM="${EEPROM:-}"; SERIAL="${SERIAL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --film)   FILM=1; shift ;;
    --eeprom) EEPROM="$2"; shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    *) break ;;
  esac
done
NAME="${1:-hyperbbc573}"
BIOS="${2:-$ROOT/dumps/bios/573.bin}"
FLASH="${3:-$ROOT/dumps/hyperbbc/flash16m.bin}"
NVRAM="${4:-$ROOT/dumps/hyperbbc/nvram8k.bin}"
RBF="$ROOT/output_files/Konami_System_573.rbf"
RBFNAME="Konami_System_573"

for f in "$BIOS" "$FLASH" "$NVRAM" "$RBF"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done
[ -n "$EEPROM" ] && { [ -f "$EEPROM" ] || { echo "error: missing eeprom $EEPROM" >&2; exit 1; }; }
[ -n "$SERIAL" ] && { [ -f "$SERIAL" ] || { echo "error: missing serial $SERIAL" >&2; exit 1; }; }

if ssh -o ConnectTimeout=6 -o BatchMode=yes "${MISTER_ALIAS:-mister}" true 2>/dev/null; then
  SSH=(ssh "${MISTER_ALIAS:-mister}"); SCP_HOST="${MISTER_ALIAS:-mister}"
else
  KEY="${MISTER_SSH_KEY:-~/.ssh/mister_crt}"; KEY="${KEY/#\~/$HOME}"
  SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "${MISTER_USER:-root}@${MISTER_HOST:?set MISTER_HOST}")
  SCP_HOST="${MISTER_USER:-root}@${MISTER_HOST}"
fi

WD="$(mktemp -d)"; trap 'rm -rf "$WD"' EXIT
cp "$BIOS" "$WD/bios.bin"; cp "$FLASH" "$WD/flash.bin"; cp "$NVRAM" "$WD/nvram.bin"
ZIPFILES="bios.bin flash.bin nvram.bin"
SEC_ROWS=""
if [ -n "$EEPROM" ]; then cp "$EEPROM" "$WD/eeprom.u1"; ZIPFILES="$ZIPFILES eeprom.u1"; fi
if [ -n "$SERIAL" ]; then cp "$SERIAL" "$WD/serial.u6"; ZIPFILES="$ZIPFILES serial.u6"; fi

# CRC32s for the .mra parts (MiSTer verifies parts against the zip).
crc32() { python3 - "$1" <<'PY'
import sys, zlib
print(f"{zlib.crc32(open(sys.argv[1],'rb').read())&0xffffffff:08x}")
PY
}
CB="$(crc32 "$WD/bios.bin")"; CF="$(crc32 "$WD/flash.bin")"; CN="$(crc32 "$WD/nvram.bin")"

( cd "$WD" && zip -q -X "$NAME.zip" $ZIPFILES )

if [ -n "$EEPROM" ]; then
  CE="$(crc32 "$WD/eeprom.u1")"
  SEC_ROWS="$SEC_ROWS	<rom index=\"4\" zip=\"$NAME.zip\"><part name=\"eeprom.u1\" crc=\"$CE\"/></rom>
"
fi
if [ -n "$SERIAL" ]; then
  CS="$(crc32 "$WD/serial.u6")"
  SEC_ROWS="$SEC_ROWS	<rom index=\"5\" zip=\"$NAME.zip\"><part name=\"serial.u6\" crc=\"$CS\"/></rom>
"
fi

cat > "$WD/$NAME.mra" <<MRA
<misterromdescription>
	<name>$NAME (System 573, flash)</name>
	<setname>$NAME</setname>
	<rbf>$RBFNAME</rbf>
	<rom index="0" zip="$NAME.zip"><part name="bios.bin" crc="$CB"/></rom>
	<rom index="2" zip="$NAME.zip"><part name="flash.bin" crc="$CF"/></rom>
	<rom index="3" zip="$NAME.zip"><part name="nvram.bin" crc="$CN"/></rom>
	<nvram index="3" size="8192"/>
${SEC_ROWS}</misterromdescription>
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
