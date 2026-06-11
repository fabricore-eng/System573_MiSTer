#!/usr/bin/env bash
# =============================================================================
# 4 MB main-RAM mirror red/green test (psx_patches/0022; PLATFORM.md Main RAM row).
#
# The System 573 has 4 MB of main RAM (MAME mame0288 ksys573.cpp L2600:
# subdevice<ram_device>("maincpu:ram")->set_default_size("4M")). MAME's PSX CPU
# maps it via RAM_SIZE (0x1f801060) config nibble 0xC -> a 4 MB window
# (psx.cpp update_ram_config L1353-1401, "zn1/konami gq/.../system 573"), and
# every DMA RAM access is masked with n_adrmask = ramsize-1 = 0x3fffff
# (cpu/psx/dma.cpp L122-125/L146/L243-247). The vendored core only decodes
# 2 MB (ram8mb=0) or 8 MB linear (ram8mb=1); the 573 shipped on ram8mb=1, so
# accesses at 0x00400000+ silently hit the WRONG SDRAM cells. patch 0022 adds
# ram4mb: mask RAM-region address bit 22 (CPU + DMA) on top of the 8 MB decode.
#
# This script hand-assembles a ~45-instruction MIPS probe ROM (loaded as the
# "BIOS" at 0xBFC00000 -- no Konami dump needed), elaborates tb_system573 with
# MIRRORTEST='1', and runs it. The probe:
#   1. sw 0xAAAA5555 -> 0xA0000000 ; sw 0x3C3C7E7E -> 0xA0400000 (the +4MB
#      alias) ; lw 0xA0000000 -> result1 (mirror => 0x3C3C7E7E)
#   2. sw 0x12348765 -> 0xA0000010 ; lw 0xA0400010 -> result2 (mirror => same)
#   3. OTC DMA (ch6) clear, 2 entries, D6_MADR=0x00400030 (alias); poll CHCR
#      busy; lw 0xA000002C -> result3 (mirror => the 0x00FFFFFF end marker)
# and stores result1/2/3 + a done flag to RAM 0x100/0x104/0x108/0x10C, where
# the tb checker renders the PASS/FAIL verdict (severity failure on FAIL).
#
# Usage:   sim/system573/run_ram_mirror.sh [STOP_TIME]
#   STOP_TIME : NVC --stop-time (default 500us; probe finishes well inside it)
#   RAM4MB    : env; '' (default) = tb/core defaults (post-0022: mirror ON);
#               '0' forces the old 8 MB linear decode (the RED configuration),
#               '1' forces the mirror. Pre-0022 cores: leave unset.
#
# Expected: PRE-patch-0022 (or RAM4MB=0)  -> MIRRORTEST FAIL (exit != 0)
#           POST-patch-0022 (default/=1)  -> MIRRORTEST PASS (exit 0)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"; RTL="$PSX/rtl"; MEMSRC="$PSX/sim/system/src/mem"; TBSRC="$PSX/sim/system/src/tb"
NVCDIR="$ROOT/sim/nvc"
WD="$HERE/build_mirror"

STOP_TIME="${1:-500us}"
RAM4MB="${RAM4MB:-}"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -d "$RTL" ] || { echo "error: psx submodule missing. Run: git submodule update --init psx" >&2; exit 1; }

# Ensure the GPL-isolated psx/ edits are applied (idempotent).
"$ROOT/tools/apply_psx_patches.sh" >/dev/null

rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"

# ---------------------------------------------------------------------------
# Hand-assemble the probe ROM (R3000, little-endian words; entry 0xBFC00000).
# All accesses through KSEG1 (uncached) -- no cache/COP0 setup needed.
# ---------------------------------------------------------------------------
python3 - "$WD/s573_bios.bin" <<'PY'
import struct, sys

def lui  (rt, imm):      return 0x3C000000 | (rt << 16) | (imm & 0xFFFF)
def ori  (rt, rs, imm):  return 0x34000000 | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def sw   (rt, off, rs):  return 0xAC000000 | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def lw   (rt, off, rs):  return 0x8C000000 | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def addiu(rt, rs, imm):  return 0x24000000 | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def srl  (rd, rt, sa):   return (rt << 16) | (rd << 11) | (sa << 6) | 0x02
def andi (rt, rs, imm):  return 0x30000000 | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def bne  (rs, rt, off):  return 0x14000000 | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def j    (target):       return 0x08000000 | ((target >> 2) & 0x3FFFFFF)
NOP = 0x00000000
BASE = 0xBFC00000

p = []
# --- 1. CPU write via the +4MB alias, read back at base ---
p += [lui(8, 0xA000)]                      # t0 = 0xA0000000 (RAM base, uncached)
p += [lui(9, 0xA040)]                      # t1 = 0xA0400000 (+4MB alias)
p += [lui(10, 0xAAAA), ori(10, 10, 0x5555)]
p += [sw(10, 0x0, 8)]                      # base[0]  = 0xAAAA5555 (sentinel)
p += [lui(11, 0x3C3C), ori(11, 11, 0x7E7E)]
p += [sw(11, 0x0, 9)]                      # alias[0] = 0x3C3C7E7E
p += [lw(12, 0x0, 8), NOP]                 # read base[0] (load-delay slot)
p += [sw(12, 0x100, 8)]                    # result1 -> 0x100
# --- 2. CPU write at base, read back via the alias ---
p += [lui(13, 0x1234), ori(13, 13, 0x8765)]
p += [sw(13, 0x10, 8)]                     # base[0x10] = 0x12348765
p += [lw(14, 0x10, 9), NOP]                # read alias[0x10]
p += [sw(14, 0x104, 8)]                    # result2 -> 0x104
# --- 3. OTC DMA (ch6) clear, MADR = the alias 0x00400030, 2 entries ---
p += [lui(15, 0x1F80)]                     # t7 = IO base
p += [lui(24, 0x0F65), ori(24, 24, 0x4321)]
p += [sw(24, 0x10F0, 15)]                  # DPCR = 0x0F654321 (enable ch6)
p += [lui(25, 0x0040), ori(25, 25, 0x0030)]
p += [sw(25, 0x10E0, 15)]                  # D6_MADR = 0x00400030
p += [addiu(16, 0, 2)]
p += [sw(16, 0x10E4, 15)]                  # D6_BCR  = 2
p += [lui(17, 0x1100), ori(17, 17, 0x0002)]
p += [sw(17, 0x10E8, 15)]                  # D6_CHCR = 0x11000002 (start, backward)
poll = len(p)
p += [lw(18, 0x10E8, 15), NOP]             # poll CHCR
p += [srl(19, 18, 24), andi(19, 19, 0x0001)]
p += [bne(19, 0, (poll - (len(p) + 1)) & 0xFFFF), NOP]   # busy (bit24)? loop
p += [lw(20, 0x2C, 8), NOP]                # base[0x2C] = OTC end-marker cell
p += [sw(20, 0x108, 8)]                    # result3 -> 0x108
# --- done flag + park ---
p += [lui(21, 0xD00E), ori(21, 21, 0xCAFE)]
p += [sw(21, 0x10C, 8)]                    # done -> 0x10C
hang = BASE + 4 * len(p)
p += [j(hang), NOP]

with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<%dI" % len(p), *p))
print("probe ROM: %d instructions, %d bytes -> %s" % (len(p), 4 * len(p), sys.argv[1]))
PY

# ---------------------------------------------------------------------------
# Analyze + elaborate (same recipe/compile order as run.sh, separate build dir).
# ---------------------------------------------------------------------------
NVC="nvc --std=2008 --ieee-warnings=off --messages=compact"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }
NVC_MEM="-M 3g -H 6g"

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

echo "== analyzing tb_system573 =="
analyze tb "$HERE/tb_system573.vhd"

GEN=( -gMIRRORTEST="'1'" -gTURBO="'0'" )
if [ -n "$RAM4MB" ]; then GEN+=( -gRAM4MB="'$RAM4MB'" ); fi
echo "== elaborating tb_system573 (MIRRORTEST=1 TURBO=0 RAM4MB=${RAM4MB:-<default>}) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -e tb_system573 --stats "${GEN[@]}"

echo "== running tb_system573 (stop-time=$STOP_TIME) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -r tb_system573 --stats --stop-time="$STOP_TIME"
