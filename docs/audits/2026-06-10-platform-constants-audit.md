# Platform-constants audit — full sweep, 2026-06-10

**Process doc:** `~/Dev/tools/docs/PLATFORM_CONSTANTS_AUDIT.md` (Gate 0).
**Living table:** `PLATFORM.md` at the repo root (this file is the frozen sweep record; the
table below is the snapshot as of this date — future edits land in PLATFORM.md).

## Scope

Every platform constant MAME 0.288 (tag `mame0288`) encodes for the Konami System 573
(`src/mame/konami/ksys573.cpp` + the device files it instantiates: cpu/psx, video/psx,
sound/spu, machine/timekpr, machine/k573cass...), diffed against our core: `rtl/emu.sv` +
`rtl/*.v` + `psx_patches/` over the pristine vendored consumer-PSX core (`psx/`). Worktree
audited: `feat-flash-load` lineage (psx_patches through 0020). 38 rows across 11 subsystems:
CPU/clocks/memory, GPU/video, DMA, SPU, BIOS, ATAPI/CD, NVRAM/RTC, flash/PCMCIA/EXP1,
573 register map & I/O, expansion boards, game config, plus core-internal load-bearing
constants with no MAME analog.

## Method

Per the hub doc's three ground-truth sources, every row cites BOTH sides or is marked UNKNOWN:

1. **MAME machine-config source** — driver + device files at tag mame0288, cited
   `file#Lline` (verified against raw.githubusercontent.com/mamedev/mame/mame0288/...).
2. **Artifact sizes as witnesses** — `ls -l` / `unzip -l` byte counts of MAME dumps, ROM zip
   members, our core's captures and packed images (the 2 MB VRAM answer sat in `ls -l` for
   weeks; this sweep treats file sizes as first-class citations).
3. **What the platform's software does at boot** — config registers the BIOS programs
   (ram_config nibble, EXP1 width), self-test ranges, bank values.

RTL citations are the file:line of the parameter, signal width, or address slice — declarations
grepped, not READMEs trusted. Candidate NEW mismatches were adversarially verified by an
independent lane (both citations re-fetched + re-read, core-side wiring re-traced) before
being recorded as real.

## Motivating case: four constants-class bugs, found the hard way first

This audit exists because the project hit the same bug-class FOUR times before anyone diffed
the platform's basic numbers (hub doc "the 2MB lesson"):

| # | Bug (cost) | The constant that was never diffed | Fix state at sweep time |
|---|---|---|---|
| 1 | Savestate forensics blinded (days) | Main RAM: MAME 4 MB, mirror window mask 0x3fffff (`ksys573.cpp#L2600`, `cpu/psx/psx.cpp#L1353-L1401`) / core runs ram8mb=1 → 8 MB linear (`rtl/emu.sv:1167`) | **STILL UNFIXED** (latent; pristine PSX core has no 4 MB mode) |
| 2 | Graphics garble — THE garble (weeks) | VRAM: MAME 2 MB / 1024 rows (`video/psx.cpp#L490-L491`; dumps = 2,097,152 B) / core 9-bit Y = 512 rows = 1 MB (`gpu_cpu2vram.vhd:44`; our dumps = 1,048,576 B) | **FIX-IN-FLIGHT** (patch 0021 pending; 0020 is the latest applied) |
| 3 | Boot stall at ROM check (days + a false-milestone confound) | Flash bank decode: MAME uses the raw control value 0..3 (`ksys573.cpp#L1141`) / core assumed shifted ctl[5:4] | **FIXED** (6b29c37, HW-confirmed: game boots+runs) |
| 4 | NVRAM self-test red-N (days) | ioctl word width: hps_io WIDE(1) = 16-bit words (`sys/hps_io.sv:28,35`) / loader wrote only the low byte | **FIXED** (7f335d7, HW-confirmed: red-N gone) |

One class: *the platform differs from the base core's home platform by a number, and the
number was assumed instead of read.*

## Tally

38 rows: **26 MATCH · 3 KNOWN-BUG · 2 FIX-IN-FLIGHT · 1 MISMATCH (new) · 6 UNKNOWN.**

## The table (frozen snapshot, 2026-06-10)

### CPU, clocks & main memory

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| Main CPU + master clock | CXD8530CQ @ XTAL(67'737'600) (67.7376 MHz crystal; internal /2 → 33.8688 MHz CPU clock) | ksys573.cpp#L2595 (+ board layout L163, L217) | PLL clk1x=33.8688 / clk2x=67.7376 / clk3x=101.6064 MHz from 50 MHz ref; PSX core runs on the post-/2 33.8688 master clock; CLK_FREQ_HZ=33_868_800. Representation difference only; clk_2x ~3 ns short worst corner (psx/PSX.sdc patched). | psx/rtl/pll/pll_0002.v:25-34; rtl/emu.sv:226-233, 1151-1153, 1757 | MATCH |
| Main RAM size + mirror window (ram_config 0x1f801060) | 4 MB ("4M"; 8× KM48V514); BIOS programs config nibble 0xC → 4 MB mirrored window, effective CPU mask 0x3fffff (reset default 0x800 = 2 MB window); MAME full-RAM dumps exactly 4,194,304 B | ksys573.cpp#L2600 (+L235); cpu/psx/psx.cpp#L1353-L1401, L1760, L2000; `ls local/mame_gate_hunt/gh_ram_*.bin` = 4194304 | ram8mb=1'b1 → 8 MB linear (inline comment falsely claims 4 MB); addr[24:23] pass through, no 4 MB mirror; DMA wrap mask also keyed on ram8mb; pristine PSX core offers only 2 MB or 8 MB, no patch adds a 4 MB mode | rtl/emu.sv:1167; psx/rtl/psx_top.vhd:1353-1355; psx/rtl/dma.vhd:740 | KNOWN-BUG #1 (UNFIXED) |
| Scratchpad + ROM window | 1 KB scratchpad at 0x1f800000-0x1f8003ff; ROM window 1<<((rom_config>>16)&0x1f) clamped to 4 MB | cpu/psx/psx.cpp#L1746, L1336-L1350, L1404-L1411 | Pristine consumer PSX path (no patch); weak ours-side cite, but games execute, which exercises the scratchpad | psx/ vendored | MATCH |
| IRQ controller | 11 lines (intin0..10) at 0x1f801070; GPU vblank on intin0; PSX_IRQ_MASK 0x7fd log-only | cpu/psx/irq.cpp#L17,L79 + irq.h#L29-L39; psx.cpp#L1762 | Pristine PSX IRQ block; 573 adds only the exp IRQ10 wiring | psx/ vendored (no patch) | MATCH |

### GPU / video

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| GPU device variant (gputype) | CXD8561Q → gputype 2 (8514Q/8561Q/BQ/CQ/8654Q all type 2; only CXD8538Q is type 1); GP1(0x10) info 07 returns 2; MAME models zero type-2 revision differences | ksys573.cpp#L2633; video/psx.cpp#L62-L69, L3371-L3373 | Vendored PSX core = consumer type-2 coordinate layout (no type-1 exists in it). Real-silicon 8561Q/BQ/CQ dither/blend deltas not in MAME — needs another source if ever relevant. | psx/rtl/gpu.vhd (pristine) | MATCH |
| GPU / video clock | GPU XTAL(53'693'175) | ksys573.cpp#L2633 | clk_vid = 53.693175 MHz (pll2 NTSC base; runtime-reconfig PAL/FF) | psx/rtl/pll2/pll2_0002.v:25,30; rtl/emu.sv:236-241, 2035 | MATCH |
| VRAM size / row count | 0x200000 (2 MB) = 1024 rows × 1024 px × 2 B (width hardwired 1024; height=(vramSize/1024)/2; Y via p_p_vram[n%height]); MAME VRAM dumps exactly 2,097,152 B | ksys573.cpp#L2633; video/psx.cpp#L490-L491, L509-L510, psx.h#L263; `ls local/mame_gate_hunt/gh_vram_*.bin` = 2097152 | 9-bit Y = 512 rows = 1 MB (pixelAddr = row[8:0] & col[9:0] & '0'); every core VRAM capture exactly 1,048,576 B (3 independent dumps) = half of MAME's. Y bit 9 aliases rows 512-1023 onto 0-511 — THE garble. | psx/rtl/gpu_cpu2vram.vhd:27,44,61,122,126; psx/rtl/gpu.vhd:198-199; psx/rtl/gpu_vram2vram.vhd:68,70; `ls local/glyph_dma/vram_de10_full.bin, vram_run3.bin` = 1048576 | KNOWN-BUG #2 / FIX-IN-FLIGHT (patch 0021 pending) |
| GPU Y-coordinate field widths (gputype 2) | E3/E4 drawarea Y = 10-bit at bit 10; E5 offset Y = 11-bit signed at bit 11; GP1(05) display-start Y = 10-bit at bit 10; texpage TWO Y bits (bit4=Y256, bit11=Y512 → GPUSTAT bit 15); CLUT Y = full 10 bits; reset drawarea (0,0)-(1023,1023) | video/psx.cpp#L3197-L3232, L3294-L3303, L826-L845, L1544-L1545, L3498-L3523 | 9-bit Y throughout (drawingAreaTop/Bottom, vram2vram src/dst, cpu2vram dst); CLUT probe patches 0012-0019 retain 9-bit. Fix scope = patch 0021: 10th bit on every Y field + texpage bit11 + GPUSTAT bit15. CAUTION: MAME's raw 16-bit A0/C0 W/H + atomic DMA are MAME quirks, NOT real-HW truth — don't copy into RTL. | psx/rtl/gpu.vhd:198-199; psx/rtl/gpu_vram2vram.vhd:68,70; psx/rtl/gpu_cpu2vram.vhd:44; psx_patches/ (no Y-width change through 0020) | FIX-IN-FLIGHT |
| GPU DMA channel + VBLANK IRQ | GPU = DMA ch2 (read+write); vblank → psxirq intin0 | video/psx.cpp#L40-L42 | Pristine dma.vhd ch2 = GPU; HW-measured bit-exact dma→gpu vs MAME (write-side verdict 2026-06-10) | psx/rtl/dma.vhd:50-75 (no patch) | MATCH |

### DMA

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| DMA channel map (consumer channels) | ch2=GPU, ch4=SPU, ch6=OTC (end marker 0xffffff); 7 channels; n_adrmask = ramsize-1 | video/psx.cpp#L40-41; sound/spu.cpp#L941-942; cpu/psx/dma.cpp#L38,L47,L124,L320-L336 | Pristine 7-channel dma.vhd, same assignments; consumer CD ch3 read data tied to zero (patch 0011); MDEC dormant. adrmask facet wrong only via the ram8mb known bug. | psx/rtl/dma.vhd:50-75; psx_patches/0011 | MATCH |
| DMA request-mode (sync 1) block semantics | words = BS × BA, BA==0 → 0x10000 wrap; MAME executes transfers atomically (quirk, not HW truth) | cpu/psx/dma.cpp#L127-L136, L249-L256 | Pristine dma.vhd; witnessed: boot font upload (GP0 A0 + ch2 REQUEST mode) crosses dma→gpu BIT-EXACT vs MAME on real HW (SignalTap 2026-06-10). Source path exonerated; remaining garble bug is inside GPU cpu2vram→VRAM (512-row aliasing). | psx/rtl/dma.vhd (pristine); memory garble-fix-plan 5p | MATCH |
| **ATAPI DMA channel (ch5)** | 573 wires CD/ATAPI DMA to PSX DMA ch5 (psxdma install_read/write_handler ch5); BIOS CD-boot depends on it (CYCLES_PER_SECTOR floor ≥2000 "or the BIOS ends up out of order") | ksys573.cpp#L2597-L2598, L391, L1193 | NOT implemented — ATAPI is PIO-only over EXP1; no psx_patch hooks ATAPI into dma.vhd; vendored dma.vhd:363 hard-wires ch5 request to '0' and the trigger block (L368-373) omits ch5 — ch5 can NEVER fire | rtl/atapi.v:5-8,27-49; rtl/system573_top.v:201-208; psx/rtl/dma.vhd:363,368-373 | **MISMATCH (NEW, verified — latent)** |

### SPU / audio

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| SPU clock + RAM size | SPU @ 67.7376/2 = 33.8688 MHz, stereo; spu_ram_size hardwired 512 KB (consumer-same; board "SPUDR4M" KM416V256) | ksys573.cpp#L2640, L2644 ctx, L234; sound/spu.cpp#L125 | 512 KB (19-bit byte addr) on clk1x; backing = SDRAM2 ch1/ch2 when fitted, else spu_ram.vhd DDR3. Audio HW-confirmed (hyperbbc milestone). | psx/rtl/spu.vhd:51; rtl/emu.sv:1203,1955,1988-2005; psx/rtl/spu_ram.vhd:20,225-236 | MATCH |

### BIOS

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| BIOS ROM | 0x080000 (512 KB) ROM_REGION32_LE; std 700a01.22g CRC(11812ef8); 3 variants; every local BIOS file/zip member exactly 524,288 B | ksys573.cpp#L3751-L3757; `ls dumps/bios/*` + `unzip -l dumps/sys573.zip` = 524288 | 512 KB window (ioctl_addr[18:0], index 0) staged at SDRAM BIOS_START 0x800000; fastboot forced OFF (Konami BIOS not SCPH) | rtl/emu.sv:681,745,1166 | MATCH |

### ATAPI / CD

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| ATAPI register map + drive identity | ATA cs0 0x1f480000-f, cs1 0x1f4c0000-f, soft reset 0x1f560000 (write bit0=0); default drive cr589 (real units CR-583/587); hyperbbc = NO drive (konami573(config,true)) | ksys573.cpp#L962-L965, L2597-L2598, L2604-L2608, L3075 | Pages 0x480000/0x4c0000/0x560000 decoded; signature 0xEB14, IDENTIFY PACKET 0xA1 (256 words), READ blocklen 2048 B, HPS streams 2352-B sectors as 1176 words; cd_present=1'b1 — deliberate HW-validated delta (GX700 POST probes unconditionally; 0xFFFF float = BSY-stuck = CDR BAD; empty-drive-present closer to a real cab than MAME's nothing) | rtl/s573_bus.v:36-37,40; rtl/atapi.v:74,107,144-147,225,233,287; rtl/s573_cdimg.v:17-23; rtl/emu.sv:1805-1811,1816-1821 | MATCH |
| ATA IRQ routing | ATA IRQ → psxirq intin10 | ksys573.cpp#L1165-L1168 | ATAPI INTRQ → exp_irq10 | rtl/system573_top.v:229; rtl/emu.sv:1831 | MATCH |
| ATAPI_CYCLES_PER_SECTOR | 30000 CPU cycles ("plenty of time" — driver convenience); only the ≥2000 BIOS floor is a real constraint | ksys573.cpp#L391, L1193-L1194 | No equivalent pacing constant (PIO-only, no DMA sector timer) | rtl/atapi.v (no pacing constant) | UNKNOWN |

### NVRAM / RTC (M48T58)

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| M48T58 timekeeper device | 0x2000 (8 KB) total; clock regs 0x1ff8-0x1fff (8) → 8184 usable NVRAM bytes; every .22h image 8,192 B | machine/timekpr.cpp#L151-L165; `ls dumps/hyperbbc/nvram8k.bin` + `unzip -l hyperbbc.zip 876?a.22h` = 8192 | ram[0:8183] + 8 RTC regs at RTC_BASE=13'd8184 (=0x1ff8); RTC freeze modeled (date wrap simplified). No SD save-back (load-only) — high-score persistence broken; feature gap, not a constant bug. | rtl/m48t58.v:49-53 | MATCH |
| M48T58 bus mapping | 0x1f620000-0x1f623fff, umask32 0x00ff00ff (byte chip on low byte of each 16-bit lane; 16 KB window for 8 KB chip) | ksys573.cpp#L968 | Page 0x62xxxx; 16-bit accesses low-byte only; byte addr = addr[14:1] | rtl/s573_bus.v:43,49-51; rtl/system573_top.v:243-252 | MATCH |
| NVRAM ioctl load path (hps_io WIDE unpack) | Framework constant (not MAME): hps_io WIDE(1) = 16-bit ioctl words, addr steps by 2 | sys/hps_io.sv:28,35; rtl/emu.sv:568 | Each WIDE word → TWO byte writes (even=dout[7:0], odd=dout[15:8]) + ioctl_wait backpressure; unpacker reused for security-cart loaders; load under reset. Original loader wrote low byte only → every odd byte zeroed → signature self-test fail (red-N). | rtl/s573_nvram_loader.v:53-61; rtl/emu.sv:757-763,1480-1502; rtl/m48t58.v:38-47; tb sim/tb_s573_nvram_loader.v | KNOWN-BUG #4 (FIXED 7f335d7, HW-confirmed) |

### Flash / PCMCIA / EXP1

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| Flash bank select decode | bank = control reg (0x1f500000) & 0x3f used RAW (set_bank(m_control & 0x3f), no shift); bit6 = sec IO dir, OUT2 0x40 zs01 SDA | ksys573.cpp#L964, L1132-L1141, L3251-L3252 | internal=(bank[5:2]==0) i.e. bank<4; bank_idx=bank[1:0] raw; ctl [6]/[7] handled. Old ctl[5:4] shifted decode starved banks 1-3 (12 MB) → ROM CHECK stall. | rtl/s573_flash.v:117-131 (MAME cited inline) | KNOWN-BUG #3 (FIXED 6b29c37, HW-confirmed) |
| Flash window + bank geometry | CPU window 0x1f000000-0x1f3fffff (4 MB); ADDRESS_MAP_BANK 16-bit, stride 0x400000/bank; onboard = banks 0-3 = 16 MB | ksys573.cpp#L957, L2630, L975-L982 | Page sel ≤0x3f; flash_word = {bank_idx, win_addr[20:0]} (full 21-bit window; old [16:1] 128 KB/bank slice fixed); 16-word line buffer; SDRAM image at FLASH_START 0x0100_0000 | rtl/s573_bus.v:34; rtl/system573_top.v:154-160; rtl/s573_flash.v:184-199; rtl/emu.sv:682-692,1573-1575 | MATCH |
| Onboard flash chips + byte interleave | 8× Fujitsu 29F016A (2 MB each; zip members exactly 2,097,152 B) as 4 banks × 4 MB; per bank a PAIR: 31x = LOW byte (umask16 0x00ff), 27x = HIGH (0xff00); bank order m,l,j,h | ksys573.cpp#L975-L982, L2615-L2622, L232; `unzip -l dumps/mame573/hyperbbc.zip` | pack_hyperbbc.py: banks 31m/27m, 31l/27l, 31j/27j, 31h/27h, even=31x LOW, odd=27x HIGH (MAME order cited in-file); flash16m.bin = 16,777,216 B; NOR program = write-through line buffer + SDRAM write-back, erase no-op vs 0xFF blank. Interleave EXONERATED as garble suspect. | tools/pack_hyperbbc.py:5-18,32-40; rtl/s573_flash.v:95-97,286-294; rtl/emu.sv:1928-1939; `ls dumps/hyperbbc/flash16m.bin` | MATCH |
| PCMCIA flash banks | pccard1 = banks 16-31 (0x4000000+), pccard2 = 32-47; detect IN1 bits 0x04000000/0x08000000; 16/32/64 MB options; hyperbbc = NO card | ksys573.cpp#L983-L984, L2685-L2709, L3233-L3234, L3073-L3079 | Decode-only: banks 16-47 read 0xFFFF, pcmcia_present=2'b00 (empty-slot semantics). Card emulation = future gate for PCCARD games. | rtl/s573_flash.v:117-121,161,348 | MATCH |
| EXP1 bus width + access protocol | Flash window amap16 (16-bit data); EXP1 16-bit (ex1_memctrl bit12=1); BIOS reads flash sig/CRC byte-by-byte (lb) | ksys573.cpp#L957 | Patches widen EXP1: 24-bit addr/16-bit data (0001), exp1_wait (0006), byte-lane replication (0009), 2-bit reqsize lb/lh/lw (0010); odd-byte rotate in the 573 slave; registered+held rdata. All four 573-essential, consistent with MAME's 16-bit space. | psx_patches/0001,0006,0009,0010; rtl/system573_top.v:296-303,315-318 | MATCH |

### 573 register map & I/O

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| 573 register address map | 0x1f400000 IN0/OUT0 · ..04 IN1 · ..08 IN2+JVS rx · ..0c IN3 · 0x1f480000/0x1f4c0000 ATA · 0x1f500000 control · 0x1f560000 atapi reset · 0x1f5c0000 nopw (watchdog?) · 0x1f600000 lamps · 0x1f620000 m48t58 · 0x1f680000 JVS tx · 0x1f6a0000 security | ksys573.cpp#L955-L971 | Same pages (0x40/0x48/0x4c/0x50/0x56/0x5c/0x62/0x68/0x6a) + extra 0x1f520000 "jvsclr" page not in MAME (decoded, consumed by nothing, reads 0) — inert; verify vs real-HW docs before wiring | rtl/s573_bus.v:34-51; rtl/system573_top.v:116-129 | MATCH |
| JVS sense + status bits | sense = IN1 bit 0x00080000 (reads 1 with no JVS board); rx-ready = 0x00100000; TX at 0x1f680000; sync 0xE0, 8-bit additive checksum | ksys573.cpp#L969, L1030-L1123, L3226-L3227 | Stub matching no-board values: 0x1f400006 bit3 (=IN1 bit19) hardwired 1; bits[5:4]=0 force MAME-equivalent timeout → graceful skip; no packet engine; jvs_mcu_rst_n unconnected. HW-confirmed (e280f95). Real JVS host = future work. | rtl/s573_io.v:72,98-109; rtl/system573_top.v:270 | MATCH |
| H8/3644 security MCU handshake | MCU ROM NO_DUMP; MAME HLEs from 64-byte h8_response (std BIOS pairs h8a01.bin CRC 131e0359; dsem2 pairs h8b01.bin); clock = OUT0 bit 0x100, data = IN1 bits 0x10-0x80; both h8*.bin exactly 64 B | ksys573.cpp#L3758-L3763, L3194, L3209-L3212, L1313-L1331; `ls dumps/bios/h8a01.bin h8b01.bin` = 64 | Response nibble hardwired 0xC — matches 700A h8a01.bin only (source TODO: 700B needs ROM-backed shifter). Scoped MATCH (700A, HW-confirmed boot); dsem2/700B fails until ROM-backed. Protocol beyond the 64 B unknowable from MAME. | rtl/s573_io.v:86-89 | MATCH |
| Security cart register + EEPROM models | 0x1f6a0000 16-bit latch; OUT1 D0-D7 → cassette lines (hyperbbc reuses as lamps d4=green d5=blue d6=red d7=start); X76F041 548 B, X76F100 132 B (0x84 incl 4B RtR+8B WPW+8B RPW), ZS01 4116 B; hyperbbc = cassette Y (X76F100), "game doesn't check the security chip" | ksys573.cpp#L970, L1197-L1211, L2240-L2251, L2711-L2718, L3073-L3079, L5828-L5835; k573cass.cpp#L65,L115,L171,L253,L280,L293 | x76f100 132-B (112-B body), x76f041 548-B, zs01 4116-B; type latched from size (≥560 ZS01, ≥256 041, else 100 — old ≥112 mistype fixed); latch page 0x6a; .u1=ioctl 4, .u6=ioctl 5. Cart-A (X76F041) unlocks gtrfrk5m/8m/pnchmn2. | rtl/x76f100.v:4-8,84; rtl/x76f041.v:62; rtl/emu.sv:1505-1518,1552-1570; rtl/s573_bus.v:46; rtl/system573_top.v:67-73,179-187 | MATCH |
| DS2401 silicon serial | 8-B raw ID: family 0x01 + 48-bit serial + CRC8; only in XI/YI/ZI ("i") carts + k573dio + gunmania/kicknkick; hyperbbc cart (Y) has NONE; readback IN1 bit 0x00004000 | ksys573.cpp#L2714-L2718, L3153, L3182, L3221, L5622-L5623 | family 8'h01 · 48-bit serial · CRC8 poly 0x8C reflected; default 48'h1; cart CART_SERIAL + DIO CART_SERIAL+1; loadable 8-B .u6 (byte k → rom[8*(7-k)+:8]); 1-Wire thresholds from CLK_FREQ_HZ. Core always instantiates a cart DS2401 even for Y carts — benign for hyperbbc; revisit per-cart presence for "i"-suffix games. | rtl/ds2401.v:20,28-38,44-50,53-70; rtl/system573_top.v:14,179,233; rtl/emu.sv:662,1539-1550 | MATCH |
| ADC0834 | OUT0 bit0=DI, bit1=CS, bit2=CLK; DO = IN1 bit 0x00010000, SARS = 0x00020000; 4 analog inputs via callback | ksys573.cpp#L2646-L2647, L3191-L3193, L3213-L3214, L3223 | Bit-banged from ctrl bits 0-2; readback on 0x06 half-word bits 0-1 (= IN1 bits 16-17); all channels tied 8'h00. Suffices for hyperbbc; DDR-family analog needs real sources. | rtl/emu.sv:1822-1825; rtl/system573_top.v:140-147; rtl/s573_io.v:65-67,110-112 | MATCH |
| DIP switches / boot device | DIP SW:4 bit 0x8 "Start Up Device": 0x0 = Flash ROM (MAME default), 0x8 = CD-ROM | ksys573.cpp#L3206-L3236 | dip_sw = {status[93], 3'b111}: SW4 = OSD "573 Boot Device", default 0 = Flash ROM; SW1-3 hardwired 1 ("off"). MAME defaults/polarity for SW1-3 not extracted — open minor item. | rtl/emu.sv:370,1795-1797 | MATCH |
| Watchdog (0x1f5c0000) | UNEMULATED in MAME: nopw, comment "// watchdog?" — no timeout/kick semantics to compare | ksys573.cpp#L966 | Observe-only: TIMEOUT_CYCLES 32'd1_000_000 clk1x (~29.5 ms), kick on any page-0x5c write, bite deliberately unconnected. Both sides inert today; ~29.5 ms unvalidated vs real HW. | rtl/watchdog.v:13; rtl/system573_top.v:15,135-138; rtl/s573_bus.v:41; rtl/emu.sv:1443-1444,1830 | UNKNOWN |
| Main-RAM-layout strap (0x1f40000e bit10) | Not extracted from MAME (IN3 bit semantics not tabulated — citation gap, ksys573.cpp#L955-L971 region) | (none — gap) | Hardwired 0 = "new 2x2MB layout" (700B BIOS then picks ram_config 0x4788); 0x0c word returns TEST at bit10. Interacts with the ram_config row. | rtl/s573_io.v:121-124 | UNKNOWN |

### Expansion I/O boards

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| Expansion I/O boards (window + clocks) | 0x1f640000-0x1f6400ff per-variant (k573dio @ 19.6608 MHz, k573kara @ 36.864 MHz, gx700pwbf/k, ge765, gunmania; gbbchmp MB89371 @ 4 MHz); hyperbbc = BASE map, nothing at 0x1f640000 | ksys573.cpp#L987-L1027, L2661, L2669, L3118, L3073-L3079 | DIO partially stubbed (crypto_key/mp3_start/fpga_ctrl unconnected); no board window. Matches hyperbbc; DIO constants need their own extraction lane for C-tier (~33 games). | rtl/system573_top.v:238-239 | UNKNOWN |

### Game config (hyperbbc)

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| hyperbbc machine config + ROM set | konami573(config,true)=no CD drive; cassette Y, security never checked; init zeroes lamp state only; all 8 flash chips populated (16 MB) + 8 KB NVRAM 876ea.22h CRC(8e11d196); uncompressed zip total 37,773,312 B = 3 variants exactly | ksys573.cpp#L3073-L3079, L2264-L2281, L5756-L5778, L6495; `unzip -l dumps/mame573/hyperbbc.zip` | Flash-only boot (ioctl 2 = 16 MB image, ioctl 3 = 8 KB NVRAM); boots+runs+audio HW-confirmed (frame_diff-verified, 6b29c37 era). All four banks live — consistent with the bank-decode bug having starved banks 1-3. Remaining delta = VRAM garble. | rtl/emu.sv:657-664; `ls dumps/hyperbbc/flash16m.bin` 16777216, `nvram8k.bin` 8192 | MATCH |

### Core-internal (no MAME analog)

| Constant | Reference value | Cited source | Our core | RTL citation | Status |
|---|---|---|---|---|---|
| Savestate region + RAM coverage | No MAME analog; platform RAM = 4 MB, VRAM = 2 MB | (ksys573.cpp#L2600, #L2633) | DDR3 slot 0x3E000000, 4 MB/slot; coverage: RAM = 2 MB ONLY, VRAM = 1 MB, SPURAM = 512 KB; .ss files 4,194,304 B both halves nonzero (cap = mapped region, not file size) | psx/rtl/savestates.vhd:90-122; rtl/emu.sv:358; `ls local/de10_menu_ss/*.ss` = 4194304 | UNKNOWN |
| SDRAM controller CAS latency | No platform reference (MiSTer-side) | (n/a) | CAS_LATENCY 3'd3 (upstream 3'd2): clk3x 101.6064 MHz > 100 MHz puts CL2 out of spec; SignalTap-proven fix for deterministic low-bit miscapture on GP0 DMA reads under flash traffic (CLUT 0x7AC0 → 0x7800/0x7840) | psx_patches/0020-sdram-cas-latency-3.patch | UNKNOWN |

## NEW mismatches (adversarially verified)

### 1. ATAPI DMA channel 5 — REAL, latent (blocks future features)

**Claim:** MAME's 573 driver wires CD/ATAPI DMA to PSX DMA ch5 and the BIOS CD-boot path
depends on it; our core's ATAPI is PIO-only with no ch5 hookup.

**Verification (independent lane, both sides re-fetched):**

1. **MAME side** (raw.githubusercontent.com/mamedev/mame/mame0288/src/mame/konami/ksys573.cpp,
   6626 lines): L2597-2598 in `konami573()` are exactly
   `m_maincpu->subdevice<psxdma_device>("dma")->install_read_handler(5, ...cdrom_dma_read...)` /
   `install_write_handler(5, ...cdrom_dma_write...)` — CD/ATAPI DMA on PSX DMA channel 5,
   confirmed. L391 is `#define ATAPI_CYCLES_PER_SECTOR ( 30000 )` with comment "BIOS requires
   this be at least 2000"; L1193 (inside `cdrom_dma_write`, L1184) repeats "CYCLES_PER_SECTOR
   can't be lower than 2000 or the BIOS ends up 'out of order'" — the BIOS CD-boot path runs
   through the ch5 DMA write handler with a timing floor, confirmed.
2. **Core side:** `rtl/atapi.v` header (lines 5-8) itself documents the platform as "DMA
   channel 5" but the module implements only "a non-data command ... or a PIO data-in
   command"; its port list (lines 27-49) is purely the EXP1 register interface
   (sel/addr/we/re/din/dout/intrq) + the sec_req/sbuf CD-image sector path — no DRQ/DMARQ/DACK
   toward the PSX DMA. Instantiation at `rtl/system573_top.v:201-208` confirms no DMA wiring.
   `grep -l 'dma.vhd' psx_patches/*.patch` returns nothing (exit 1) — vendored dma.vhd
   untouched by patches 0001-0020.
3. **Aggravating fact the original claim missed:** vendored `psx/rtl/dma.vhd:363` hard-wires
   `dmaArray(5).request <= '0';` AND the trigger block (L368-373) has triggerDMA lines for
   channels 0,1,2,3,4,6 only — **ch5 can NEVER fire in this core**, even if game code sets the
   D_CHCR start bit. Correct for a consumer PSX (ch5 = unused PIO port); a genuine
   platform-constant divergence for the 573, which repurposes ch5 for ATAPI.

**Impact:** zero effect today — hyperbbc is flash-boot, and the current garble is the separate
VRAM-size bug. Gates the entire tier-B CD/ATAPI track of the 573 library roadmap (CD-boot
games), BIOS boot with DIP SW4=CD-ROM, and transitively tier-C DDR/DIO games that install
from CD. The divergence is two-layered: the channel is dead in dma.vhd AND atapi.v lacks the
device-side DMA data path + pacing.

**Suggested action:** recorded in PLATFORM.md now; fix only when tier-B CD work starts.
Fix shape (3 parts):
- (a) new numbered psx_patch on `psx/rtl/dma.vhd` exposing a ch5 request + read/write data
  port (mirror the gpu/spu pattern; today L363 hard-wires the request off and L368-373 omits
  the trigger);
- (b) extend `rtl/atapi.v` with the device-side DMA protocol (honor the PACKET features-reg
  DMA bit; stream sector words to the ch5 port instead of the PIO data register);
- (c) pace sector completion at ≥2000 CPU cycles/sector (MAME uses 30000) or the BIOS CD-boot
  goes "out of order" (ksys573.cpp#L391, L1184-L1194).

## UNKNOWN rows — explicit follow-ups

| # | Row | Follow-up |
|---|---|---|
| 1 | Watchdog (0x1f5c0000) | MAME has no semantics (nopw). If the watchdog is ever wired to bite, measure the real-board timeout first; until then both sides are inert. |
| 2 | Main-RAM-layout strap (0x1f40000e bit10) | Reference side uncited — decode MAME's IN3 port bits per-bit when auditing inputs; cross-check against the ram_config value the BIOS writes (interacts with KNOWN-BUG #1). |
| 3 | Savestate RAM/VRAM coverage | Core tooling gap: savestates map only 2 MB RAM (platform has 4) and 1 MB VRAM (platform has 2). Extend coverage alongside patch 0021 if savestate debugging matters. |
| 4 | SDRAM CAS latency (CL3) | Implementation constant, no reference value — keep the SignalTap evidence chain with the patch; re-evaluate if clk3x ever changes. |
| 5 | ATAPI_CYCLES_PER_SECTOR | Becomes load-bearing with the ch5 DMA work (tier-B): treat 30000 as tuning, ≥2000 as the hard floor. |
| 6 | Expansion I/O boards (k573dio etc.) | Run a dedicated constants-extraction lane for the DIO board (window map, 19.6608 MHz clock, MP3/crypto regs) before starting C-tier DDR/MP3 work. |

## Disposition summary

- **Fixed before this sweep (HW-confirmed):** flash bank decode (#3, 6b29c37), NVRAM WIDE
  unpack (#4, 7f335d7).
- **Fix in flight:** VRAM 2 MB / 1024 rows + 10-bit Y field widths (#2, patch 0021 pending —
  not yet present in psx_patches/ as of this sweep).
- **Open, latent:** main RAM 4 MB window/mask (#1 — pristine PSX core has no 4 MB mode; needs
  a patch adding the mirror/mask), ATAPI DMA ch5 (new — tier-B gate).
- **Accepted-with-rationale deltas vs MAME:** cd_present=1 (empty CR-589 attached; GX700 POST
  needs a non-floating drive), extra 0x1f520000 decode (inert), DS2401 always instantiated
  (benign for hyperbbc), SW1-3 polarity (open minor item).
