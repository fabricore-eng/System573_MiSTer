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

The 573-specific hardware is **implemented and unit-tested**, the **PlayStation
core is integrated over EXP1**, the **Konami BIOS executes in full-system
simulation**, and the **MiSTer hardware top now synthesizes** — the full
`emu | psx_mister | …` hierarchy passes Quartus Analysis & Synthesis for the
DE10-Nano (Cyclone V), and the `.rbf` build is running. It is not yet a verified
game-booting bitstream, but the core is well past "glue around a stub."

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
- **Phase 3 in progress:** driving the boot to a non-black framebuffer (the boot
  screen). The current bottleneck is *simulation speed* — early boot runs uncached
  (KSEG1) and is dominated by the SDRAM model's per-access latency.
- **Phase 4 (hardware) in progress:** `rtl/emu.sv` is now the real MiSTer top — a
  clone of the proven `psx/PSX.sv` with the 573 EXP1 deltas — and the whole design
  **synthesizes** in Quartus 17.0 (via Colima/Docker on the build Mac, using a 30 GB
  swap on the data disk for the PS1 core's memory-heavy A&S). Getting there fixed
  the Quartus-hostile RTL: clocked full-array writes are guarded with `synthesis
  translate_off`, the M48T58 NVRAM reads synchronously so it infers M10K, and flash
  is read-only in synthesis (constant-folded) for first boot. The `.rbf` build
  (map→fit→asm→sta) is running; see [`docs/PHASE4_HARDWARE.md`](docs/PHASE4_HARDWARE.md).

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
| MiSTer top level               | `rtl/emu.sv`          | 🏗️ PSX.sv clone + 573 deltas; **synthesizes**, `.rbf` building |
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
