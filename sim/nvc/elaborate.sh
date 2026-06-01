#!/usr/bin/env bash
# Reproducible gate: analyze + elaborate the patched PSX core (psx_mister) under NVC,
# straight from the repo. Proves the System 573 EXP1 widening (psx_patches/) compiles
# and elaborates cleanly. NVC is used because the PSX core is VHDL-2008 -- Verilator
# cannot consume it, and no open-source tool co-simulates VHDL+Verilog (see
# docs/PHASE1_PSX.md). It (re)applies our psx/ patches first.
#
# Usage: sim/nvc/elaborate.sh        # analyze + elaborate psx_mister (exit !=0 on failure)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"; RTL="$PSX/rtl"; MEMSRC="$PSX/sim/system/src/mem"
WD="$HERE/build"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -d "$RTL" ] || { echo "error: psx submodule missing. Run: git submodule update --init psx" >&2; exit 1; }

# Ensure our GPL-isolated psx/ edits are applied to the pinned submodule working tree.
"$ROOT/tools/apply_psx_patches.sh" >/dev/null

rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"
NVC="nvc --std=2008"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }

# Empty altera_mf stub (unused use-clause in spu_ram.vhd).
analyze altera_mf "$HERE/altera_mf_stub.vhd"

# mem library: behavioral RAM models (no altera_mf), per upstream vcom_all.bat.
analyze mem "$MEMSRC/dpram.vhd" "$MEMSRC/RamMLAB.vhd" \
            "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd" \
            "$RTL/SyncFifoFallThroughMLAB.vhd" "$RTL/SyncRam.vhd"

# work: sim dpram first (provides dpram_dif, used by spu_ram via `entity work.dpram_dif`).
analyze work "$MEMSRC/dpram.vhd"

# work: the PSX core in upstream compile order (psx.qip order).
CORE=(export divider pGPU mul32u mul9s gpu_fillVram gpu_cpu2vram gpu_vram2vram \
  gpu_vram2cpu gpu_line gpu_rect gpu_poly gpu_pixelpipeline gpu_overlay gpu_dither \
  gpu_videoout_async gpu_videoout_sync gpu_crosshair justifier_sensor gpu_videoout gpu \
  irq pJoypad joypad_pad joypad_mem joypad timer dma exp2 pGTE gte_mac0 gte_mac123 \
  gte_UNRDivide gte mdec cd_xa_zigzag cd_xa cd_top memctrl sio spu_ram spu_gauss spu \
  datacache cpu memorymux memcard statemanager savestates cheats psx_top psx_mister)
files=(); for f in "${CORE[@]}"; do files+=("$RTL/$f.vhd"); done
analyze work "${files[@]}"

echo "== elaborating psx_mister =="
$NVC --work="work:$WD/work" -L "$WD" -e psx_mister
echo "OK: patched PSX core (psx_mister) analyzes + elaborates clean under NVC."
