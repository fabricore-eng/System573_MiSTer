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

This is **not** a finished, game-booting core. A complete System 573 core has to
sit on top of a full PlayStation 1 core (the kind of effort that took the MiSTer
PSX core years). This repo implements and **unit-tests** the 573-specific glue
that sits *around* a PS1, and provides clearly-marked integration stubs for the
PS1 itself.

| Module                         | File                  | State                  |
|--------------------------------|-----------------------|------------------------|
| DS2401 1-Wire serial number    | `rtl/ds2401.v`        | ✅ implemented + tested |
| ADC0834 serial ADC             | `rtl/adc0834.v`       | ✅ implemented + tested |
| M48T58 RTC + NVRAM             | `rtl/m48t58.v`        | ✅ implemented + tested |
| Watchdog timer                 | `rtl/watchdog.v`      | ✅ implemented + tested |
| Konami ASIC I/O register block | `rtl/s573_io.v`       | ✅ implemented + tested |
| EXP1 address decoder           | `rtl/s573_bus.v`      | ✅ implemented + tested |
| PS1 CPU/GPU/SPU subsystem      | `rtl/ps1_stub.v`      | 🔌 integration stub     |
| MiSTer top level               | `rtl/emu.sv`          | 🔌 wiring scaffold      |
| MAS3507D MP3 / Digital I/O     | —                     | 📋 documented, not impl |
| ATAPI CD-ROM                   | —                     | 📋 documented, not impl |

✅ = real RTL with a passing testbench. 🔌 = compiles/wires but is a placeholder.
📋 = specified in docs only.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the path from here to a booting core.

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

FPGA synthesis targets the standard MiSTer framework: the `sys/` directory is
where the [MiSTer-devel `Template_MiSTer`](https://github.com/MiSTer-devel/Template_MiSTer)
`sys` submodule belongs, and `rtl/emu.sv` is the `emu` top level it instantiates.

## License

RTL in this repository is released under the **GNU GPL v2** to match the MiSTer
framework it is intended to plug into. Hardware register details are transcribed
from the community [psx-spx](https://psx-spx.consoledev.net/konamisystem573/)
documentation and the MAME `ksys573` driver.
