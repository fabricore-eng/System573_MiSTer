# A0 DELIVERABLE — ddrsbm BOOT CHECK: the exact MAS3507D I2C transaction list (2026-07-01)

De-stub plan step A0 (`docs/2026-07-01-k573dio-i2c-destub-plan.md`), executed via a
5-agent recon workflow (`wf_93acac08-a37`): MAME 0.285 source derivation + full capstone
re-disassembly of `local/ddrsbm_gwait.bin`, synthesized, then **adversarially verified by
two independent lanes** (game-side: every load-bearing claim re-derived from raw bytes —
ALL CONFIRMED; MAME-side: confirmed with 2 refinements, noted below). Raw evidence:
`local/tracedig/a0_i2c_disasm.md`, `local/tracedig/a0_mas3507d_mame.md`.
Dynamic confirm: MAME DIO-window tap `tools/trace/ddrsbm_dio_tap.lua` →
`local/ddrsbm_dio_tap.log` (golden byte stream; see addendum at end).

## 1. Headline: the boot gate is ACK-ONLY

The game performs two **write-only** I2C transactions and passes iff every byte is ACKed
(and SCL always echoes). There is **NO version/ID read** — MAME's MAS3507D model contains
no ID register at all (register reads return 0x00 bytes and ddrsbm boots against that),
and the dumped game code **never compares any read-back value** during boot. `dio_mas_init`
(0x800aa89c) returns 0 iff every ACK-sample read 0; NACK → −3, 3 retries → −1.

## 2. Line-level idioms the RTL must echo

- **[SCL-echo]** After EVERY write that raises SCL, the game spins `lhu 0x1f6400ac & 0x2000`
  until nonzero — **UNBOUNDED** (three such spins: 0x800aaf68 i2c_start, 0x800ab1e8
  send_bit, 0x800ab358 read_bit). SCL readback must always equal the written SCL bit —
  the MAS3507D never stretches (MAME `i2c_sclo` is set at reset and never cleared).
  The spin at 0x800aaf68 is the current hang: the stub read-mux has no 0xac case.
- **[ACK-sample]** After every written byte: write SDA=1 (release), raise SCL, [SCL-echo],
  read `0xac & 0x1000` (lhu @0x800ab390) — must be **0** (slave pulling low) = ACK.
- Reads of 0xac are side-effect-free; writes are not gated by any other state.
- Register bit layout (MAME `k573fpga.cpp mas_i2c_r/w`, silicon-confirmed by the spin):
  write bit13→SCL, bit12→SDA (**SCL applied before SDA within one 16-bit write**);
  read = `{scl, sda_host & sda_slave} << 12`. **All line latches reset HIGH** (a pristine
  0xac read returns 0x3000; the first write of 0x2000 from (1,1) must register as START).

## 3. The ordered transaction list

Phase 0 — pre-I2C MMIO (all already satisfied by current RTL):
read 0x80 == 0x1234 (@0x800aa418) → write 0xf4=0 → MPEG reset pulse on 0xaa
(0x1000, 0, 0x1000, ~0xf-tick delay before the 3rd) → `0xf6 & 0xc000 == 0x8000`
short-circuits the FPGA-bitstream-programming path (RTL returns 0xB000 ✓).

**T1 — WRITE_MEM bank0 addr 0x32f = 0x00030 (OutputConfig)** (`mas_reset_and_run`
@0x800aa82c → `mas_mem_write` @0x800abb40):
1. START: write 0xac=0x3000 [SCL-echo ← the hang], 0x2000 (SDA↓ @ SCL=1), 0x0000
2. byte **0x3a** (device write address) → ACK
3. byte **0x68** (data-write subcommand) → ACK
4. 6 header bytes → ACK each: cmd byte (**0xa0**, from a table outside the dumps —
   confirmed by the dynamic tap, §6), pad 0x00, word-count BE 0x00 0x01, addr BE 0x03 0x2f
5. one 20-bit word as 4 bytes: **0x00, 0x30, 0x00, 0x00** → ACK each
6. STOP: SCL0/SDA0 → SCL1 [SCL-echo] → SDA1

**T2 — RUN 0x0fcb** ("validate OutputConfig", log-only in MAME) (`mas_write_word`
@0x800ab5e4): START, **0x3a**→ACK, **0x68**→ACK, **0x0f**→ACK, **0xcb**→ACK, STOP.

Phase 3 — post-I2C MMIO (write-only, no compares): 0xba=0xffff (once, never read back),
0xf4 = 0x8000, 0, 0x8000. Then `dio_mas_init` returns 0.

Runtime (post-boot, P4 audio scope, NOT boot-gating — verified stored-never-compared):
reg writes (0x3a, 0x68, 0x9X + 3 bytes); frame-count read (0x3a, 0x69 arms it,
repeated-START, 0x3b, then the slave streams fc[15:8], fc[7:0] MSB-first — 0x00 0x00 at
boot; master ACKs first byte, NACKs last, STOP); 0xae bit12 (streaming — runtime callers
at 0x800ac39c/3e4/7ec require it ==0 to proceed, matching our reset-0 read ✓);
0xcc/0xce counter reads.

## 4. Minimal slave spec (what rtl/mas3507d_i2c.v implements)

- Sampling: bits on rising SCL, MSB-first; bit value = the SDA level BEFORE the write
  that raised SCL (MAME processes SCL first, then SDA, within one 16-bit write).
- START = SDA 1→0 while SCL(new)=1, valid from ANY state; resets the bit counter,
  **preserves** the read-armed flag/byte count (the repeated-START read flow needs this).
  STOP = SDA 0→1 while SCL=1 → idle.
- Address byte: ACK iff `(byte & 0xfe) == 0x3a` (7-bit addr 0x1d). 0x3b enters the read
  branch; 0x3a clears read-armed. Other addresses: NAK → dead until START/STOP.
- ACK: slave drives SDA low during the SCL-low period after the 8th bit, holds through
  the 9th falling edge (valid whenever the host samples with SCL high on clock 9 —
  strictly earlier than MAME's rising-9th-edge drive, compatible with the bit-bang).
- Write branch: **ACK-and-drop every byte** (unimplemented writes logged loudly behind a
  DBG-off `$display` in sim — no silent lies, per [[no-mask-fault-with-fake-data]]).
  Note this is deliberately MORE permissive than MAME only on paths the game never
  exercises (MAME NAKs over-length sequences; the game never over-runs).
- Read branch (0x69-armed or not): stream `sdao_data` MSB-first; armed = the 32-bit
  decoded-frame-count packing (fc[15:8], fc[7:0], fc[31:24], fc[23:16]); unarmed = zeros.
  Our decoder decodes nothing yet → frame count is genuinely 0 → bytes 0x00 (truthful,
  not fake: P4 wires the real count). Master NACK on a read byte → park until START/STOP.
- NO clock stretching (SCL readback = host latch, unconditionally), no CONTROL (0x6a)
  semantics, no reg/mem read-back data paths needed.

## 5. Neighbor registers — verified adequate as-is for the gate

| Reg | Boot-check role | Current RTL | Verdict |
|-----|----------------|-------------|---------|
| 0xae fpga_ctrl | never read before init passes; runtime needs bit12==0 first | `fpga_ctrl_rb` = streaming<<12, 0 at reset — semantics MATCH MAME `get_fpga_ctrl` (bit14 && start≤cur<end) | OK, no change |
| 0xba | written 0xffff once, never read | write-ignored | OK |
| 0xaa mpeg_ctrl | written (reset pulse), never read-compared in dumps | reads 0 (MAME steady-idle = 0x3000) | OK for gate; revisit if tap shows top-level polls |
| 0xcc/0xce counters | runtime-only reads, stored never compared | read 0 | OK for gate. **Known follow-up:** on the ddrsbm FPGA variant MAME's counter FREE-RUNS (wall-clock × 44100) from reset even with no audio — a stub-0 will likely break later song-position logic (P4 scope, observe first) |
| 0x80 / 0xf6 | ==0x1234 / &0xc000==0x8000 | 0x1234 / 0xB000 | OK (pre-existing) |

## 6. Dynamic-tap addendum (closes the two static soft spots)

Soft spot 1: the WRITE_MEM cmd byte comes from a lookup table @~0x800dea08, outside both
RAM dumps (MAME-inferred 0xa0). Soft spot 2: the top-level caller of `dio_mas_init` is
outside the dump windows, so extra top-level register polls could not be excluded
statically.

**RESULTS (two runs):**
- **R/W tap** (`local/ddrsbm_dio_tap.log`): MAME 0.285 **died at f=207 mid-byte-2** —
  the log stops between two adjacent store instructions. WRITE taps crash MAME even on
  MMIO (the RAM-tap disease is not RAM-specific); the plan's fallback applied. Before
  dying it confirmed on the wire: the reset-released read = 0x3000, the START idiom
  (0x3000 → echo → 0x2000 → 0x0000), the per-bit sequence incl. an SDA-release trailer,
  **single-bit-per-store discipline** (the SCL-before-SDA same-write ordering concern is
  moot for this game), address byte 0x3a MSB-first, and the first ACK sampled as bit12=0.
- **Read-only tap** (`local/ddrsbm_dio_rtap.log`): **survived the full 90 emulated
  seconds at 100% speed.** The complete DIO I2C init runs inside frame 207:
  **16 ACK samples (pc 0x800ab390), every one reading 0x2000 = ACK** — exactly T1's
  12 bytes + T2's 4 bytes — with ~9 immediate echo reads (pc 0x800aae74) per byte.
  **Nothing else in 0x1f6400a0–cf is read in the entire 90 s** — no 0xaa/0xae/0xcc/0xce
  top-level or runtime polls. Both soft spots are closed for the gate: the ACK-only
  verdict is dynamically confirmed end-to-end; the cmd byte stays MAME-inferred (0xa0)
  but the RTL is insensitive to it (ACK-and-drop).
- Tooling lesson recorded: MAME 0.285 write taps crash the emulation regardless of
  address class; read-only taps are safe. `tools/trace/ddrsbm_dio_tap.lua` keeps the
  write tap for reference; delete the `install_write_tap` block to get the safe variant.

## 7. Oracle-fidelity caveats (recorded, not blocking)

- MAME's own TODO (k573dio.cpp:84): the REAL ddrsbm FPGA bitstream returns 0x7654 for
  unused registers — unmodeled in MAME, ddrsbm boots anyway. A known oracle≠silicon gap;
  flag for PLATFORM.md, do not implement blind.
- MAME leaves the slave SDA latch LOW after NAK/STOP and during write-byte shifting (its
  own FIXME); our slave releases SDA per real-chip I2C. Divergence only on paths the game
  never samples.
- Unbounded-hang asymmetry, useful for debugging: pre-fix, the game can NEVER fail
  cleanly (all SCL-echo spins are counterless). Any residual freeze after the de-stub
  points at the 0xac read mux specifically — check it before anything else.
