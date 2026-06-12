# Konami System 573 — MiSTer FPGA core

A work-in-progress MiSTer FPGA core for the **Konami System 573**, the
PlayStation-based arcade board behind *Dance Dance Revolution* and the rest of
Konami's BEMANI line (as well as games like *GunMania* and *Hyper Bishi Bashi
Champ*).

## What this board is

The System 573 is, at its core, a Sony PlayStation:

| Block        | Part                              | Notes                              |
|--------------|-----------------------------------|------------------------------------|
| CPU          | Sony CXD8530CQ (MIPS R3000A)      | 33.8688 MHz, same as retail PS1    |
| GPU          | Sony CXD8561Q                     | 2 MB VRAM (retail PS1 has 1 MB)    |
| SPU          | Sony CXD2925Q                     | 512 KB sound RAM                   |
| Main RAM     | 4 MB                              | retail PS1 has 2 MB                |
| BIOS         | 512 KB Konami BIOS                | boots from CD-ROM / flash          |

On top of the PS1 it adds 573-specific hardware on the EXP1 bus:

- **Konami ASIC I/O** (`0x1f400000`) — JAMMA inputs, coin counters, ADC & security
  cartridge bit-bang lines, audio control.
- **ATAPI CD-ROM** (`0x1f480000`) — game data, booted per title.
- **Bank-switched flash / PCMCIA** (`0x1f000000`, control at `0x1f500000`).
- **Security cartridge** (`0x1f6a0000` + status in the ASIC) — per-game DS2401
  silicon serial number plus an X76F041 / X76F100 / ZS01 secured EEPROM.
- **M48T58 timekeeper** (`0x1f620000`) — battery-backed NVRAM + RTC.
- **ADC0834** serial ADC (bit-banged through the ASIC control register).
- **Watchdog** (`0x1f5c0000`) — resets the board if not kicked.
- **Digital I/O board** (`0x1f640000`, DDR & later BEMANI) — FPGA + **MAS3507D**
  MP3 decoder streaming encrypted audio, plus light outputs and its own DS2401.

The full register map (transcribed from psx-spx) lives in
[`docs/MEMORY_MAP.md`](docs/MEMORY_MAP.md).

## Status — honest accounting

**Latest milestone (2026-06-12): two games boot and run on real hardware.**
Game #1 **hyperbbc** (flash-only) boots, runs, and has audio. Game #2
**hypbbc2p** (*Hyper Bishi Bashi Champ 2P*) — the first **CD-install** title —
now **boots and runs on real hardware** (de10): the authentic `gx908ja.u1`
security cassette clears the on-screen `-11N` BIOS signature wall, the CD/ATAPI
installer copies the disc to onboard flash (the **first hardware exercise of the
CD path**, previously sim-only), the flash programs, the in-game ROM check passes,
and the attract/demo loop runs. So the **security-cassette + CD-install path is
validated on hardware**. Note: hypbbc2p requires the real `gx908ja.u1` dump —
the BIOS reads a boot-time cassette **signature** (cassette block 1) that is
authentic-dump data, not synthesizable from game plaintext, so the real dump is a
required user-supplied artifact (treat it like a BIOS). The MAME-`BAD_DUMP`
`gx908ja.u1` (crc 8900eaff) is functionally complete and works.

The 573-specific hardware is **implemented and unit-tested**, the **PlayStation
core is integrated over EXP1**, the **Konami BIOS executes in full-system
simulation**, and — as of 2026-06-02 — **the core boots that BIOS and displays it
on real MiSTer hardware**: a built `.rbf` brings up the gchgchmp 573 BIOS; the color
bars (initially a CPU i-cache crash, fixed via `psx_patches/` 0004/0005) are now
passed and the BIOS reaches the GX700 power-on self-test (parked at CDR), with a
locked component signal on a CRT (Cyclone V, DE10-Nano-class; verified on a
SuperStation One). There's plenty
left — inputs, CD/security/flash, full game compatibility — but it is a real,
booting core now, not glue around a stub.

**Where it is right now (updated 2026-06-01):**

- **Phases 1 & 2 complete** (merged via reviewed PRs). The MiSTer PSX core
  (`psx/`, vendored as a pinned submodule) is wired to this fabric over the
  PlayStation **EXP1** bus, widened to a full 16-bit master with IRQ10. Those core
  edits live as isolated patches in `psx_patches/`, re-applied by
  `tools/apply_psx_patches.sh` — the submodule pin never moves.
- A **full-system simulation harness** (`sim/system573/`) boots the **Konami
  BIOS** on the integrated core under [**NVC**](https://www.nickg.me.uk/nvc/) (the
  PSX core is VHDL-2008, which Verilator cannot consume — see
  [`docs/PHASE1_PSX.md`](docs/PHASE1_PSX.md)). Verified: the CPU runs from the
  reset vector through the 4 MB RAM test, BSS clear, **main init (`0x1FC05504`)**
  and **GPU init** (the GPUSTAT poll resolves), kicking the 573 watchdog over EXP1
  throughout. `tools/check_boot.py` gates these milestones.
- **Phase 3 — BIOS self-tests on hardware:** the color bars turned out to be a CPU
  i-cache *crash* (wrong instruction word on the cached KSEG0 BIOS mirror), now fixed
  by `psx_patches/` 0004 (i-cache redirect) + 0005 (run BIOS fetches uncached). With
  the 18E (H8/3644) I/O-MCU self-test answered (`rtl/s573_io.v`, PR #16), the BIOS boots
  past the color bars to the GX700 power-on self-test on real hardware. The self-test
  is a sequential gate, now parked at CDR (CD-ROM), the next check. Sim speed was the
  Phase-3 frontier earlier but is no longer the blocker.
- **Phase 4 (hardware) — boots on real hardware:** `rtl/emu.sv` is the real MiSTer
  top — a clone of the proven `psx/PSX.sv` with the 573 EXP1 deltas — and the design
  builds a `.rbf` (Quartus Prime Lite 17.0.x on x86-64 Linux; the `raetro/quartus:17.0`
  Docker image works — Quartus 17.0 is required for this Cyclone V part) that **boots
  the Konami BIOS past the color bars (an i-cache crash now fixed) to the GX700
  power-on self-test, parked at the CDR check**. Getting
  there fixed the Quartus-hostile RTL (`synthesis translate_off`
  guards, M10K NVRAM, constant-folded flash) **and** two build-config defects found
  by an adversarial review — a mis-pinned bitstream (no pin-location files →
  `sys_pins.tcl`) and unmet timing (unsourced `psx/PSX.sdc`). clk_1x/clk_vid now
  meet; clk_2x is ~3 ns short at the worst corner (a polish item). See
  [`docs/PHASE4_HARDWARE.md`](docs/PHASE4_HARDWARE.md).

A complete System 573 core has to sit on top of a full PlayStation 1 (the kind of
effort that took the MiSTer PSX core years); this repo implements and
**unit-tests** the 573-specific glue around that PS1 and integrates a mature PS1
core underneath it.

| Module                         | File                  | State                  |
|--------------------------------|-----------------------|------------------------|
| DS2401 1-Wire serial number    | `rtl/ds2401.v`        | ✅ implemented + tested |
| ADC0834 serial ADC             | `rtl/adc0834.v`       | ✅ implemented + tested |
| ADC0838 8-channel serial ADC   | `rtl/adc0838.v`       | ✅ implemented + tested |
| M48T58 RTC + NVRAM             | `rtl/m48t58.v`        | ✅ implemented + tested |
| Watchdog timer                 | `rtl/watchdog.v`      | ✅ implemented + tested |
| Konami ASIC I/O register block | `rtl/s573_io.v`       | ✅ implemented + tested |
| EXP1 address decoder           | `rtl/s573_bus.v`      | ✅ implemented + tested |
| X76F100 security EEPROM        | `rtl/x76f100.v`       | ✅ implemented + tested |
| X76F041 security EEPROM        | `rtl/x76f041.v`       | ✅ implemented + tested |
| CRC-16/CCITT engine (ZS01)     | `rtl/crc16.v`         | ✅ implemented + tested |
| ZS01 (NS2K001) security PIC    | `rtl/zs01.v`          | ✅ implemented + tested |
| Digital I/O board registers    | `rtl/k573dio.v`       | ✅ lamps/RAM/keys/DS2401 |
| MP3 audio descrambler          | `rtl/k573_mp3dec.v`   | ✅ implemented + tested |
| MP3 streaming controller       | `rtl/k573_mp3stream.v`| ✅ implemented + tested |
| ATAPI task-file + PACKET + READ | `rtl/atapi.v`        | ✅ subset impl + tested |
| Bank-switched flash (NOR-backed) | `rtl/s573_flash.v`  | ✅ banking impl + tested |
| NOR flash command engine       | `rtl/flash_nor.v`     | ✅ implemented + tested |
| Security-cartridge bus glue    | `rtl/s573_seccart.v`  | ✅ implemented + tested |
| PS1 CPU/GPU/SPU subsystem      | `psx/` submodule      | ✅ integrated in sim (EXP1) |
| MiSTer top level               | `rtl/emu.sv`          | ✅ PSX.sv clone + 573 deltas; **boots BIOS on real hardware** |
| MAS3507D MP3 decode (Phase 9)  | —                     | 📋 documented, not impl |

✅ = real RTL with a passing testbench (or, for `psx/`, executing the BIOS in the
full-system NVC sim). 🏗️ = real RTL that synthesizes but isn't hardware-verified
yet. 📋 = docs only.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the phases and
[`docs/EXECUTION_PLAN.md`](docs/EXECUTION_PLAN.md) for the detailed plan from here
to full game compatibility (PSX integration, hardware bring-up on MiSTer, and the
ordered file/dump manifest in [`dumps/README.md`](dumps/README.md)).

## Building / testing

The 573-specific RTL is plain Verilog-2005 and is verified with
[Icarus Verilog](https://steveicarus.github.io/iverilog/):

```sh
cd sim
make            # run every testbench, report PASS/FAIL
make ds2401     # run a single module's testbench
```

On Ubuntu, `iverilog` comes from `apt-get install -y iverilog`. A Claude Code
`SessionStart` hook (`.claude/hooks/session-start.sh`, wired up in
`.claude/settings.json`) installs the toolchain and runs the suite automatically
at the start of each web session.

### Full-system boot simulation (NVC)

The PlayStation core is VHDL-2008 (Verilator can't consume it), so the
full-system boot runs under [NVC](https://www.nickg.me.uk/nvc/):

```sh
brew install nvc                          # one-time
sim/system573/run.sh [STOP_TIME] [RAM8MB] # e.g. sim/system573/run.sh 5ms 1
REUSE=1 sim/system573/run.sh 20ms         # re-run a built design at a new stop-time
```

It applies `psx_patches/`, builds the core under NVC, loads the Konami
game-in-BIOS image, runs, and writes traces + a framebuffer dump to the
git-ignored `sim/system573/build/`. Convert the framebuffer to PNG with
`tools/gra2png.py`, and check how far the boot got with:

```sh
tools/check_boot.py sim/system573/build   # report which boot milestones were reached
```

See [`sim/system573/README.md`](sim/system573/README.md) for the harness details
and the current furthest-verified point.

FPGA synthesis targets the standard MiSTer framework: the `sys/` directory is
where the [MiSTer-devel `Template_MiSTer`](https://github.com/MiSTer-devel/Template_MiSTer)
`sys` submodule belongs, and `rtl/emu.sv` is the `emu` top level it instantiates.

## License

RTL in this repository is released under the **GNU GPL v2** to match the MiSTer
framework it is intended to plug into. Hardware register details are transcribed
from the community [psx-spx](https://psx-spx.consoledev.net/konamisystem573/)
documentation and the MAME `ksys573` driver.
