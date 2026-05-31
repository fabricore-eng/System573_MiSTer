# Architecture & scope

## Why the System 573 fits MiSTer

The System 573 *is* a Sony PlayStation (PS1) with extra arcade peripherals, and
PS1-class hardware is firmly within MiSTer's reach — a mature MiSTer PSX core
already exists, which makes the 573 an honest, reachable target. MiSTer runs on a
Terasic DE10-Nano: an Intel Cyclone V SE (5CSEBA6), ~110K logic elements,
~5.5 Mbit of on-chip RAM, paired with 128 MB of DDR3 (used as the framebuffer /
cartridge / disk store) — comfortably enough for a PS1-class core and the 573's
surrounding logic. The board is also exhaustively documented by MAME and psx-spx,
so the peripheral behavior is known rather than guessed.

## Block diagram

```
                 ┌───────────────────────────────────────────────┐
                 │                 PlayStation core               │
                 │  R3000A CPU ── GTE ── DMA ── GPU(2MB VRAM)      │
                 │       │                       SPU(512KB)        │
                 │   main 4MB                                      │
                 └───┬───────────────────────────────────────────┬┘
                     │ EXP1 bus (cs at 0x1f400000.. )             │ video/audio
        ┌────────────┴─────────────────────────────┐             ▼
        │            s573_bus  (decoder)            │        MiSTer scaler
        └─┬───┬────┬────┬────┬────┬────┬────┬───────┘
          │   │    │    │    │    │    │    │
       s573_io│ m48t58│ wdog│ secart│ digio│ atapi│ flash/pcmcia
          │   │    │    │    │    │
       JAMMA │  RTC/  │  reset│ DS2401 + X76/ZS01    MAS3507D MP3
       coins │  NVRAM │       │ adc0834              + light outs
       audio │
```

## Module responsibilities

### `s573_bus.v` — EXP1 address decoder
Takes a CPU physical address (masked to the `0x1fxxxxxx` region) plus a read/write
strobe and produces one-hot chip selects for each 573 peripheral window. This is
the spine the rest of the core hangs off. Pure combinational; fully tested.

### `s573_io.v` — Konami ASIC I/O register block (`0x1f400000`)
The board's central I/O latch. Holds the write-only control register (ADC bit-bang
lines DI/`/CS`/CLK, coin-counter energize, audio amp/mute/DAC enable, JVS MCU
reset) and muxes the many read-only input words: DIP switches, JAMMA player 1/2
controls, security-cartridge I0–I7 inputs and IRDY/DRDY handshake, ADC DO/SARS,
coin and service/test buttons. Tested against the bit assignments in
`docs/MEMORY_MAP.md`.

### `ds2401.v` — Dallas/Maxim DS2401 silicon serial number
A 1-Wire *slave*. Real System 573 security carts (and the Digital I/O board)
carry a DS2401 whose 64-bit ROM (8-bit family `0x01` + 48-bit serial +
8-bit Maxim CRC) the BIOS bit-bangs out and checks. Implemented as a clocked
1-Wire slave that answers a reset/presence handshake and the `Read ROM` (`0x33`)
command, computing the CRC8 internally. Tested with a bit-banging master model.

### `adc0834.v` — National ADC0834 4-channel serial ADC
The 573 reads analog inputs (e.g. volume) through an ADC0834 bit-banged on the
ASIC control register. Implemented as the ADC's `/CS`/CLK/DI/DO serial slave:
shifts in the start bit + channel-select, then shifts out the conversion MSB-first.
Conversion values are provided by a test/host port. Tested end-to-end.

### `m48t58.v` — ST M48T58 timekeeper
8 KB of battery-backed SRAM with the real-time clock mapped into the top 16 bytes
(`0x1f623ff0`–`0x1f623ffe`, BCD, byte accesses on a 16-bit bus). Implements the
read/write-mutex "freeze" bits that latch a coherent time snapshot, a 1 Hz tick
that advances seconds→year with correct carry, and the NVRAM array. Tested for
NVRAM persistence and for clock roll-over.

### `watchdog.v` — board watchdog
Free-running counter that asserts a reset pulse if the CPU does not strobe the
clear window (`0x1f5c0000`) within the timeout. Tested both for "kept alive" and
"allowed to bite".

### `ps1_stub.v` / `emu.sv` — integration scaffolding
`ps1_stub.v` documents and stubs the PlayStation core's external interface (clock,
reset, EXP1 master, video, audio) so the 573 glue can be wired and elaborated
without pulling in a multi-thousand-line PSX core. `emu.sv` is the MiSTer `emu`
top-level: it shows where `sys/sys_top.v`, the PS1 core, and `s573_bus` connect.
Neither is a functional CPU — both are explicitly placeholders.

## Clocking

- `clk_sys` — core/EXP1 bus clock. The bit-bang peripherals (DS2401, ADC0834)
  are parameterized by `CLK_FREQ_HZ` so their microsecond-scale timing is derived
  from whatever this clock actually is; the testbenches run them at a low
  synthetic frequency so simulations finish quickly.
- A real build would also bring up the ~33.8688 MHz PS1 CPU/GPU domain inside the
  PS1 core; that is out of scope for the stub.
