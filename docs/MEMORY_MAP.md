# System 573 memory map

Transcribed from the community [psx-spx](https://psx-spx.consoledev.net/konamisystem573/)
documentation and cross-checked against MAME's `konami/ksys573.cpp`. All EXP1
accesses require the PS1 `EXP1` config register `0x1f801008 = 0x24173f47` and use
16-/32-bit transactions.

## Top-level windows

| Address range            | Function                                   |
|--------------------------|--------------------------------------------|
| `0x1f000000–0x1f3fffff`  | Bank-switched flash / PCMCIA               |
| `0x1f400000–0x1f40000f`  | Konami ASIC I/O registers                  |
| `0x1f480000–0x1f48000f`  | IDE bank 0 (ATAPI CD-ROM)                  |
| `0x1f4c0000–0x1f4c000f`  | IDE bank 1 (alternate status)              |
| `0x1f500000`             | Bank switch / security-cart control        |
| `0x1f520000`             | JVS ready-flag clear                       |
| `0x1f560000`             | IDE reset control                          |
| `0x1f5c0000`             | Watchdog clear                             |
| `0x1f600000`             | External digital outputs                   |
| `0x1f620000–0x1f623fff`  | M48T58 RTC + battery-backed RAM            |
| `0x1f640000–0x1f6400ff`  | Digital I/O board registers                |
| `0x1f680000`             | JVS MCU data output                        |
| `0x1f6a0000`             | Security cartridge output latch            |

## Konami ASIC I/O (`0x1f400000`)

### `0x1f400000` — control (write)
| Bits | Meaning                                   |
|------|-------------------------------------------|
| 0    | ADC DI                                     |
| 1    | ADC /CS                                    |
| 2    | ADC CLK                                     |
| 3–4  | Coin counter 1/2 energize                  |
| 5    | Audio amplifier enable                      |
| 6    | External audio input mute                   |
| 7    | SPU DAC enable                              |
| 8    | H8/3644 (18E) MCU response clock — pulsing steps the self-test response index (was mislabelled "JVS MCU reset") |

### `0x1f400004` — DIP / JVS / security status (read)
| Bits  | Meaning                          |
|-------|----------------------------------|
| 0–3   | DIP switches                     |
| 4–7   | H8/3644 (18E) MCU response nibble — the GX700 self-test clocks control bit 8 to step an index through the H8's 64-byte response ROM and compares this; 700A (`h8a01.bin`) = const `0xC`. (Was mislabelled "JVS MCU status/error" — the JVS serial path is separate, `0x1f680000`.) |
| 8–15  | Security cartridge I0–I7 inputs   |

### `0x1f400006` — misc inputs (read)
| Bits  | Meaning                                  |
|-------|------------------------------------------|
| 0     | ADC DO                                    |
| 1     | ADC SARS                                  |
| 2     | Security cart IO0 tristate state           |
| 3     | JVS port sense                            |
| 4–5   | JVSIRDY / JVSDRDY                          |
| 6–7   | Security cart IRDY / DRDY                   |
| 8–9   | Coin switches                              |
| 10–11 | PCMCIA card insertion                      |
| 12    | Service button                            |

### `0x1f400008` — JAMMA player controls (read)
| Bits | Meaning                                              |
|------|------------------------------------------------------|
| 0–7  | Player 2 (JAMMA X, Y, V, W, Z, a, b, U)               |
| 8–15 | Player 1 (JAMMA 20, 21, 18, 19, 22, 23, 24, 17)       |

### `0x1f40000a` — JVS MCU data input (read, valid when JVSIRDY)
### `0x1f40000c` / `0x1f40000e` — extra buttons
| Bits | Meaning                              |
|------|--------------------------------------|
| 8–9  | Player buttons 4–5                    |
| 10   | Test button                          |
| 11   | Player button 6                      |

## Bank switch / security control (`0x1f500000`, write)
| Bits | Meaning                                            |
|------|----------------------------------------------------|
| 4–5  | **Internal onboard-flash bank index (0–3)** — the 16 MB flash is 4×4 MB chips selected here. The 700A BIOS `set_bank_hi` (0x803ca188) writes `(idx&3)<<4`, i.e. ctl = 0x00/0x10/0x20/0x30 for banks 0/1/2/3. (Corrected 2026-06-05: the old "0–5 = 0–3 internal / 16–31 PCMCIA1 / 32–47 PCMCIA2" flat numbering CONTRADICTS the BIOS — the body-copy loader 0x803c2210 walks `set_bank_hi(2/1/0)`. `rtl/s573_flash.v` decodes this field as `bank[5:4]`.) |
| 0–3  | Low bank-select nibble (BIOS `set_bank_lo` 0x803ca108); = 0 for onboard-flash access. |
| 6    | Security cart IO0 direction (0 = input)             |
| 7    | CPLD signal (unknown)                              |

> PCMCIA card **presence** is reported via the read register `0x1f400006[11:10]` (driven absent in `emu.sv`), NOT via this bank field.

## Security cartridge latch (`0x1f6a0000`, write)
| Bits | Meaning                                  |
|------|------------------------------------------|
| 0–7  | D0–D7 output pins (latched, sets DRDY)    |

Inputs are read back through `0x1f400004` (I0–I7) and `0x1f400006`
(IO0 / IRDY / DRDY). The X76F041/X76F100 are bit-banged I2C-like: IO0 = SCL,
D0 = SDA. The ZS01 (a PIC16 a.k.a. NS2K001) replaces the EEPROM with an
obfuscated, CRC16-checked protocol. A DS2401 provides the cart's silicon serial
number.

## M48T58 RTC (`0x1f623ff0`–`0x1f623ffe`, BCD, low 8 bits)
| Address      | Register     | Bits / notes                       |
|--------------|--------------|------------------------------------|
| `0x1f623ff0` | Control      | 0–5 calibration, 6 read, 7 write   |
| `0x1f623ff2` | Seconds      | 0–6 sec, 7 stop                    |
| `0x1f623ff4` | Minutes      | 0–6                                 |
| `0x1f623ff6` | Hours        | 0–5 (24h)                          |
| `0x1f623ff8` | Day of week  | 0–2, 4 century                     |
| `0x1f623ffa` | Day of month | 0–5, 6 low-battery                  |
| `0x1f623ffc` | Month        | 0–4                                 |
| `0x1f623ffe` | Year         | 0–7 (00–99)                        |

The whole `0x1f620000` window below the clock bytes is 8 KB battery-backed SRAM.

## Watchdog (`0x1f5c0000`)
Any write clears the watchdog. If not cleared within the timeout the board resets.

## Digital I/O board (`0x1f640000`, DDR / later BEMANI)
| Address        | Function                                         |
|----------------|--------------------------------------------------|
| `0x1f640080`   | Magic (`0x1234` Konami / `0x573f` custom)         |
| `0x1f6400a0–a6`| MP3 start/end address (hi/lo)                     |
| `0x1f6400a8`   | MP3 frame counter / descrambler key1              |
| `0x1f6400aa`   | MP3 playback status / MAS3507D status              |
| `0x1f6400ac`   | MAS3507D I2C (bit 12 SDA, bit 13 SCL)             |
| `0x1f6400ae`   | MP3 feeder control (bits 13–15)                   |
| `0x1f6400b0–b8`| DRAM read/write address + data port               |
| `0x1f6400e0–e6`| Light output banks A/B/D                           |
| `0x1f6400ea`   | descrambler key2; `0x1f6400ec` key3               |
| `0x1f6400ee`   | DS2401 1-Wire (bit 12 r/w)                         |
| `0x1f6400f0–ff`| CPLD: DAC reset, FPGA status, bitstream upload     |

## ATAPI CD-ROM (`0x1f480000` / `0x1f4c0000`)
Standard IDE/ATAPI task-file registers (data, error/features, sector count,
LBA/CHS, drive/head, status/command). IRQ10 via CPLD, DMA channel 5 (manual sync,
PIO transfers).
