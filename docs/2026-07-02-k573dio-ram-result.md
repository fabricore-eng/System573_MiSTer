# RESULT — gate 4: k573dio DIO RAM de-stub, DDR3-backed (MEMORY CHECK 22G/22H/22J)

Implements `docs/2026-07-02-k573dio-ram-plan.md`. Commit `0f74623` on
`feat-digital-bringup`. Memory: `[[fabricore-573-digital-bringup]]`.

## What changed

The DIO board's sample RAM (3x 8 MiB EDO on a real GX894; one flat 32 MiB share
masked `0x1ffffff` in MAME) was an 8 KB sim array — ddrsbm's POST MEMORY CHECK
sweeps 24 MB through the b4 auto-increment port and everything aliased mod 8 KB
→ `22H BAD / 22J BAD / 22G BAD`, CPU halt. The register model was already
MAME-faithful; only the backing was replaced.

- **A0 decision — emu.sv arbiter, no psx_patch.** The psx core is the sole
  DDRAM master and fully exposed at the emu.sv boundary (it pins
  `DDRAM_ADDR[28:25]="0011"`). New `rtl/s573_ddram_arb.v` sits between the psx
  master and the top-level port: psx absolute priority; DIO client gets
  single-beat ops only when psx is completely idle (no command, zero
  outstanding read beats, not mid write-burst — WE gaps tracked); psx sees a
  fake `DDRAM_BUSY` during a DIO op (legal Avalon — the shared f2sdram port
  asserts BUSY arbitrarily anyway). In-order return routing needs no tags by
  construction. `psx/` stays byte-identical.
- **Window: DDR3 bytes 0x32000000–0x33FFFFFF** (32 MiB aligned, MAME-mask
  0x1ffffff). Verified clear of every psx in-window user (VRAM +0, memcard
  staging +1M/+2M, SPU +3M, GPU FBs +4M–8M, rewind +128M, savestates +224M).
  Documented in `PLATFORM.md` "DDR3 map" (with the pre-existing 2MB-VRAM vs
  memcard-staging overlap flagged as a separate task).
- **`rtl/k573dio.v` `BACKING_EXTERNAL`** (s573_flash precedent, so iverilog
  tests all of it): CPU b4 reads through a 2-line beat cache + next-beat
  prefetch (sequential sweep ⇒ steady-state all hits); miss stalls the CPU via
  the new `dio_wait` OR'd into the patch-0006 EXP1 read wait. The wait HOLDS
  the read strobe (verified against memorymux.vhd:956 — `bus_exp1_read` is a
  level decode of `EXT_READ_NEXT`), so the auto-increment is qualified by the
  cache hit and fires exactly once, in the completion cycle, where the
  registered `exp1_rdata` latches the pre-increment data. b4 writes can never
  stall: 1024-deep posted-write FIFO drained as 16-bit-lane byte-enable DDR3
  writes (no read-modify-write — `DDRAM_BE` is native). Coherency =
  drain-before-read + invalidate-on-push + in-flight-fill poisoning (invariant:
  a valid line can never be stale). FIFO overflow = FAULT: sticky
  `dbg_wfifo_ovf` fed into the emu.sv debug band (band 1 R[0], so synthesis
  keeps it SignalTap-able) + `$fatal` in sim.
- **`rtl/k573_mp3stream.v`**: combinational DRAM read → req/ready handshake
  (new S_REQ state); streams through its own beat-hold line at lowest
  scheduler priority. `DDRSBM` param → plumbed `cfg_ddrsbm` port, tied 0 in
  emu.sv until P4 (the descrambled byte stream still dangles — no behavior
  change, but P4 now flips one signal).

## Sim evidence (all green before the build)

- Suite **36 → 38**, all PASS (`make -C sim all`). New targets:
  - `k573dio_ram`: MAME memcheck shape over all three chip bases + the 8 KB
    alias boundary + window top; held-strobe stall semantics (the TB emulates
    the patch-0006 memorymux); 512-halfword sequential sweep; read-pointer
    jumps; burst absorb; FIFO exactly-full boundary (1 in-flight + 1024 queued,
    no overflow, full drain-back); write→read coherency; MP3-line invalidation
    by CPU write. **RED under `DIO_RAM_STUB=1`** with exactly the alias
    signature (locus 0x002000 data read back at 0x000000).
  - `s573_ddram_arb`: protocol scoreboard — random BUSY, psx read/write bursts
    including mid-burst WE gaps, generation-stamped psx write data, both ends
    of the 22-bit DIO beat address path, full both-bank final sweep.
- **Adversarial review before the build** (20-agent workflow: 5 lenses × verify):
  - 1 real RTL bug found & fixed pre-silicon: the write-FIFO pop's same-cycle
    push compensation counted an overflow-DROPPED push, permanently skewing
    `wf_cnt`/rp/wp into stale-slot drains after an overflow. Fixed with a
    shared `push_ok` accept condition.
  - 1 real integration gap fixed: `dio_dbg_ovf` had no synthesis-surviving
    sink (the fail-loud contract was silent on HW) — now in the debug band.
  - 5 TB blind spots fixed and then **mutation-tested**: dropped psx writes,
    DIO address aliasing (the memcheck-class bug shape), and stale-MP3-line
    serves are all now caught (each mutation run RED before landing the fix).
  - 4 findings refuted with cycle traces (notably: no in-spec rd_pend
    underflow; the psx DDRAM outputs were already combinational at the
    boundary, so the arbiter mux adds one mux level, not a new comb stage).
- `sim/Makefile` fix in passing: `.DEFAULT_GOAL := all` (bare `make -C sim`
  had silently become a no-op when `secdata:` was added above `all:` — the
  session-start hook had been running nothing).

## Silicon verify — GATE 4 CLEARED (build 0f74623, rbf 5f5262d5, de10, 2026-07-02)

Timing note: setup met (+2.76 worst); the chronic "requirements not met" flag
is the framework pll_hdmi domain as always, plus fraction-of-ns hold misses at
the Fast −40 °C corner only (TNS −0.555) — bench-irrelevant, silicon confirms.

**MEMORY CHECK: 22H / 22J / 22G all OK — captured directly.**
De-confounded chain (devlock reboot → uptime 20 s → strap poke → ONE
load_core): `local/dio_v5_watch_036.png` = `22H CHECKING`,
`_037` = **`22H OK` (green) / `22J CHECKING`**, then the game proceeded through
DATA LOADING to the attract FMV (`_046`) and the **DDR Solo Bass Mix title
screen** (`_047`) — the first ddrsbm gameplay visuals ever on this core. The
BAD case halts the CPU forever (0x8009a578), so progression past the check is
itself the all-OK verdict; frames 036/037 sit at 0.43 % differ / SSIM 0.992 vs
the BAD anchor (same layout, verdict words only).

**Install regression: PASS, golden-exact.** The full CD install ran on this
build (erase 87 %→100 % + program + auto-save) and the auto-saved
`ddrsbm.sav` is md5-identical to the MAME golden
`82243fe3121cb23e97fec37b9ed0b8ef` — the silicon-proven flash path is
untouched, and the DDR3 arbiter underneath changed nothing.

**Two operational discoveries (both fixed):**
1. *Slot-4 remembered mount, worse than documented:* `config/System573.s4`
   pointed at a MISSING `powyakex.sav`; Main mounted NOTHING and the .mgl's
   s4 entry did not rebind even though `ddrsbm.sav` exists. Fix (recorded in
   `local/tracedig/dio_verify_v5_memcheck.sh`): rewrite the 1024-byte S4 file
   (`<path>\0.bin\0` NUL-padded) at MENU time, before load_core. Proven: the
   install auto-save landed in `ddrsbm.sav`.
2. *The installed-flag lives in the M48T58 NVRAM*, and the core has no NVRAM
   save-back — loading `nvram8k_blank.bin` made every COLD boot re-run the
   installer even with the golden flash restored (the prior session only ever
   reached the memcheck via the installer's SOFT reboot, which keeps the
   in-core NVRAM). Fix: `.mgl` index 3 now loads
   `ddrsbm_nvram_installed.bin` = the MAME golden post-install m48t58
   (md5 `73f2c6fa20de8cfa1b51fca80699697a`, from dell
   `local_golden/ddrsbm/nvram_run1/m48t58`) — the 1-minute cold-boot
   memcheck verify is now real.

**NEW GATE FOUND (gate 5): `HARD-WARE ERROR -1N / CDROM DRIVE TIMEOUT`,
reproducible 2/2 boots.** After the memcheck, the game DATA-LOADs dozens of
files from CD (multi-phase, non-monotonic numbering), reaches attract/title,
and dies with the CD timeout ~40 s into attract (`local/dio_v5_watch_048+`;
first occurrence `local/dio_verify_v4_postinstall_d.png` mid-DATA-LOADING).
This territory was unreachable before gate 4 (memcheck BAD blocked it);
`atapi.v` is untouched by this change. Observe-first next: PC-first probe +
which ATAPI command/LBA pattern the attract streamer issues when it dies
(the silicon-hang heuristics apply — steady-state PC snapshot first).

**Boot regressions (strap cleared, `regress_boot_v1.sh`, de-confounded
uptime-19s ONE-load_core runs): both PASS at prior baselines.**
- powyakex: t60→t120 62.84 % differ / luma 1.9→83.8, t120→t180 62.90 % / 83.8→83.2
  (prior baseline 62–64 %, luma →84).
- hyperbbc: t60→t120 63.98 % / luma 1.6→54.0, t120→t180 64.27 % / 54.0→53.5
  (prior baseline 64–68 %, →52).

## State of the world (end of session)

- de10: rbf `5f5262d5` deployed; strap byte CLEARED; `ddrsbm.sav` = golden
  (freshly re-proven); `config/System573.s4` → ddrsbm.sav; the ddrsbm .mgl now
  loads `ddrsbm_nvram_installed.bin` (index 3) — a cold boot goes straight to
  POST/memcheck/attract; devlock RELEASED. Board parked at the gate-5 CDROM
  TIMEOUT screen (harmless).
- Suite 38/38 (`make -C sim` works again — `.DEFAULT_GOAL := all`).
- New assets: `s573_ddram_arb` + `k573dio_ram` TBs (mutation-tested),
  `dio_verify_v5_memcheck.sh` (S4 fix + tight memcheck cadence), the installed
  m48t58 golden (`local/ddrsbm_nvram_installed.bin`, staged on de10),
  frame-diff printer bugs fixed in the verify/regress scripts.
- `dbg-signaltap-atapi-irq` fast-forwarded to `32daf9f` (memcard/VRAM
  no-overlap doc + the tb_s573_io expectation fix) — useful base for the
  gate-5 ATAPI observe work.

## Next gate

Gate 5: the attract-loop CDROM DRIVE TIMEOUT (observe-first, ATAPI lane).
Then P4 (MP3 audio proper): mas3507d frame_count, HPS-side minimp3 decode +
PCM transport (rides the same marginal f2sdram bridge — plan the in-RTL
ballast), per-game `cfg_ddrsbm`.
