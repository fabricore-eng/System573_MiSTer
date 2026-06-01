# Full-system NVC boot harness (`tb_system573`)

The Phase-2 observability workhorse: the vendored PlayStation core (`psx_mister`,
with the System 573 EXP1 widening from `psx_patches/`) + the upstream pure-VHDL memory
models + a minimal behavioral 573 EXP1 responder, executing the **Konami BIOS** under
[NVC](https://www.nickg.me.uk/nvc/). NVC is used because the PSX core is VHDL-2008 and
no open-source tool co-simulates VHDL + Verilog in one kernel (see `docs/PHASE1_PSX.md`).

## Run

```sh
brew install nvc                       # one-time
sim/system573/run.sh [STOP_TIME] [RAM8MB]   # e.g. sim/system573/run.sh 2ms 1
```

It applies the `psx/` patches, builds the `psx`/`mem`/`tb` libraries, copies the
game-in-BIOS image (`dumps/bios/700a01(gchgchmp).22g` — boots with no CD/security) in as
`s573_bios.bin`, loads it to SDRAM byte `0x800000` (BIOS region 0), and runs. Outputs land
in the git-ignored `build/`:

- `bios_fetch.log` — SDRAM reads in the BIOS region (`0x800000+`) and main RAM: evidence the CPU is executing the BIOS.
- `exp1_trace.log` — every EXP1 access (addr / we / re / wdata / returned rdata): what 573 peripherals the BIOS touches.
- `gra_fb_out_vga.gra` (composited video-out, 640×480) and `gra_fb_out.gra` (raw VRAM, 1024×512) — convert with `tools/gra2png.py <in.gra> <out.png>`.

NVC needs a large heap for the upstream memory models' big process arrays (`run.sh`
passes `-M 3g -H 6g`).

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

**Reproducible furthest point (clean runs).** This is the SDRAM-model-latency wall, and it
is the honest, reproducible state — see the caution below:
- `run.sh 5ms 1` → the BIOS is still in the **4 MB RAM test** (PC `~0x1FC0040C–0x434`); the
  stride-patched test walks the range in 256 steps but each iteration is uncached (KSEG1)
  *and* kicks the watchdog over EXP1, so the test alone takes ~5 ms of sim.
- `run.sh ~20ms 1` → past the RAM test, in the **BSS/runtime clear loop** (`~0x1FC0046C`),
  also uncached.
- `exp1_trace.log` shows the watchdog kicks (`EXP1 WE addr=0x5C0000`) — EXP1 works.

**Caution / correction.** An earlier revision of this file claimed the BIOS "reaches main
init at `0x1FC05504`" and "polls GPUSTAT bit 28, alternating with GPUREAD". That was an
artifact of trace files clobbered by a detached background run writing `build/` concurrently
with foreground runs — it is **not** reproducible from a clean isolated run and has been
retracted. The taps are correct and will show main init once a run gets there; the gate is
sim speed (below), not the tooling.

The framebuffer is black (the GPU is scanning out blank video; nothing drawn yet).

**Next (Phase 3 — to the boot screen):**
1. **Sim speed is the gate.** The BIOS boot is dominated by *uncached* (KSEG1) memory work
   — the 4 MB RAM test, the BSS/runtime clears, and runtime copies — each access paying the
   SDRAM model's latency (TURBO only helps cached accesses, so it barely moves the boot).
   To reach main init in tractable sim: reduce the SDRAM-model latency for bring-up, and/or
   run the boot once long and check-point via the PSX core's savestate for fast iteration.
   (`ddrram_model` `SLOWTIMING=0` separately speeds the GPU VRAM path, relevant once drawing
   starts.)
2. With main init reached, identify what the BIOS polls (a read-completion-timed data tap —
   the current `io_trace` `data` samples `dataFromBusses` early and under-reports) and grow
   the VHDL EXP1 responder's read values past any watchdog/security/RTC/ASIC polls.
3. Drive to a non-black framebuffer (boot screen), compare against MAME `ksys573`, and add
   `tools/check_boot.py` milestone gating.
