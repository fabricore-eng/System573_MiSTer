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

## Status (Phase 2 gate: MET)

The Konami BIOS executes on the integrated core. At a ~3 ms run the traces show:
- **`bios_fetch.log`** — the CPU fetches the reset vector at `0x800000` (= phys
  `0x1FC00000`) and runs early POST with real branches (e.g. `0x800074`→`0x800188`); the
  periodic snapshot reaches `[snap] bios_reads=1962 ram_reads=38 last_ram_Adr=0x00800438`
  — `0x800438` is inside the BIOS main-RAM test loop (~`0x1FC00418`–`0x458`), with
  main-RAM read-backs (`ram_reads`) occurring, i.e. the 4 MB RAM test is running.
- **`exp1_trace.log`** — `EXP1 WE addr=0x5C0000 wdata=0x0001` (×2): stores landing on the
  573 watchdog (page 0x5c) — the first 573 peripheral POST touches, exactly as predicted.
  No EXP1 reads yet (the BIOS hasn't reached the security/RTC/ASIC polls).

The framebuffer is black (the GPU does not draw during early POST — the boot screen is the
Phase-3 milestone).

**Next (Phase 3 — BIOS POST):** the uncached 4 MB RAM test is the sim bottleneck (millions
of cycles); enable `TURBO_MEM` to accelerate it, then iterate the EXP1 responder's read
values past the security-cart / RTC / ASIC polls until the BIOS POSTs to a visible boot
screen. The responder currently returns benign `0` for reads (honoring the registered-slave
timing) and will grow per-peripheral responses as the BIOS demands them.
