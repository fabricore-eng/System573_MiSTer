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

**Phase-3 progress (in flight):** sim accelerators + observability taps are in place, and
the BIOS boots much further:
- `TURBO_MEM/COMP/CACHE='1'` and `FAST_RAMTEST=1` (the sim-only RAM-test stride patch)
  blow past the uncached 4 MB RAM test (otherwise ~10M+ cycles).
- A **CPU PC tap** (`pc_trace.log`, NVC external name into `icpu.pc`) and an **internal-I/O
  address tap** (`io_trace.log`, into `imemorymux`) give full execution + register-access
  visibility.
- With these, the BIOS clears the RAM test → BSS clear → runtime copies → **reaches main
  init at `0x1FC05504`** (confirmed in `pc_trace.log`), then enters a wait-with-timeout loop
  (BIOS subroutine ~`0x1FC044D4`) that **polls GPUSTAT (`0x1F801814`) bit 28** ("ready to
  receive DMA"), alternating with GPUREAD (`0x1F801810`) — see `io_trace.log`. So far the
  only 573-peripheral access is the watchdog; the BIOS has not yet reached the
  security/RTC/ASIC polls.

The framebuffer is still black (the GPU is scanning out blank video; nothing drawn yet).

**Next (Phase 3 — to the boot screen):**
1. Resolve the GPUSTAT-ready poll: verify the value the GPU returns (the current `io_trace`
   `data` field samples `dataFromBusses` slightly early, so it under-reports — add a
   read-completion-timed data tap), and confirm the PSX GPU asserts the ready bit given how
   the BIOS programs GP1 (display setup) in our harness.
2. Address the uncached-boot sim cost (each KSEG1 access is several cycles through the SDRAM
   model): options are reducing the model's latency for bring-up, or running the boot once
   and check-pointing via the PSX core's savestate for fast iteration afterward.
3. Then iterate the EXP1 responder past any security/RTC/ASIC polls and drive to a non-black
   framebuffer (boot screen), comparing against MAME `ksys573`; add `tools/check_boot.py`
   milestone gating. The responder currently returns benign `0` for reads (honoring the
   registered-slave timing) and grows per-peripheral responses as the BIOS demands them.
