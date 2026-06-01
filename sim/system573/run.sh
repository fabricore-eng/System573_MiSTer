#!/usr/bin/env bash
# =============================================================================
# Phase-2 full-system NVC bring-up: analyze + elaborate + run tb_system573.
#
# Builds the patched PSX core (psx work/mem libs, same recipe as
# sim/nvc/elaborate.sh), adds a `tb` library with the upstream pure-VHDL memory
# models (globals/sdram_model3x/ddrram_model/framebuffer), then tb_system573,
# copies the Konami game-in-BIOS image in as s573_bios.bin, and runs under NVC.
#
# Usage:
#   sim/system573/run.sh [STOP_TIME] [RAM8MB]
#     STOP_TIME : NVC --stop-time value (default 2ms)
#     RAM8MB    : '1' (8 MB decode, default) or '0' (2 MB decode)
#
# All build artifacts + sim outputs (.gra, trace logs) land in build/ (gitignored).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"; RTL="$PSX/rtl"; MEMSRC="$PSX/sim/system/src/mem"; TBSRC="$PSX/sim/system/src/tb"
NVCDIR="$ROOT/sim/nvc"
WD="$HERE/build"

STOP_TIME="${1:-2ms}"
RAM8MB="${2:-1}"
# FAST_RAMTEST=1 (default): sim-only BIOS patch that enlarges the 4 MB RAM-test
# stride 4->0x4000 so it walks the full 0xA0000000..0xA0400000 range in 256 steps
# instead of 1,048,576. The test is uncached (KSEG1), so each access costs ~hundreds
# of core cycles regardless of TURBO -- the real test is ~10M+ cycles, untenable to
# simulate. The stride is a power-of-2 dividing the 4 MB range so the loop still
# exits exactly (t1 reaches the end pointer) and still kicks the watchdog. The
# ORIGINAL dump is never touched; only the build/ copy is patched, for bring-up
# only. The Quartus .rbf uses the pristine BIOS. Set FAST_RAMTEST=0 for the real test.
FAST_RAMTEST="${FAST_RAMTEST:-1}"
BIOS_SRC="$ROOT/dumps/bios/700a01(gchgchmp).22g"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -d "$RTL" ] || { echo "error: psx submodule missing. Run: git submodule update --init psx" >&2; exit 1; }
[ -f "$BIOS_SRC" ] || { echo "error: BIOS not found: $BIOS_SRC" >&2; exit 1; }

# Ensure the GPL-isolated psx/ edits (EXP1 widening) are applied.
"$ROOT/tools/apply_psx_patches.sh" >/dev/null

rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"
cp "$BIOS_SRC" "$WD/s573_bios.bin"

if [ "$FAST_RAMTEST" != "0" ]; then
  # Patch BIOS offset 0x450 (the RAM-test stride): addi $t1,$t1,4 (0x21290004 LE)
  # -> addi $t1,$t1,0x4000 (0x21294000 LE). Guarded: only patches if the expected
  # word is present, so it fails loudly on a different BIOS revision.
  python3 - "$WD/s573_bios.bin" <<'PY' || { echo "error: FAST_RAMTEST BIOS patch failed" >&2; exit 1; }
import sys, struct
p = sys.argv[1]; off = 0x450
b = bytearray(open(p, "rb").read())
orig = struct.unpack_from("<I", b, off)[0]
if orig != 0x21290004:
    sys.exit(f"unexpected word 0x{orig:08x} at 0x{off:x}; refusing to patch")
struct.pack_into("<I", b, off, 0x21294000)
open(p, "wb").write(b)
print("FAST_RAMTEST: BIOS RAM-test stride patched 4->0x4000 (sim-only, build/ copy)")
PY
fi

NVC="nvc --std=2008"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }

echo "== analyzing altera_mf stub =="
analyze altera_mf "$NVCDIR/altera_mf_stub.vhd"

echo "== analyzing mem library =="
analyze mem "$MEMSRC/dpram.vhd" "$MEMSRC/RamMLAB.vhd" \
            "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd" \
            "$RTL/SyncFifoFallThroughMLAB.vhd" "$RTL/SyncRam.vhd"

# The core is built into a library named `psx` (matching the `library psx;`
# clause in tb_system573 / upstream tb.vhd). The core's own internal cross-
# references use `library work`, which resolves to the current library (psx)
# during analysis -- so `psx` is self-consistent.
echo "== analyzing psx core library (upstream compile order) =="
analyze psx "$MEMSRC/dpram.vhd"
CORE=(export divider pGPU mul32u mul9s gpu_fillVram gpu_cpu2vram gpu_vram2vram \
  gpu_vram2cpu gpu_line gpu_rect gpu_poly gpu_pixelpipeline gpu_overlay gpu_dither \
  gpu_videoout_async gpu_videoout_sync gpu_crosshair justifier_sensor gpu_videoout gpu \
  irq pJoypad joypad_pad joypad_mem joypad timer dma exp2 pGTE gte_mac0 gte_mac123 \
  gte_UNRDivide gte mdec cd_xa_zigzag cd_xa cd_top memctrl sio spu_ram spu_gauss spu \
  datacache cpu memorymux memcard statemanager savestates cheats psx_top psx_mister)
files=(); for f in "${CORE[@]}"; do files+=("$RTL/$f.vhd"); done
analyze psx "${files[@]}"

echo "== analyzing tb library (upstream pure-VHDL models, verbatim) =="
analyze tb "$TBSRC/globals.vhd" "$TBSRC/sdram_model3x.vhd" \
           "$TBSRC/ddrram_model.vhd" "$TBSRC/framebuffer.vhd"

echo "== analyzing tb_system573 =="
analyze tb "$HERE/tb_system573.vhd"

# -M / -H raise NVC's heap limits: the upstream memory models declare huge
# process variables (sdram_model3x t_data = 2**27 ints ~512 MB each x2;
# ddrram_model t_data = 2**28 ints ~1 GB). Default limits OOM at init.
NVC_MEM="-M 3g -H 6g"

echo "== elaborating tb_system573 (RAM8MB=$RAM8MB) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -e tb_system573 -gRAM8MB="'$RAM8MB'"

echo "== running tb_system573 (stop-time=$STOP_TIME) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -r tb_system573 --stop-time="$STOP_TIME"

echo
echo "== outputs in $WD =="
ls -la "$WD"/*.gra "$WD"/*.log 2>/dev/null || true
