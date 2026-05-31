# Roadmap

The honest path from this repository to a System 573 core that boots a game.

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
- [ ] Vendor in / submodule the MiSTer PSX core (`MiSTer-devel/PSX_MiSTer`)
- [ ] Replace `ps1_stub.v` with the real core's EXP1 master + video/audio
- [ ] Expose the EXP1 bus and route it through `s573_bus`
- [ ] Bring up the 512 KB Konami BIOS in place of the SCPH BIOS
- [ ] Map 4 MB main / 2 MB VRAM (the 573's enlarged memories vs. retail PS1)

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
            tested); wiring it as the flash backing + DDR3 store still to do
- [ ] Wire `s573_io` JAMMA inputs to the MiSTer `joystick`/keyboard HPS inputs
- [ ] Get the Konami BIOS to POST and reach the CD boot

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
- [ ] Analog I/O board variant
- [ ] JVS MCU emulation for later I/O
- [ ] Save/restore of NVRAM + security state to SD
- [ ] Per-game timing, video options, MiSTer OSD menu

Phases 1–5 are large. Phase 0 (this repo) is the part that is *done and
verified*; everything below is specified but unbuilt.
