#!/usr/bin/env bash
# =============================================================================
# Stage 1 of the garble-isolation plan: savestate -> full-573 sim REPLAY.
#
# Analyze + elaborate + run tb_573_ssreplay (sim/system573_ssreplay/), which
# instantiates the SAME full-573 DUT + memory models as sim/system573, but drives
# the REAL in-core savestate loader (psx/rtl/savestates.vhd): it PRELOADS a .ss
# into the ddrram_model at the DDR savestate region and PULSES load_state, exactly
# as the .rbf does on HW (rtl/emu.sv ss_load -> psx_mister.load_state). Then it
# runs forward and dumps the framebuffer (gra_fb_out_vga.gra -> PNG).
#
# Usage:
#   sim/system573_ssreplay/run.sh [STOP_TIME] [SS_FILE]
#     STOP_TIME : NVC --stop-time value (default 2ms)
#     SS_FILE   : path to a .ss savestate. If omitted/missing, a SYNTHETIC
#                 zero-payload .ss with a VALID header (DWORD[1]=STATESIZE) is
#                 generated so the LOAD FSM can be exercised end-to-end (de-risk).
#
# Env:
#   LOAD_SS=0   boot WITHOUT a savestate (A/B vs the resume) -- skips preload+pulse
#   DRAWTAP=1   enable the per-draw GPU CLUT tap (drawtap.log) -- OFF by default
#   PRELOAD=1   (default when a real .ss is given) Option A: also carve the .ss
#               VRAM(15)+RAM(16) slices (FASTSIM skips them) and preload them into
#               the ddrram_model VRAM window + the main sdram_model3x. Set 0 to skip.
#   LOAD_AT     NVC time literal: when (after reset) to pulse load_state (def "60 us")
#   TURBO       1 (default) sim accelerators; 0 = realistic timing
#   SLOWVRAM    ddrram_model VRAM read latency, cycles (default 0)
#   RAM8MB      '1' (8 MB, default) or '0' (2 MB)
#   REUSE=1     re-run the cached elaboration with a (possibly new) STOP_TIME/SS
#
# All build artifacts + sim outputs land in build/ (gitignored).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"; RTL="$PSX/rtl"; MEMSRC="$PSX/sim/system/src/mem"; TBSRC="$PSX/sim/system/src/tb"
NVCDIR="$ROOT/sim/nvc"
WD="$HERE/build"

STOP_TIME="${1:-2ms}"
SS_FILE_IN="${2:-}"
# Resolve a relative .ss path to absolute NOW (the build cd's into $WD, after which a
# relative path no longer resolves -> the staging block would silently fall back to a
# synthetic zero .ss). Absolute keeps the top-level PRELOAD check + staging consistent.
if [ -n "$SS_FILE_IN" ] && [ -f "$SS_FILE_IN" ]; then
  SS_FILE_IN="$(cd "$(dirname "$SS_FILE_IN")" && pwd)/$(basename "$SS_FILE_IN")"
fi
RAM8MB="${RAM8MB:-1}"
TURBO="${TURBO:-1}"
SLOWVRAM="${SLOWVRAM:-0}"
LOAD_SS="${LOAD_SS:-1}"
DRAWTAP="${DRAWTAP:-0}"
PCPROBE="${PCPROBE:-0}"
GPUPROBE="${GPUPROBE:-0}"
LOAD_AT="${LOAD_AT:-60 us}"
REUSE="${REUSE:-0}"
# PRELOAD defaults ON when a real .ss is supplied (Option A), OFF otherwise.
if [ -n "$SS_FILE_IN" ] && [ -f "$SS_FILE_IN" ]; then PRELOAD="${PRELOAD:-1}"; else PRELOAD="${PRELOAD:-0}"; fi
VRAM_BASENAME="ss_vram.bin"
RAM_BASENAME="ss_ram.bin"
BIOS_SRC="$ROOT/dumps/bios/700a01(gchgchmp).22g"

# The savestate region is SAVESTATESIZE = 0x100000 DWORDs = 1048576 dwords = 4 MiB.
# Header layout (psx/rtl/savestates.vhd): DDR DWORD pair at the base holds
# {ddr3_DIN(63:32)=STATESIZE, ddr3_DIN(31:0)=header_amount}; in the LE .ss byte
# stream that is word[0]=header_amount, word[1]=STATESIZE=1048574 (0x000FFFFE).
SS_DWORDS=1048576
STATESIZE=1048574

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -d "$RTL" ] || { echo "error: psx submodule missing. Run: git submodule update --init psx" >&2; exit 1; }
[ -f "$BIOS_SRC" ] || { echo "error: BIOS not found: $BIOS_SRC" >&2; exit 1; }

NVC="nvc --std=2008 --ieee-warnings=off --messages=compact"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }
# sdram_model3x (2**27 ints x2) + ddrram_model (2**28 ints) need raised heap limits.
NVC_MEM="-M 3g -H 6g"

SS_BASENAME="state.ss"

if [ "$REUSE" = "1" ]; then
  [ -f "$WD/tb/TB.TB_573_SSREPLAY.elab" ] || {
    echo "error: REUSE=1 but no elaborated design in $WD; run once without REUSE first" >&2
    exit 1; }
  cd "$WD"
  echo "== REUSE=1: skipping analyze/elaborate; reusing $WD =="
  # still (re)stage the savestate so a new SS_FILE/STOP_TIME takes effect
  if [ "$LOAD_SS" != "0" ]; then
    if [ -n "$SS_FILE_IN" ] && [ -f "$SS_FILE_IN" ]; then
      cp "$SS_FILE_IN" "$WD/$SS_BASENAME"
      echo "   staged real savestate: $SS_FILE_IN ($(wc -c < "$SS_FILE_IN") bytes)"
      if [ "$PRELOAD" = "1" ]; then
        python3 "$ROOT/tools/ss_vram_extract.py" "$WD/$SS_BASENAME" \
                --vram "$WD/$VRAM_BASENAME" --ram "$WD/$RAM_BASENAME"
        echo "   re-carved Option A slices ($VRAM_BASENAME + $RAM_BASENAME)"
      fi
    fi
  fi
else

"$ROOT/tools/apply_psx_patches.sh" >/dev/null
rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"
cp "$BIOS_SRC" "$WD/s573_bios.bin"

# Stage the savestate. Real .ss if given+exists; else a SYNTHETIC valid-header
# zero-payload .ss so the LOAD FSM runs end-to-end (the de-risk path).
if [ "$LOAD_SS" != "0" ]; then
  if [ -n "$SS_FILE_IN" ] && [ -f "$SS_FILE_IN" ]; then
    cp "$SS_FILE_IN" "$WD/$SS_BASENAME"
    echo "== savestate: REAL $SS_FILE_IN ($(wc -c < "$SS_FILE_IN") bytes) =="
    # Option A: carve the FASTSIM-skipped VRAM(15)+RAM(16) slices for tb preload.
    if [ "$PRELOAD" = "1" ]; then
      python3 "$ROOT/tools/ss_vram_extract.py" "$WD/$SS_BASENAME" \
              --vram "$WD/$VRAM_BASENAME" --ram "$WD/$RAM_BASENAME"
      echo "== Option A preload: carved $VRAM_BASENAME (VRAM) + $RAM_BASENAME (RAM) =="
    fi
  else
    if [ -n "$SS_FILE_IN" ]; then
      echo "== savestate: '$SS_FILE_IN' not found -> generating SYNTHETIC valid-header .ss =="
    else
      echo "== savestate: none given -> generating SYNTHETIC valid-header .ss (de-risk) =="
    fi
    SS_DWORDS=$SS_DWORDS STATESIZE=$STATESIZE python3 - "$WD/$SS_BASENAME" <<'PY'
import os, struct, sys
p = sys.argv[1]
n = int(os.environ["SS_DWORDS"]); statesize = int(os.environ["STATESIZE"])
buf = bytearray(n * 4)                       # all zero payload
# header: word[0]=header_amount(=1), word[1]=STATESIZE so the slot validates.
struct.pack_into("<I", buf, 0, 1)
struct.pack_into("<I", buf, 4, statesize)
open(p, "wb").write(buf)
print(f"synthetic .ss: {len(buf)} bytes, word[1]=0x{statesize:08x} (STATESIZE) for slot-valid")
PY
  fi
fi

echo "== analyzing altera_mf stub =="
analyze altera_mf "$NVCDIR/altera_mf_stub.vhd"

echo "== analyzing mem library =="
analyze mem "$MEMSRC/dpram.vhd" "$MEMSRC/RamMLAB.vhd" \
            "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd" \
            "$RTL/SyncFifoFallThroughMLAB.vhd" "$RTL/SyncRam.vhd"

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

echo "== analyzing tb_573_ssreplay =="
analyze tb "$HERE/tb_573_ssreplay.vhd"

echo "== elaborating tb_573_ssreplay (LOAD_SS=$LOAD_SS PRELOAD=$PRELOAD RAM8MB=$RAM8MB TURBO=$TURBO SLOWVRAM=$SLOWVRAM DRAWTAP=$DRAWTAP LOAD_AT='$LOAD_AT') =="
# --no-collapse: keep the per-i combinational CLUT signals (CLUTaddrB/CLUTDataB at
# the dpram instance ports) NAMEABLE so the DRAWTAP external-name taps resolve.
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -e tb_573_ssreplay --stats --no-collapse \
     -gRAM8MB="'$RAM8MB'" -gTURBO="'$TURBO'" -gSLOWVRAM=$SLOWVRAM \
     -gLOAD_SS="'$LOAD_SS'" -gDRAWTAP="'$DRAWTAP'" -gPCPROBE="'$PCPROBE'" \
     -gGPUPROBE="'$GPUPROBE'" \
     -gPRELOAD_VRAM="'$PRELOAD'" -gPRELOAD_RAM="'$PRELOAD'" \
     -gVRAM_FILE="$VRAM_BASENAME" -gRAM_FILE="$RAM_BASENAME" \
     -gSS_FILE="$SS_BASENAME" -gLOAD_AT="$LOAD_AT"

fi   # end of build (REUSE=0 path)

echo "== running tb_573_ssreplay (stop-time=$STOP_TIME, reuse=$REUSE) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -r tb_573_ssreplay --stats --stop-time="$STOP_TIME"

echo
echo "== rendering framebuffer .gra -> PNG =="
for g in gra_fb_out_vga gra_fb_out; do
  if [ -s "$WD/$g.gra" ]; then
    python3 "$ROOT/tools/gra2png.py" "$WD/$g.gra" "$WD/$g.png" || true
  fi
done

echo
echo "== outputs in $WD =="
ls -la "$WD"/*.gra "$WD"/*.png "$WD"/*.log 2>/dev/null || true
