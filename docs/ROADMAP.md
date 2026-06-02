# Roadmap

The honest path from this repository to a System 573 core that boots a game.

> **For the forward plan** (PSX integration → BIOS POST → first game → full game
> compatibility), including how I work autonomously against a locally-attached
> MiSTer and the ordered file/dump manifest, see
> [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md) and [`../dumps/README.md`](../dumps/README.md).
> This roadmap tracks the coarse phases; the execution plan is the working doc.

## Phase 0 — 573 glue (this repo)
- [x] EXP1 address decoder (`s573_bus`)
- [x] Konami ASIC I/O register block (`s573_io`)
- [x] DS2401 silicon serial number
- [x] ADC0834 serial ADC
- [x] M48T58 RTC + NVRAM
- [x] Watchdog
- [x] Unit testbenches for all of the above (Icarus Verilog)
- [x] MiSTer top-level scaffold + PS1 integration stub
- [x] Fabric wires all peripherals through `s573_bus`: ASIC I/O, RTC, watchdog,
      flash banking, ATAPI, Digital I/O, security cart (`system573_top`, tested)

## Phase 1 — sit on a real PlayStation core
The 573 is a PS1. The only sane way forward is to integrate an existing,
open PS1 core rather than re-implement R3000A + GTE + GPU + SPU from scratch.
See [`PHASE1_PSX.md`](PHASE1_PSX.md) for the concrete integration plan (EXP1
hook point, the 4 MB/2 MB deviations, IRQ10/DMA ch5, bring-up order).
- [x] Vendor in / submodule the MiSTer PSX core (`MiSTer-devel/PSX_MiSTer`,
      pinned; EXP1 widening + NVC-strictness fixes live in `psx_patches/`)
- [x] Replace `ps1_stub.v` with the real core's EXP1 master + video/audio
      (`rtl/emu.sv` = a clone of `psx/PSX.sv` with the 573 EXP1 deltas)
- [x] Expose the EXP1 bus and route it through `s573_bus` (widened to a full
      16-bit master + IRQ10; `system573_top` is the EXP1 slave)
- [x] Bring up the 512 KB Konami BIOS in place of the SCPH BIOS (executes in the
      NVC sim **and** on real hardware via the `games/PSX/boot.rom` path)
- [~] Map 4 MB main / 2 MB VRAM — 4 MB main RAM done (`ram8mb=1`, sim-validated);
      the 573's **2 MB VRAM** (vs the PSX core's 1 MB) is **not yet addressed**
      and is a candidate factor in the open video-output issue

## Phase 2 — make it boot
- [~] ATAPI CD-ROM block (task-file regs, packet command, IRQ10, DMA ch5)
      - [x] ATA task-file + ATAPI PACKET handshake, non-data + PIO data-in,
            INTRQ (`rtl/atapi.v`, tested; TUR/INQUIRY/READ CAPACITY)
      - [x] READ(10)/READ(12) sector streaming from a backing disc store (tested)
      - [ ] Back the disc store with a real CD image in MiSTer DDR3; DMA ch5
- [~] Bank-switched flash / PCMCIA backing store via MiSTer's DDR3
      - [x] Bank-switch control register + windowed banking (`rtl/s573_flash.v`,
            tested)
      - [x] AMD/Fujitsu NOR program/erase command engine (`rtl/flash_nor.v`,
            tested), wired as s573_flash's per-bank backing (writes go through
            the unlock/program/erase sequences); DDR3-backed store still to do
- [~] Wire `s573_io` JAMMA inputs to the MiSTer `joystick`/keyboard HPS inputs
      (conservatively routed in `emu.sv`: `joy[7:0]` → p1/p2; full JAMMA map TODO)
- [~] Get the Konami BIOS to POST and reach the CD boot — POSTs through RAM test,
      BSS clear, **main init** and GPU init in the NVC sim; gchgchmp (game-in-BIOS)
      needs no CD. **Open frontier:** no visible video yet (see below)

## Phase 3 — security & per-game
- [x] Security cart EEPROM: X76F100 bit-banged I2C (`rtl/x76f100.v`, tested)
- [x] Security cart EEPROM: X76F041 bit-banged I2C (`rtl/x76f041.v`, tested)
- [x] ZS01 (NS2K001) obfuscated + CRC16 protocol (`rtl/zs01.v`, tested)
      - [x] CRC-16/CCITT packet-integrity engine (`rtl/crc16.v`, tested)
      - [x] 12-byte command/response packet state machine
      - [x] Scramble/descramble cipher (custom rotate/add byte cipher, faithful
            to MAME's zs01.cpp; round-trip verified in sim)
      - [ ] Stretch: exercise the optional data-key (command bit2) descramble
            layer in the testbench (implemented, currently unexercised)
- [x] Security-cartridge bus glue (`rtl/s573_seccart.v`, tested): D0-D7 latch
      -> EEPROM SDA/SCL/CS/RST + board DS2401, IO0/I0 read-back
- [ ] Per-game DS2401 serials + installation cart handling
- [ ] M48T58 contents / "master calendar" handling

## Phase 4 — BEMANI Digital I/O board (DDR)
- [x] Digital I/O register block (`rtl/k573dio.v`, tested): light outputs,
      DRAM port (auto-incrementing read/write pointers), MP3 address window,
      descrambler key1/2/3 latches, board DS2401, ID/status words
- [x] Encrypted-audio descrambler datapath (`rtl/k573_mp3dec.v`, tested):
      both schemes (default + DDR SBM) with the running key schedule
- [x] MP3 streaming controller (`rtl/k573_mp3stream.v`, tested): reads board
      DRAM start..end, descrambles, emits the MP3 byte stream + FPGA status
- [ ] MAS3507D MP3 decoder + DAC path (the MP3->PCM decode itself; I2C stubbed)
- [ ] Stream music from CD/flash through the descrambler into the decoder

## Phase 5 — polish
- [~] Analog I/O board variant
      - [x] ADC0838 8-channel serial ADC (`rtl/adc0838.v`, tested)
      - [ ] Analog I/O board glue / JVS analog path
- [ ] JVS MCU emulation for later I/O
- [ ] Save/restore of NVRAM + security state to SD
- [ ] Per-game timing, video options, MiSTer OSD menu

Phases 1–5 are large. Phase 0 (the 573 glue) is *done and verified*, and
**Phase 1 (sit on a real PSX core) is complete** — the integrated core executes
the Konami BIOS in simulation **and boots + displays it on real MiSTer hardware**
(Cyclone V, 98% ALM / 100% DSP fit; see [`PHASE4_HARDWARE.md`](PHASE4_HARDWARE.md)).

## Hardware bring-up status — IT BOOTS (2026-06-01)
**The core boots the Konami BIOS and displays correctly on real hardware.** On a
SuperStation One the gchgchmp BIOS comes up to its test screen — clean SMPTE-style
color bars and a working menu — with a locked, perfect component signal on a CRT
(and a matching HDMI scaler capture). So the R3000 CPU runs from real SDRAM, the
GPU renders into VRAM, and video scans out end-to-end.

Getting there took fixing **two build-config defects** in the first `.rbf` (found
by the video-output investigation + the PR #14 adversarial review; the early
"runs on hardware" claim before these was wrong):

1. **Mis-pinned bitstream** — the project sourced the framework HDL (`sys.qip`)
   but *no* pin-location files, so all 145 board pins (SDRAM, HDMI, VGA…) were
   auto-placed to arbitrary balls. SDRAM mis-pinned ⇒ the BIOS couldn't run; VGA
   mis-pinned ⇒ the CRT wouldn't lock (the HPS side still worked, masking it).
   Fixed: `sys_pins.tcl`.
2. **Timing not met** — `psx/PSX.sdc` (the pll2→clk_vid generated clock + cross-
   PLL false-paths) was never sourced, so STA reported huge negative slack
   (clk_1x ~28.5 MHz vs the ~33.8 it needs). "0 A&S errors" ≠ timing met. Fixed:
   source `psx/PSX.sdc` — clk_1x and clk_vid now meet.

Notably, the simulation-side "black framebuffer" (Phase-3) turned out to be a
**sim artifact** (the NVC harness's behavioral EXP1 responder returns zeros); on
correctly-pinned, timing-met silicon the render→display path just works.

**Remaining polish / next:** clk_2x and the HDMI PLL are still ~2–3 ns short at
the worst (hot/slow) corner — the core works but is not fully timing-clean (98%
ALM congestion); drive the menu with real inputs (JAMMA mapping/polarity); then
CD / security-cart / flash for the broader library. Phases 2–5 below are still
largely unbuilt.
