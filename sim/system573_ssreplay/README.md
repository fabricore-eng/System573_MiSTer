# sim/system573_ssreplay — savestate → full-573 sim replay (Stage 1)

Stage 1 of the garble-isolation plan (`.claude/plans/calm-wiggling-honey.md`): load a
PlayStation/573 **savestate (`.ss`)** into the **full 573 system** under NVC and run forward, so
the core becomes BOTH *freezable* (via the savestate) AND *fully observable* (in sim) — the unlock
for an alignment-free per-draw GPU comparison vs MAME.

It reuses the exact full-573 DUT + memory models of `sim/system573` (`psx_mister` + two
`sdram_model3x` + `ddrram_model` + `framebuffer`), but instead of tying the savestate path off it
**drives the real in-core savestate loader**.

> ### ⏱ Do Stage 0 FIRST — it may name the bug without any sim
> A HW savestate ALSO freezes our complete VRAM. Before running this (slow) sim replay, run the
> cheap board-free **static VRAM byte-compare** on the same `.ss`:
> ```
> tools/ss_garble_probe.sh <real.ss> local/mame_vram_title.bin   # -> per-region SSIM/%diff + heatmap
> ```
> `tools/ss_vram_extract.py` carves the `.ss` VRAM (savetype 15, byte 0x100000, 1 MiB) and RAM
> (savetype 16, byte 0x200000, 2 MiB) slices; the probe renders our frozen VRAM + MAME's and runs
> `frame_diff_regions.py`. Because TEXTURE pages are scene-independent, a TEXTURE/CLUT region
> diverging = the data bug, even if the scene-dependent FRAMEBUFFER region differs. Only escalate to
> this Stage-1 sim replay if Stage 0 shows the textures/CLUTs are byte-CORRECT in VRAM yet still
> render garbled (→ a GPU *sampling* bug the per-draw tap isolates). Both tools are self-tested
> (`--selftest`); the probe pipeline is validated end-to-end (VRAM==MAME→MATCH, gradient→MISMATCH).

## How the savestate-load is wired (the real HW path, no vendored edit)

On real hardware (`rtl/emu.sv:1351-1353`) the framework wires `ss_save`/`ss_load`/`ss_slot` straight
to `psx_mister.save_state`/`load_state`/`savestate_number`. The HPS DMAs the `.ss` file into the DDR3
savestate region; pulsing `load_state` makes the in-core FSM read it back out of DDR and replay it
into every sub-block. This harness reproduces that exactly:

1. **psx_mister.load_state** (the only savestate control input) → `psx_top` →
   **`istatemanager`** (`psx/rtl/psx_top.vhd:2215`, `statemanager.vhd`): on a `load` rising edge it
   latches `load_buffer` and, once `request_busy=0`, drives `request_loadstate` + `request_address =
   Softmap_SaveState_ADDR + slot*SAVESTATESIZE` (`statemanager.vhd:114-117`).
2. **`isavestates`** (`psx/rtl/psx_top.vhd:2134`, `savestates.vhd`) takes `load` →
   `LOAD_WAITSETTLE → LOAD_RESETSSCHECK → LOAD_HEADERAMOUNTCHECK → LOADMEMORY_*`. It READS the
   savestate from DDR via `ss_ram_ADDR/ss_ram_RD` and, in `LOADMEMORY_WRITE` (`savestates.vhd:644`),
   replays `SS_DataWrite_2x`/`SS_Adr_2x`/`SS_wren_2x(savetype)` + `loading_savestate` into the core.
3. The `SS_*` wires are **internal** to `psx_top` — produced by `isavestates`, consumed by every
   sub-block (CPU `psx_top.vhd:1991`, GPU `:1632`, DMA `:1334`, …, SPURAM/VRAM/RAM `:1924`). They are
   **not ports** on `psx_top`/`psx_mister`, so a tb cannot drive them — the in-core loader owns them.
   *(This is why the plan's "instantiate `tb_savestates`" can't be used as-is in the full system:
   `tb_savestates.vhd` drives `SS_*` directly, which works only in the bare PSX UNIT benches where the
   sub-blocks are stood up standalone. In the full system you drive `load_state` and let `isavestates`
   produce `SS_*`. Same `.ss` format on both sides — `savestates.vhd` ⇄ `tb_savestates.vhd`.)*
4. The savestate DATA lives in the **`ddrram_model`** (the sim's DDR3 backing). The tb preloads the
   `.ss` there via `COMMAND_FILE_START_2`. Address derivation (so the in-core reads hit the preloaded
   words): `Softmap_SaveState_ADDR=0x3800000` DWORD → top `ddr3_ADDR = addr<<2 = 0xE000000` byte
   (`psx_top.vhd:2045 ss_ram_ADDR & "00"`) → `psx_mister DDRAM_ADDR(24:0)=ddr3_ADDR(27:3)=0x1C00000`
   (`psx_mister.vhd:312`) → `ddrram_model.intern_addr = DDRAM_ADDR(22:0) & '0' = 0x400000<<1 =
   **0x800000**` (`ddrram_model.vhd:46` — the model decodes ONLY `DDRAM_ADDR(22:0)`, so the high
   savestate address aliases deterministically to this low `data[]` word; no VRAM collision). The tb
   sets `COMMAND_FILE_TARGET = SS_WORD_BASE = 0x800000`.

Observability (read-only NVC external-name aliases, no DUT edit): `state_loaded`/`validSStates`
(real psx_mister ports), plus `psx_top.loading_savestate` and `psx_top.savestate_busy` → `ssload_probe.log`.

## `.ss` file format

Raw DDR savestate region: **1048576 little-endian 32-bit DWORDs = 4 MiB**, laid out per
`savestates.vhd` `savetypes` (CPU@1024, GPU@2048, …, SPURAM@131072, VRAM@262144, RAM@524288 — all
DWORD offsets). Header: byte word[0]=`header_amount`, **word[1]=`STATESIZE`=1048574 (0x000FFFFE)** —
the slot-valid magic the loader checks (`savestates.vhd:557,572`). This is identical to the file the
MiSTer firmware writes for a HW savestate and to what `ddrram_model` dumps as `ss_out.ss`.

## ⚠️ KNOWN LIMITATION — FASTSIM (is_simu) skips VRAM + RAM on a USER load

The harness must keep `is_simu='1'` (is_simu='0' stalls the boot at the reset vector — see
`sim/system573`). `is_simu` feeds `savestates FASTSIM`. In `LOADMEMORY_NEXT` (`savestates.vhd:588-590`)
a **user** load (`resetMode='0'`) with `FASTSIM='1'` loads savetypes **0..14** (CPU…SPURAM) but
**SKIPS VRAM(15) and RAM(16)**. So a `.ss` load under this harness restores
CPU/GPU-regs/GPUTiming/DMA/GTE/Joypad/MDEC/memctrl/Timer/SPU-regs/IRQ/SIO/Scratchpad/SPURAM —
but **NOT VRAM (textures/CLUTs/framebuffer) and NOT main RAM (game code/data)**.

Consequences + options for the garble per-draw work:
- The GPU resumes with the correct **draw-register state**, but the VRAM it samples/draws into is
  whatever the boot left, not the `.ss` VRAM. For a faithful per-draw render you need VRAM loaded.
- Option A (preferred next step): also preload the `.ss` **VRAM slice** (savetype 15, DWORD offset
  0x262144·4 in the file = 256 KiB region) straight into the `ddrram_model` low VRAM window via a
  second `COMMAND_FILE_START_2` (TARGET=0), bypassing the FASTSIM-skipped in-core VRAM load. Main RAM
  likewise can be staged into the `sdram_model3x` (savetype 16). This is a tb-only preload — no
  vendored edit — and is the natural Stage-1 extension once a real `.ss` is in hand.
- Option B: try `is_simu='0'` *for the replay only* (the boot-stall note is about cold boot; a load
  overwrites the CPU PC). Unproven; flagged as an experiment.

The harness still **fully de-risks the FSM**: it runs the complete load handshake end-to-end.

**Option A is now IMPLEMENTED** (tb generics `PRELOAD_VRAM`/`PRELOAD_RAM` + `VRAM_FILE`/`RAM_FILE`;
`run.sh` carves the slices with `tools/ss_vram_extract.py` and preloads them; auto-ON when a real
`.ss` is given). Addressing (verified): the VRAM slice → `ddrram_model` `TARGET=0` lands in
`data[0..0x3FFFF]` (the 1024×512 RGB555 window the GPU samples — `ddrram_model.vhd:359-374`); the
main-RAM slice → the main `sdram_model3x` `TARGET=0` lands at PSX phys 0 (`data[0]`; a RAM read
indexes `data[ram_Adr&~1]` with top bits "00" for phys 0, `memorymux.vhd:576/630`). Both disjoint
from the BIOS (`0x800000`) and the savestate region (`data[0x800000..]`). `FIX_POLY_DIV` (ships ON)
ports the `sim/gpu_replay` M5 tb-side repair so the POLY/LINE paths render under NVC (the same
inout-record `'U'`-poison would otherwise silently emit 0 pixels — see below).

## ⚠️⚠️ STAGE-1 RESULT (2026-06-07): the full-system replay DEADLOCKS on resume — bounded NEGATIVE

Ran with the real `local/hyperbbc_garble.ss` (Option A preload + load + FIX_POLY_DIV) out to 150 ms
sim time (~20 min wall). **The garble does NOT reproduce, and it cannot, because the resume
deadlocks the GPU/DMA before the CPU ever reaches the 320-quad band redraw.** Evidence (all
objective, via the `PCPROBE`/`GPUPROBE`/`DRAWTAP` external-name taps added here; flip them on):

1. **Load completes + CPU resumes correctly.** Load FSM runs to `state_loaded=1` at ~5.9 ms (SPURAM
   replay dominates). The CPU then executes REAL game code (554 distinct PCs, IRQs fire), so the
   RAM preload is faithful. The frozen PC `0x801391C0` is a VSync spin (`bne` on a flag at
   `0x8017BCC4` cleared by the vblank ISR); the CPU breaks out of it (ISR works).

2. **The CPU then spins on the GPU-DMA-busy bit and never advances.** It parks polling
   `D2_CHCR (0x1F8010A8) & 0x01000000` (GPU DMA ch2 start/busy) and `GPUSTAT & 0x04000000`
   (ReadyRecDMA) — waiting for the GPU DMA of the OT (which CONTAINS the band's 320 `0x2C` quads)
   to finish. It never finishes.

3. **The GPU is permanently STUCK mid-command (the deadlock).** From ~20 ms onward `GPUPROBE` shows
   a single stable terminal state: `procIdle=0` (a draw command is mid-flight) + `procReqFifo=1`
   (the active drawer is requesting more FIFO words) + `fifoEmpty=1` + `dmaOn=0` (FIFO empty, DMA
   off → the words never come). `procIdle` returns to 1 **zero** times after 20 ms; **zero** new GPU
   pixels are written (the `gra` stays exactly the preload size). `polyReqFifo=0 rectReqFifo=0` at
   the stall, so the stuck drawer is a **non-poly block-transfer/fill** (cpu2vram / vram2vram /
   fill / line) that consumed its opcode but not its parameter words.

**Root cause = a savestate-resume mid-DMA inconsistency.** The `.ss` was captured with the GPU
mid-command and DMA ch2 mid-linked-list-transfer. FASTSIM restores the GPU **registers** (incl. the
mid-command `proc_idle=0`) but the **in-flight DMA pointer/count** + the partially-filled GPU
command FIFO do not resume coherently, so the drawer waits forever for FIFO words DMA will never
deliver → `proc_done` never fires → `D2_CHCR` busy never clears → CPU spins → the band redraw is
never reached. This is independent of (and upstream of) the garble; the cold `sim/gpu_replay` rig
remains the only tool that actually rasterises the band quads (it injects the GP0 stream directly,
bypassing the DMA/FIFO resume).

**So the disambiguator the plan wanted (live CLUT cache at the garble draw) is NOT obtainable from
this savestate via this path** — the live draw never executes. The established forensic chain stands
unchanged (cold rig M5: poly path + CLUT lookup are byte-faithful; the garble REQUIRES a green-ramp
CLUT live at draw time; no such CLUT exists in the `.ss` VRAM). Pinning (a) wrong-coord-upstream vs
(b) cache-staleness still needs the **live GPU CLUT-cache state at the real on-HW draw** (an on-HW
CLUT-cache probe), OR a *mid-frame* (not GAME-OVER-static) savestate captured when the GPU/DMA are
idle between frames (so the resume doesn't land mid-command), OR a vendored-edit that re-syncs the
DMA/FIFO on `state_loaded`. The harness + taps are in place for the latter two the moment such a
`.ss` exists.

Reproduce the negative:
```
# all taps on, run to 30 ms (the deadlock is fully established by ~20 ms):
DRAWTAP=1 PCPROBE=1 GPUPROBE=1 sim/system573_ssreplay/run.sh 30ms local/hyperbbc_garble.ss
tail build/gpuprobe.log     # -> the stable procIdle=0 procReqFifo=1 fifoEmpty=1 terminal stall
grep -c '^OUT' build/drawtap.log   # -> 0 (band never drawn)
```

## Run recipe

```
# De-risk (no real .ss yet): synthetic valid-header zero .ss is auto-generated.
sim/system573_ssreplay/run.sh 5ms

# With a REAL savestate captured from HW (Alt-F1 on the MiSTer, copy the .ss off the SD):
sim/system573_ssreplay/run.sh 5ms /path/to/hyperbbc_garble.ss

# Re-run the cached elaboration with a new stop-time / .ss (seconds, not minutes):
REUSE=1 sim/system573_ssreplay/run.sh 10ms /path/to/state.ss

# A/B a stock boot (no savestate) to compare the resume against:
LOAD_SS=0 sim/system573_ssreplay/run.sh 2ms

# Enable the per-draw GPU tap (drawtap.log; OFF by default):
DRAWTAP=1 sim/system573_ssreplay/run.sh 5ms /path/to/state.ss
```

Env knobs: `LOAD_AT` (when after reset to pulse `load_state`, default `"60 us"`), `TURBO`,
`SLOWVRAM`, `RAM8MB`, `PRELOAD` (Option A VRAM+RAM preload; auto-ON for a real `.ss`),
`DRAWTAP` (per-draw CLUT tap over the garble band → `drawtap.log`), `PCPROBE` (CPU-PC liveness →
`pcprobe.log`), `GPUPROBE` (DMA/GPU-FIFO/draw state → `gpuprobe.log`). Outputs land in `build/`
(gitignored): `gra_fb_out_vga.gra/.png` (640×480 displayed video), `gra_fb_out.gra/.png` (1024×512
raw VRAM), `ssreplay.log` (the load sequence), `ssload_probe.log` (the load-FSM handshake edges),
`drawtap.log`/`pcprobe.log`/`gpuprobe.log` (if the matching probe is on).

## Where to drop a real `.ss`

Pass the path as arg 2 (`run.sh <stop> <path.ss>`) — run.sh stages it into `build/state.ss`. If the
file is missing, run.sh synthesizes a valid-header zero `.ss` so the FSM still runs (the de-risk
path). A real `.ss` must be 4 MiB (1048576 LE dwords) with word[1]=0x000FFFFE, or `validSStates`
reads 0x0 and the load is a no-op (visible in `ssreplay.log` / `ssload_probe.log`).

## De-risk status (synthetic .ss)

ANALYZES + ELABORATES + RUNS clean in NVC (no errors; same benign warnings as `sim/system573`).
The load FSM runs end-to-end: reset-release auto-runs the resetMode init (`ss_busy=1`), the preloaded
`.ss` header VALIDATES (`validSStates=0x1`), the pulsed `load_state` is honored, and the core enters
the replay (`loading_savestate=1`) driving `SS_*` into the sub-blocks — no assertion/crash. See
`ssload_probe.log` for the timestamped handshake.
