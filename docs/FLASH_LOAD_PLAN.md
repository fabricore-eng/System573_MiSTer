# Onboard NOR Flash — 16 MB loadable backing (hyperbbc boot) — implementation plan

Status: **designed, not yet implemented** (2026-06-02). Prereq met: the BIOS i-cache
crash is fixed (psx_patches 0004+0005), so the BIOS can now reach the game-launch.

## Goal
Make the 573 onboard flash (`0x1F000000` window, banks 0-3) hold the real **16 MB**
hyperbbc image (`dumps/hyperbbc/flash16m.bin`, CRC-verified) instead of the current
4 KB-per-bank constant-`0xFFFF` BRAM, so the BIOS can load + run the game.

## Architecture decision: EXP1 read **handshake** + **line buffer**
The hard part is latency: a combinational 4 KB BRAM read must become a 16 MB
SDRAM-backed read, on the EXP1 bus, which today expects a near-fixed-timing slave.

**Chosen:** add an EXP1 read **wait handshake** (`bus_exp1_wait`) to the memorymux read
FSM so it stalls until the flash word is ready, backed by a **16-word (32-byte) line
buffer inside `s573_flash`** filled by one SDRAM burst. Hits return in the normal strobe
(zero stall); misses stall the bus and kick a fill.

Why this and not the alternatives:
- Correct for **both** open cases without knowing which the BIOS does — in-place
  execution (i-cache line fills pay the miss penalty, like real HW's slow EXP1 flash)
  **and** copy-flash→RAM (sequential reads hit the line buffer 15/16; misses stream at
  burst rate; game then runs cached from RAM). The bus never advances on stale data.
- Direct memorymux→SDRAM routing (like RAM/BIOS) is **rejected**: the bank register
  lives on the 573 side, so memorymux can't form the address, and it would bypass the
  autoselect-ID FSM POST needs.

The **autoselect MFR/DEV ID** path (`0x0004`/`0x00AD`, Fujitsu 29F016A) stays
combinational with immediate ready — POST's flash-ID check is unchanged.

## Free SDRAM home
16 MB free contiguous at **SDRAM byte `0x02000000`** (RAM@0x0, BIOS@0x00800000,
EXE@0x01000000). `flash_addr = 0x02000000 + {bank[1:0], win_addr[20:0], 1'b0}`.

## Ordered edits
1. **`rtl/flash_nor.v`** — add `BACKING_EXTERNAL` param. Default 0 = inline `mem[]` (sim
   /tests unchanged). 1 = expose array-read addr/data to parent; keep the JEDEC command
   FSM + ID path byte-identical.
2. **`rtl/s573_flash.v`** — widen `win_addr` to `[20:0]`; flat word `= {bank[1:0],
   win_addr[20:0]}`; add a 16-word line buffer (tag `flash_word[22:5]`); hit → combinational
   `win_dout` + `flash_ready=1`; miss → `flash_ready=0` + SDRAM fill request. `ST_AUTO` ID
   reads answer immediately (no SDRAM). New ports up to the top: `flash_mem_req/addr/q/ready`
   + `flash_ready`. Keep `SIM_BACKING=1` default so iverilog uses the inline chips.
3. **`psx_patches/0006-s573-exp1-flash-wait.patch`** (NEW) — thread `bus_exp1_wait` through
   `memorymux`←`psx_top`←`psx_mister`←`emu.sv`←`system573_top.flash_ready`; in the EXP1
   read FSM hold (loop in a wait state) while `ext_select_ex1 & bus_exp1_wait`. **Purely
   additive** — never change the hit-case `EXT_READ_NEXT→EXT_READ` capture timing. Highest-
   risk edit (touches the crux FSM). Register in `apply_psx_patches.sh`.
4. **`rtl/system573_top.v`** — `.win_addr(exp1_addr[21:1])` (FIXES a real bug: was `[16:1]`
   = only 128 KB of a 4 MB bank); plumb the flash backing ports + `flash_wait`.
5. **`rtl/emu.sv`** — new ioctl_index 2 (flash) + 3 (NVRAM); `FLASH_START=27'h0200_0000`;
   extend the ramdownload packer + ch3 mux for `flash_download`; add the SDRAM read client
   for fills; wire `flash_wait`→`bus_exp1_wait`; drive the M48T58 load port.
6. **`psx_patches/0007-sdram-ch4-flash.patch`** (NEW) — add a read-only 128-bit ch4 to
   `psx/rtl/sdram.sv` (lowest arbiter priority) for flash fills. **Fallback if it hurts
   timing closure** (98% ALM): reuse ch3 (idle during gameplay) with 16 single-word reads
   per fill. Register in `apply_psx_patches.sh`.
7. **`rtl/m48t58.v`** — add an NVRAM load port (`nvram_we/addr/din`) to fill the 8 KB from
   `876ea.22h` (`dumps/hyperbbc/nvram8k.bin`).
8. **`tools/apply_psx_patches.sh`** — register patches 0006, 0007.
9. **`games/System573/Hyper Bishi Bashi Champ.mra`** (NEW) + optional CONF_STR `FS2/FS3`
   file pickers. `.mra` streams the pre-interleaved `flash16m.bin` flat at index 2,
   `nvram8k.bin` at index 3, (optionally the 573 BIOS at index 0).

## Keep iverilog tests green
Use a `SIM_BACKING=1` parameter (NOT `ifdef`): sim keeps the inline `flash_nor mem[]` +
program/erase + combinational read; synth sets `SIM_BACKING=0` for the SDRAM line-buffer
path. Existing `tb_s573_flash`/`tb_flash_nor`/`tb_m48t58` pass unchanged (at most widen a
tb `win_addr` reg). Add an optional `tb_s573_flash_sdram` with a behavioral SDRAM-line
model to cover miss/hit/handshake + ID-during-stall.

## Risks
1. **0006 memorymux patch is the crux + highest risk** — keep the hold purely additive;
   verify POST still passes (ID read must not stall — `flash_ready=1` in `ST_AUTO`).
2. **EXP1 wait must never deadlock POST** — assert `flash_wait` ONLY on `sel_flash &
   array-read & miss`; every other EXP1 select (ASIC/RTC/ATAPI/digio) + the ID path must
   leave it 0. A stuck-high wait hangs the whole 573 bus.
3. **sdram.sv ch4 (0007)** could disturb timing closure (already tight) — lowest priority,
   read-only; fall back to ch3-reuse if it regresses.
4. **Bank order (m,l,j,h)** is from the MAME flashbank_map and confirmed (bank0 = "GQ876");
   if wrong, it's a one-line re-pack, not RTL.

## First-build verification order
1. `make -C sim` — all tb PASS (+ new SDRAM-line tb).
2. `apply_psx_patches.sh --check` — 0001-0007 apply clean.
3. HW boot hyperbbc via the `.mra`: (a) POST passes flash-ID; (b) bank0/word0 = `"GQ876"`;
   (c) BIOS reaches game launch (handshake doesn't hang, 4 MB/bank addressing correct);
   (d) observe whether post-launch fetches stay in `0x1F0xxxxx` → answers in-place vs copy.
