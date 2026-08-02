# OBSERVATION — gate 5: ddrsbm `HARD-WARE ERROR -1N / CDROM DRIVE TIMEOUT` (2026-07-02, build-free)

Follows `docs/2026-07-02-k573dio-ram-result.md` (gate 4 cleared; this error is
what the game dies with after title/attract, reproducible 2/2 silicon boots).
Memory: `[[fabricore-573-digital-bringup]]`. Produced by a 3-lane observe
workflow (MAME oracle on dell + full-EXE disasm + RTL audit) with an
adversarial reconcile pass — **no RTL changed, no build spent**. Operator
observations folded in: the error followed coin/start past the title on run 2
(run 1 died with zero input during DATA LOADING); attract FMV video played
with NO music (expected today — decode chain unwired — but see H1-reclassified
below: even P4 audio needs the pacing fix first).

## 1. THE VERDICT (reconciled, adversarially checked)

**The timeout is a CD data-path completion stall (H2 class) that PERSISTS
across the game's own recovery resets — NOT the MP3-pacing bug (H1, refuted as
the mechanism) and NOT frame-counter starvation (H3, refuted).**

The error-string discriminator (disasm) is the key: the game prints `CDROM
DRIVE TIMEOUT` **only** when an async READ(12)'s driver status stays `-10`
(in-flight, never completed) for ~45 s **across 2–3 game-issued drive resets**
(watchdogs at 0x80088e44 / 0x80088f30→0x80088fd4 / 0x80095bd0; reset+re-issue
between strikes via 0x800889f0 + the stored-read record). A command that
*completes with error* prints a different string (`CDROM DRIVE ERROR` /
COMMAND / MEDIA). So the silicon mechanism must (a) leave a read incomplete
forever and (b) survive the reset-retry ritual.

## 2. WHAT EACH LANE ESTABLISHED

**MAME oracle (dell, MAME 0.285, golden installed NVRAM, 600 emulated seconds
incl. coin+start gameplay): CLEAN — zero CD errors.** Gate −1 holds; the data
is fine. Workload profile extracted (`local/g5_mame_oracle/g5_ata_e.log`, tap
`g5_ata_profile.lua`):
- POST/memcheck: ZERO ATA traffic (t≈10–150 s).
- DATA LOADING (t≈150–247 s): 497 ATA commands, ~22 MB at ~220 KB/s —
  **32 full drive re-init bundles interleaved with len=64 READ(12) storms.**
- Per song afterwards: one ~920 KB preload (READ12 lba≈2086 len 1, lba≈862
  len 57, lba≈42911 len 450) then a **STOP UNIT (0x1b) ×2 ritual** — and
  **zero CD commands mid-song** (music is never refilled while playing).
- This exact workload is brand-new silicon territory: nothing before gate 4
  ever got past the memcheck to run it.

**EXE disasm (base 0x80010000):** full error-path map (renderer 0x800a5650,
wrapper 0x8002ee34(msg,−1,0) → always "−1N"); the game's own IRQ-driven ATAPI
driver (async READ(12) via 0x8009c9d0, state byte @0x801468d7, ISR 0x8009ba70
acks the 573 IDE latch with `sb 2 → 0x1f802030`, drains via DMA ch5 or PIO,
completion = IRQ with DRQ clear); the CD chunk loader (0x80097a1c,
double-buffer 2×128 KB @0x80380000/0x803a0000, refill gated on a
sectors-remaining counter + buffer flag — **the 0xae streaming bit and 0xa8
frame counter appear NOWHERE in the CD path**); DATA LOADING = MP3 preload
into DIO DRAM over the identical READ(12)+DMA-ch5+b4 path (two list-ordered
iterators → the non-monotonic "No.NN"). ddrsbm never touches key2/key3
(single-key game).

**RTL audit:** confirmed the H1 arithmetic (streamer drains at 6.6–9.7 MB/s
vs a real MAS3507D's 16–40 KB/s, ~200–500×; songs "finish" in ~0.3 s) — real
bug, wrong mechanism. Found the **reset blindspot** that supplies exactly the
persistence the disasm demands:
- `ide_rst` resets `atapi.v` but is **NOT wired to `s573_cdimg`**
  (system573_top.v:278–285 — cdimg gets only clk/rst);
- cdimg samples the 1-clk `sec_req` strobe **only in S_IDLE**
  (s573_cdimg.v:94), waits unboundedly in S_REQ (on cd_ack) and S_STREAM
  (needs exactly 1176 `cd_wr` strobes — counting the GLOBAL `sd_buff_wr`,
  un-gated by `sd_ack[1]`, emu.sv), and raises an **untagged** `sec_ready`;
- so a retry landing mid-fetch silently LOSES the new request, and/or the old
  fetch's buffer is later served as the new LBA's data; `atapi.v` S_FETCH has
  no device timeout — BSY holds forever → driver status `-10` forever → the
  exact observed screen, immune to every drive reset the game throws at it.

## 3. RANKED HYPOTHESES (end state)

1. **H2-refined (LIKELY): async READ(12) completion stall persisting across
   resets** — either the June "data-in never fully drains → completion INTRQ
   never fires" invariant re-manifesting under the new sustained workload,
   and/or the s573_cdimg reset blindspot above. Which variant fires on
   silicon is NOT yet observed (MAME cannot model these RTL/HPS mechanisms —
   its clean run does not clear silicon).
2. **H2a (OPEN, cheap fix warranted): STOP UNIT (0x1b) unimplemented** — the
   ONLY opcode in the whole 10-minute workload that falls to atapi.v's
   default CHECK-CONDITION arm (atapi.v:431–437), while REQUEST SENSE reports
   key 0 (a contradiction) and MAME's CR-589 answers GOOD. Verified unable to
   produce a stuck −10 by itself (the arm completes promptly), but it
   timestamps both silicon death windows (end of DATA LOADING; right after
   coin/start) because it marks where the heavy per-song rituals begin — and
   the game's *reaction* to the sense contradiction may drive extra resets
   into the blindspot.
3. **H1 (REFUTED as the gate-5 mechanism; reclassified)**: the unpaced
   mp3stream is the **music blocker** (P4 must fix pacing, not just wire the
   decoder: songs drain in 0.3 s, the one-shot FSM parks at mp3_end and
   ignores later extensions, 0xa8/0xcc/0xce read 0) and an **amplifier**
   (sequencer cycles songs ~200× faster → per-song CD rituals fire far more
   often on silicon than in MAME) — but it gates no CD traffic.
4. **H3 (REFUTED)**: counters feed only beat-timing math; no CD coupling.

## 4. NEXT MEASUREMENT (build-free, the gate-5 RED test)

Extend the `cdboot` sim pattern (tb_cdboot.v links atapi.v + s573_cdimg.v +
ch5 BFM) into a **gate-5 workload replay bench** driven from the oracle log:
(a) a re-init bundle + back-to-back len=64 READ12s with the HPS ack/stream
latency swept fast→ms-slow; (b) the per-song ritual verbatim (incl. STOP UNIT
×2); (c) **the game's recovery ritual mid-fetch**: pulse ide_rst while cdimg
is in S_REQ / mid-S_STREAM, re-issue the identical READ12, ×3. Assert every
command completes within a bound and served data matches the commanded LBA.
Expected: the bench goes RED on the lost-sec_req / stale-sector / re-wedge
variant — that's the fix's RED/GREEN. Fix directions on the table (NOT
implemented tonight): wire ide_rst into s573_cdimg (+ tag sec_ready with the
LBA, accept sec_req outside S_IDLE), implement STOP UNIT as a GOOD no-op,
and (P4) pace the mp3 streamer.

## 5. ARTIFACTS

- `local/g5_mame_oracle/` — oracle frames (MAME attract/title/gameplay),
  `g5_ata_e.log` (full 600 s ATA trace), `g5_ata_profile.lua` (the tap).
  Mirror on dell `~/System573_MiSTer/local/g5_mame_oracle/`.
- Workflow: `wf_ca19fd9d-d26` (3 observe lanes + reconcile, ~644k tokens).
