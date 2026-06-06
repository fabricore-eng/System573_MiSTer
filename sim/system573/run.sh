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
# TURBO=1 (default): sim accelerators (TURBO_MEM/COMP/CACHE). TURBO=0 runs the core
# under realistic memory/cache/DMA timing (slower; use to confirm no accelerator masks
# an integration bug, esp. on the GPU-DMA path).
TURBO="${TURBO:-1}"
# SLOWVRAM: VRAM (DDR) model read latency in cycles for the GPU path. Default 0
# (near-instant) for bring-up: the boot spins on GPUSTAT bit 28 (GPU ready-for-DMA =
# command-FIFO empty), which drains only as fast as the GPU executes VRAM commands, so
# slow VRAM lengthens those waits and the drawing path. Set SLOWVRAM=15 for realistic
# VRAM timing. Sim-model only (ddrram_model), never in the .rbf.
SLOWVRAM="${SLOWVRAM:-0}"
# FAST_RAMTEST=1 (default): sim-only BIOS patch that enlarges the 4 MB RAM-test
# stride 4->0x4000 so it walks the full 0xA0000000..0xA0400000 range in 256 steps
# instead of 1,048,576. The test is uncached (KSEG1), so each access costs ~hundreds
# of core cycles regardless of TURBO -- the real test is ~10M+ cycles, untenable to
# simulate. The stride is a power-of-2 dividing the 4 MB range so the loop still
# exits exactly (t1 reaches the end pointer) and still kicks the watchdog. The
# ORIGINAL dump is never touched; only the build/ copy is patched, for bring-up
# only. The Quartus .rbf uses the pristine BIOS. Set FAST_RAMTEST=0 for the real test.
FAST_RAMTEST="${FAST_RAMTEST:-1}"
# FAST_BOOT=1 (default): additional sim-only BIOS patches (build/ copy ONLY, never the
# .rbf) that shortcut the remaining UNCACHED (KSEG1) boot-ROM spin loops that the boot
# stalls in BEFORE it reaches the GX700 self-test / ATAPI drive check, so the full-system
# sim can actually EXECUTE the real drive check in a tractable wall-clock budget. Each is
# guarded (refuses to patch if the expected word is absent -- fails loudly on a different
# BIOS revision). The patches (all functionally invisible to the BIOS's own checks):
#   * 0x474  BSS/runtime clear loop `bne r1,r0,0x46C` -> NOP. Zeroes A0019000..A001B150
#     uncached; the sdram_model3x array is already 0-initialised so the clear is redundant
#     in sim (README "BSS clear is redundant in sim"). NOP makes it fall through after one
#     iteration. Saves ~550 uncached stores.
#   * 0x44C8 GPUSTAT bit-28 wait first-check `bne r25,r0,0x4504` -> `bne r3,r0,0x4504`.
#     r3 = 0x10000000 (set by `lui r3,0x1000` at 0x44B8) is always nonzero, so the branch
#     to the success exit (0x4504, returns r2=0 "GPU ready") is ALWAYS taken on the first
#     GPUSTAT read -- the BIOS never enters the bit-28 countdown poll loop (0x44D4..0x44FC)
#     that traps the boot when the sim GPU never resolves GPUSTAT bit28. Same effect as the
#     GPU reporting "ready to receive DMA / command-FIFO empty" immediately.
# Set FAST_BOOT=0 to keep these loops (the .rbf always uses the pristine BIOS).
FAST_BOOT="${FAST_BOOT:-1}"
# CORRECT_BOOT=1 (default): KEEP the two BSS/runtime-clear loops that FAST_BOOT would
# otherwise NOP -- the BIOS BSS clear (0x474, zeroes A0019000..A001B150) and the PS-X
# EXE crt0 BSS clear (0x43188, zeroes RAM 0x803d0fac..0x803f9584). NOP'ing them ASSUMED
# the sim main-RAM model is zero-init, but the boot then hung at a CORRUPT-pointer
# interrupt jump to unmapped 0xFA02221C during EXE POST hw-init (the kernel exception
# dispatcher at low RAM 0x00000C80 walks the interrupt-callback chain and jalrs through a
# junk verifier/handler pointer in an EXE BSS struct that was never zeroed). Re-running
# the REAL BSS clears guarantees those structs (incl. the ISR sentinel 0x803d2358 and any
# chain nodes) are genuinely zero before main(), so the chain walk skips null entries
# instead of jumping to garbage -- CORRECTNESS over the ~41K-word speed shortcut. The
# 22G checksum is recomputed regardless, so dropping these two NOPs is consistent. Set
# CORRECT_BOOT=0 to restore the (faster, but boot-corrupting) NOP behaviour. Only consulted
# when FAST_BOOT!=0. Sim-only; the .rbf always runs the pristine BIOS.
CORRECT_BOOT="${CORRECT_BOOT:-1}"
# ATAPI_EMU=1: make the behavioral EXP1 responder MIRROR rtl/atapi.v for the ATAPI page
# (0x48/0x4c/0x56), so the full-system sim runs the REAL BIOS GX700 drive check against
# atapi.v-equivalent responses (signature 0xEB14, STATUS/byte-count, A0 PACKET + A1
# IDENTIFY + the data-in cmd set) AND drives exp_irq10 (ATAPI INTRQ) -- the only way to
# observe whether the integrated IRQ10/ISR path services the real drive check (NVC can't
# co-sim the Verilog atapi.v). Default 0 (ATAPI reads return 0; the drive check then
# diverges on the signature -- useful only to confirm the BIOS REACHES the check).
# Mutually exclusive with INJECT (which owns exp_irq10). Sim-only; the .rbf uses atapi.v.
ATAPI_EMU="${ATAPI_EMU:-0}"
# INJECT=1: enable the ATAPI-INTRQ interrupt-delivery probe. The harness has no
# Verilog ATAPI device (NVC can't co-sim Verilog), so to test whether an ATAPI
# interrupt actually reaches+vectors the integrated CPU, the tb self-arms a clean
# exp_irq10 pulse INJECT_DELAY after the BIOS first unmasks I_MASK bit10, and a
# probe captures the full delivery chain (irq_probe.log / sentinel.log). Default 0
# (legacy: exp_irq10 held low). Sim-only; never in the .rbf.
INJECT="${INJECT:-0}"
# INJECT_DELAY / INJECT_WIDTH are NVC time generics (e.g. "5 us"). Defaults match
# the tb. Only consulted at elaboration (drop REUSE to change).
INJECT_DELAY="${INJECT_DELAY:-5 us}"
INJECT_WIDTH="${INJECT_WIDTH:-3 us}"
# INJECT_AT > "0 ns": time-based injection (fire at this absolute sim time regardless of
# I_MASK) -- use when the BIOS never reaches its own IRQ10 unmask in the simulable window.
INJECT_AT="${INJECT_AT:-0 ns}"
# REUSE=1: skip the (idempotent) patch-apply + analyze + elaborate and just re-run
# the design already built in build/ with a (possibly different) STOP_TIME -- seconds
# instead of minutes. Valid ONLY after a cold build (REUSE unset). RAM8MB/TURBO/SLOWVRAM/
# FAST_RAMTEST and the harness taps/RTL are FIXED at the cached build's values under
# REUSE (the args/env that select them only affect elaboration); rebuild (drop REUSE)
# to change any of them. (Without --ignore-time, NVC still warns if a source is newer
# than the elaborated design -- the safety net for a forgotten rebuild.)
REUSE="${REUSE:-0}"
BIOS_SRC="$ROOT/dumps/bios/700a01(gchgchmp).22g"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -d "$RTL" ] || { echo "error: psx submodule missing. Run: git submodule update --init psx" >&2; exit 1; }
[ -f "$BIOS_SRC" ] || { echo "error: BIOS not found: $BIOS_SRC" >&2; exit 1; }

# NVC invocation. --ieee-warnings=off suppresses the NUMERIC_STD metavalue warnings
# the core emits while signals settle from 'U' early in sim (benign -- e.g. reads of
# the un-preloaded SPU RAM); they otherwise dominate stdout AND wall-clock.
# --messages=compact shortens the rest. Both are diagnostics-only (no behavior change).
NVC="nvc --std=2008 --ieee-warnings=off --messages=compact"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }
# -M / -H raise NVC's heap limits: the upstream memory models declare huge process
# variables (sdram_model3x t_data = 2**27 ints ~512 MB each x2; ddrram_model
# t_data = 2**28 ints ~1 GB). Default limits OOM at init.
NVC_MEM="-M 3g -H 6g"

if [ "$REUSE" = "1" ]; then
  [ -f "$WD/tb/TB.TB_SYSTEM573.elab" ] || {
    echo "error: REUSE=1 but no elaborated design in $WD; run once without REUSE first" >&2
    exit 1; }
  cd "$WD"
  echo "== REUSE=1: skipping patch/analyze/elaborate; reusing $WD =="
  echo "   (RAM8MB/TURBO/SLOWVRAM/FAST_RAMTEST fixed at the cached build's values; drop REUSE to change)"
else

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

if [ "$FAST_BOOT" != "0" ]; then
  # Sim-only shortcuts past the remaining uncached boot-ROM spin loops (build/ copy
  # only). Table of (offset, expected_word, new_word). Each entry is guarded: if the
  # expected word is not present it aborts loudly (wrong BIOS revision). See the
  # FAST_BOOT comment above for the rationale of each.
  CORRECT_BOOT="$CORRECT_BOOT" python3 - "$WD/s573_bios.bin" <<'PY' || { echo "error: FAST_BOOT BIOS patch failed" >&2; exit 1; }
import sys, struct, os
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
# CORRECT_BOOT=1 keeps the two BSS-clear loops intact (omits their NOP patches) so the
# real BIOS/EXE zero their runtime data structures -- prevents the corrupt-pointer hang.
CORRECT_BOOT = os.environ.get("CORRECT_BOOT", "1") != "0"
# (file_off, expected, new, label)
PATCHES = [
    (0x454, 0x1528FFED, 0x00000000,
     "4MB RAM-test loop bne r9,r8,0x40C -> NOP (no watchdog model in this harness; "
     "test is sim-redundant -- runs 1 iteration then falls through)"),
    (0x4E4, 0x14C0FFFB, 0x00000000,
     "BIOS->RAM copy loop bne r6,r0,0x4D4 -> NOP (tb PRELOAD_COPY stages the 0x9000-byte "
     "slice into RAM; copy redundant -- boot jr's straight into the relocated code)"),
    (0x20244, 0x14E3FFFA, 0x00000000,
     "PS-X EXE copy loop bne r7,r3,0x20230 -> NOP. The boot ROM copies the 0x11000-byte "
     "573 EXE (file 0x40800) BYTE-BY-BYTE (lbu/sb) to RAM 0x803c0000 -- ~69632 uncached "
     "iterations, the dominant bottleneck to reaching the EXE's GX700 drive check. The tb "
     "PRELOAD_EXE stages that body into RAM so the boot jalr's straight into the EXE entry "
     "0x803c296c with the code already present."),
    (0x44C8, 0x1720000E, 0x1460000E,
     "GPUSTAT bit28 wait first-check bne r25,r0 -> bne r3,r0 (r3=0x10000000, always exit ready)"),
    # 22G self-checksum at EXE 0x803c1ac0: sums 0x1FFFE words of BIOS (0x9FC00000) UNCACHED
    # (~131070 reads x ~33 clk1x = ~4.3M cycles = the single biggest barrier to the drive
    # check). Shrink the loop count (r6 0x1FFFE->2) so it runs ~2 iters, then NOP the
    # result compare (bne r5,r2) so 22G is forced OK regardless of the (now-wrong) partial
    # sum -- the boot falls through to result=1 (OK). EXE-body file offsets; staged via
    # PRELOAD_EXE. (The trailing checksum word is recomputed below for any other consumer.)
    (0x422CC, 0x3C060001, 0x3C060000,
     "22G checksum loop count: lui r6,0x0001 -> lui r6,0x0000 (with next, r6=2 not 0x1FFFE)"),
    (0x422D0, 0x34C6FFFE, 0x34C60002,
     "22G checksum loop count: ori r6,r6,0xfffe -> ori r6,r6,0x0002 (loop runs ~2 iters)"),
    (0x422F8, 0x14A20002, 0x00000000,
     "22G checksum compare bne r5,r2 -> NOP (force result OK; partial sum no longer checked)"),
    # EXE work-RAM PRNG test (orchestrator 0x803c1bf0): fills + verifies ~1MB of RAM
    # (0x80010000..0x80110000) with a linear-congruential PRNG (0x803c19a0 fill calls the
    # 0x41C64E6D rand at 0x803c28c0 65536x, looped 16x = ~1M PRNG calls = >10M clk1x = the
    # dominant remaining barrier to the drive check). The sdram_model3x is reliable for any
    # address, so the test is sim-redundant. Stub BOTH primitives to return instantly:
    #   * fill 0x803c19a0 -> jr r31 / nop  (skip the PRNG fill loops)
    #   * verify 0x803c1a04 -> jr r31 / addu r2,r0,r0  (return 0 = "RAM OK")
    # so the orchestrator's `bne r2,r0,fail` always passes. (EXE-body file offsets; staged
    # by PRELOAD_EXE. The 22G checksum compare is already NOP'd so these byte changes are
    # harmless to it.)
    (0x421A0, 0x27BDFFD8, 0x03E00008,
     "EXE RAM-test FILL-A entry addiu sp -> jr r31 (skip the 16x128KB PRNG fill)"),
    (0x421A4, 0xAFBF0020, 0x00000000,
     "EXE RAM-test FILL-A entry+4 sw r31 -> nop (jr delay slot)"),
    (0x42204, 0x27BDFFD8, 0x03E00008,
     "EXE RAM-test VERIFY entry addiu sp -> jr r31 (skip the read-back verify)"),
    (0x42208, 0xAFBF0024, 0x00001021,
     "EXE RAM-test VERIFY entry+4 sw r31 -> addu r2,r0,r0 (return 0 = RAM OK)"),
    # The EXE memory-test SUITE has several PRNG fill+verify pairs. The INNER PRNG-fill
    # primitive 0x803c184c (calls the 0x41C64E6D LCG rand at 0x803c28c0 per halfword) is
    # invoked by MULTIPLE outer test functions (0x803c19a0 [stubbed above] AND 0x803c1fc0's
    # function), so stubbing one outer wrapper is not enough -- the boot still grinds the
    # other suite's fill. Stub the inner primitive itself -> all fills become no-ops. (Any
    # verify that reads back the skipped fill must also be stubbed to return OK; 0x803c1a04
    # is done above. If a later run still grinds a verify mismatch, locate the remaining
    # verify entr(y/ies) and stub similarly, OR -- cleaner -- find the POST test-suite
    # orchestrator and skip straight to the drive-check subsystem test.)
    (0x4204C, 0x27BDFFE0, 0x03E00008,
     "EXE RAM-test INNER PRNG-fill 0x803c184c entry addiu sp -> jr r31 (no-op all fills)"),
    (0x42050, 0xAFBF0018, 0x00000000,
     "EXE RAM-test INNER PRNG-fill entry+4 sw r31 -> nop (jr delay slot)"),
    # The RAM-test SUITE wrapper 0x803c1fc0 calls four children: 0x803c184c (inner PRNG
    # fill, stubbed above), the orchestrator 0x803c1ba0, the SPU "WAVE RAM" test 0x803c1cdc,
    # and the timer/RTC test 0x803c1e74. The wrapper does NOT check any of their return
    # values (results go to the 0x803d2xxx status table, written by each fn internally), and
    # POST only ABORTS on a BAD result -- so neutralising the SLOW loops inside them (not the
    # status writes) is invisible to POST. The remaining slow loops the inner-fill stub does
    # NOT cover:
    #   * 0x803c1b78  the orchestrator's 1 MB NOR-fill (0x80010000..0x80110000, ~256K cached
    #     iterations). It is a pure fill (read/NOR/store), no status side effect -> stub to
    #     jr r31 outright. The orchestrator's verify (0x803c1a04) is already stubbed to return
    #     0 ("RAM OK") so 0x803c1ba0 still takes its OK path and writes OK status.
    #     (Its delay slot at file 0x4237C is already a NOP, so jr r31 is safe with no 2nd patch.)
    (0x42378, 0x8C820000, 0x03E00008,
     "EXE RAM-test 1MB NOR-fill 0x803c1b78 entry lw v0,(a0) -> jr r31 (skip 256K-iter fill)"),
]
# The two BSS/runtime-clear loops are CORRECTNESS-critical (they zero the runtime data
# structures the kernel/EXE later read as interrupt-callback chain nodes + sentinels).
# Only NOP them when CORRECT_BOOT=0 (the old, boot-corrupting fast path). With
# CORRECT_BOOT=1 (default) they run for real -- the boot no longer jalrs through a junk
# handler pointer to 0xFA02221C during EXE POST hw-init.
if not CORRECT_BOOT:
    PATCHES.insert(1, (0x474, 0x1420FFFD, 0x00000000,
        "BSS-clear loop bne r1,r0,0x46C -> NOP (CORRECT_BOOT=0: sim RAM 0-init assumed)"))
    PATCHES.append((0x43188, 0x1420FFFC, 0x00000000,
        "PS-X EXE crt0 BSS-clear bne r1,r0,0x803c297c -> NOP (CORRECT_BOOT=0: sim RAM 0-init assumed)"))
print(f"FAST_BOOT: CORRECT_BOOT={'1 (BSS clears KEPT -- correct boot)' if CORRECT_BOOT else '0 (BSS clears NOPd -- fast, may corrupt)'}")
for off, exp, new, label in PATCHES:
    cur = struct.unpack_from("<I", b, off)[0]
    if cur != exp:
        sys.exit(f"FAST_BOOT: unexpected word 0x{cur:08x} at 0x{off:x} "
                 f"(expected 0x{exp:08x}); refusing to patch [{label}]")
    struct.pack_into("<I", b, off, new)
    print(f"FAST_BOOT: 0x{off:05x} 0x{exp:08x}->0x{new:08x}  {label}")

# CRITICAL: the 573 EXE runs a 22G self-checksum POST step (loop at EXE 0x803c1ac0)
# that sums the 512KB BIOS as 32-bit LE words[0:0x1FFFF] (file 0..0x7FFFC) and compares
# to the stored word at file 0x7FFFC; a mismatch => 22G BAD => POST ABORTS before the
# drive check. Every FAST_BOOT patch above changes a summed byte, so we MUST recompute
# the trailing checksum word so 22G still passes. (sum excludes word[0x1FFFF] itself.)
s = 0
for i in range(0x1FFFF):
    s = (s + struct.unpack_from("<I", b, 4*i)[0]) & 0xFFFFFFFF
old_ck = struct.unpack_from("<I", b, 0x7FFFC)[0]
struct.pack_into("<I", b, 0x7FFFC, s)
print(f"FAST_BOOT: 22G checksum recomputed 0x{old_ck:08x}->0x{s:08x} (word@0x7FFFC) "
      f"so the BIOS self-check still passes with the patches")
open(p, "wb").write(b)
PY
fi

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

# PRELOAD_COPY mirrors FAST_BOOT: the tb pre-stages the BIOS->RAM copy slice exactly when
# FAST_BOOT NOPs the copy loop (they MUST match -- the boot jr's into the preloaded code).
if [ "$FAST_BOOT" != "0" ]; then PRELOAD_COPY=1; else PRELOAD_COPY=0; fi

echo "== elaborating tb_system573 (RAM8MB=$RAM8MB TURBO=$TURBO SLOWVRAM=$SLOWVRAM INJECT=$INJECT PRELOAD_COPY=$PRELOAD_COPY ATAPI_EMU=$ATAPI_EMU) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -e tb_system573 --stats \
     -gRAM8MB="'$RAM8MB'" -gTURBO="'$TURBO'" -gSLOWVRAM=$SLOWVRAM \
     -gPRELOAD_COPY="'$PRELOAD_COPY'" -gATAPI_EMU="'$ATAPI_EMU'" \
     -gINJECT="'$INJECT'" -gINJECT_DELAY="$INJECT_DELAY" -gINJECT_WIDTH="$INJECT_WIDTH" \
     -gINJECT_AT="$INJECT_AT"

fi   # end of build (REUSE=0 path)

echo "== running tb_system573 (stop-time=$STOP_TIME, reuse=$REUSE) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -r tb_system573 --stats --stop-time="$STOP_TIME"

echo
echo "== outputs in $WD =="
ls -la "$WD"/*.gra "$WD"/*.log 2>/dev/null || true
