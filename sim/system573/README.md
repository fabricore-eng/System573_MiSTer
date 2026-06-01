# Full-system NVC boot harness (`tb_system573`)

The Phase-2 observability workhorse: the vendored PlayStation core (`psx_mister`,
with the System 573 EXP1 widening from `psx_patches/`) + the upstream pure-VHDL memory
models + a minimal behavioral 573 EXP1 responder, executing the **Konami BIOS** under
[NVC](https://www.nickg.me.uk/nvc/). NVC is used because the PSX core is VHDL-2008 and
no open-source tool co-simulates VHDL + Verilog in one kernel (see `docs/PHASE1_PSX.md`).

## Run

```sh
brew install nvc                            # one-time
sim/system573/run.sh [STOP_TIME] [RAM8MB]   # e.g. sim/system573/run.sh 2ms 1
REUSE=1 sim/system573/run.sh 20ms           # re-run the built design at a new stop-time (seconds, not minutes)
tools/check_boot.py build                   # report which boot milestones were reached
```

It applies the `psx/` patches, builds the `psx`/`mem`/`tb` libraries, copies the
game-in-BIOS image (`dumps/bios/700a01(gchgchmp).22g` — boots with no CD/security) in as
`s573_bios.bin`, loads it to SDRAM byte `0x800000` (BIOS region 0), and runs. Outputs land
in the git-ignored `build/`:

- `bios_fetch.log` — SDRAM reads in the BIOS region (`0x800000+`) and main RAM: evidence the CPU is executing the BIOS.
- `pc_trace.log` — CPU PC tap (non-sequential PC changes + periodic snapshots): the execution position.
- `io_trace.log` — distinct PSX internal-I/O register accesses (`0x1F801xxx`): which GPU/SPU/timer/DMA/IRQ registers the BIOS touches.
- `exp1_trace.log` — every EXP1 access (addr / we / re / wdata / returned rdata): what 573 peripherals the BIOS touches.
- `gra_fb_out_vga.gra` (composited video-out, 640×480) and `gra_fb_out.gra` (raw VRAM, 1024×512) — convert with `tools/gra2png.py <in.gra> <out.png>`.

`run.sh` flags: `REUSE=1` skips the patch/analyze/elaborate and re-runs the already-built
design at a new `STOP_TIME` (RAM8MB/TURBO/FAST_RAMTEST are then fixed at the cached build's
values). `TURBO=0` / `FAST_RAMTEST=0` disable the bring-up accelerators for a realistic run.
NVC prints `--stats` (build vs run wall-clock) and suppresses the benign NUMERIC_STD
metavalue warnings (`--ieee-warnings=off`). It needs a large heap for the upstream memory
models' big process arrays (`-M 3g -H 6g`).

**`tools/check_boot.py build`** parses these traces and reports which BIOS boot milestones
were reached — `reset → ram_test → watchdog → bss_clear → copy_loop → main_init →
gpustat_poll → gpustat_done → draw → framebuffer`. `--require KEY` gates a phase (exit 1 if
a milestone is missing); `--compare BASELINE_DIR` confirms a change (e.g. a sim accelerator)
didn't regress the boot (every baseline milestone still reached, PC-milestone order
preserved).

## Status

**Phase-2 gate: MET.** The Konami BIOS executes on the integrated core — `bios_fetch.log`
shows the CPU fetching the reset vector at `0x800000` (= phys `0x1FC00000`) and running,
and `exp1_trace.log` shows stores landing on the 573 watchdog (`EXP1 WE addr=0x5C0000`,
page 0x5c) — proving the EXP1 routing end-to-end.

**Phase-3 progress (in flight):** sim accelerators + observability taps are in place.

- `FAST_RAMTEST=1` (sim-only RAM-test stride patch, build/ copy only) + `TURBO=1`
  (`TURBO_MEM/COMP/CACHE`; set `TURBO=0` for realistic timing).
- A **CPU PC tap** (`pc_trace.log`, NVC external name into `icpu.pc`) and an **internal-I/O
  address tap** (`io_trace.log`, into `imemorymux`) give full execution + register-access
  visibility.

**Furthest point (verified, clean single-writer runs).** The boot is *slow but progressing*;
the position depends purely on how long you run:
- `run.sh 5ms 1` → still in the **4 MB RAM test** (PC `~0x1FC0040C–0x434`); the stride-patched
  test walks the range in 256 steps, each iteration uncached (KSEG1) *and* kicking the
  watchdog over EXP1, so the test alone takes ~5 ms of sim.
- `~20 ms` → past the RAM test, in the **BSS/runtime clear loop** (`~0x1FC0046C`), also uncached.
- `run.sh 150ms 1` → **reaches main init at `0x1FC05504`** (and the `0x5130–0x5534` range —
  confirmed in `pc_trace.log`), performs **GPU init including a GPUSTAT/GPUREAD poll
  (`0x1F801814`/`0x1F801810`) that RESOLVES** after ~17 iterations (`io_trace.log`; *not* a
  stuck spin), then grinds a large **uncached BIOS→RAM copy** (`~0x1FC004D4`, ~36 KB) — the
  current sim-time sink. Watchdog kicks throughout (`exp1_trace.log`); EXP1 works.

The framebuffer is still black (no draw yet) — the boot hasn't reached the drawing stage.

> **Note on an earlier correction.** A prior revision documented "reaches main init / polls
> GPUSTAT" *at a much shorter stop-time*, from traces **clobbered** by a detached background
> run writing `build/` concurrently with foreground runs. The PR-#9 review correctly flagged
> it as non-reproducible at 5 ms. The clean 150 ms single-writer run above now **verifies the
> substance** (main init *is* reached, GPUSTAT *is* polled) — the original error was the
> timing/clobbering, not the conclusion. Always run single-writer to `build/`.

**Next (Phase 3 — to the boot screen):**
1. **Sim speed is the sole gate.** The boot is dominated by *uncached* (KSEG1) memory work —
   the 4 MB RAM test, the BSS/runtime clears, and the runtime copies — each access paying the
   SDRAM model's latency (~hundreds of core cycles; TURBO only helps *cached* accesses, so it
   barely moves the boot). The `~36 KB` copy at `0x4D4` alone is most of a 150 ms run. To get
   past the copies to the drawing stage in tractable sim: reduce the SDRAM-model latency for
   bring-up (carefully — the core's cache/DMA timing assumes the model's `done` cadence), or
   run the boot once long and check-point via the PSX core's savestate for fast iteration.
   (`ddrram_model` `SLOWTIMING=0` separately speeds the GPU VRAM path, relevant once drawing
   starts.)
2. Once past the copies, grow the VHDL EXP1 responder's read values as the BIOS reaches any
   security/RTC/ASIC polls (so far only the watchdog is touched; the GPUSTAT poll already
   resolves). For confirming exact polled values, add a read-completion-timed data tap — the
   current `io_trace` `data` samples `dataFromBusses` early and under-reports.
3. Drive to a non-black framebuffer (boot screen) and compare against MAME `ksys573`.
   Milestone gating exists (`tools/check_boot.py`); the `draw`/`framebuffer` gates fire once
   the GPU renders. Confirm the integration once under `TURBO=0`.
