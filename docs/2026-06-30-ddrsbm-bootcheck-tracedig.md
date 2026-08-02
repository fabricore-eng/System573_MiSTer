# ★ FINDING — ddrsbm BOOT CHECK: the IDENTIFY-settle fix targets a race that does NOT exist (2026-06-30)

Deliverable of the §5 trace-dig (plan: `docs/2026-06-30-ddrsbm-bootcheck-tracedig-handoff.md`).
Free, no-build. Supersedes the H1-vs-H2 framing. Memory: `[[fabricore-573-digital-bringup]]`.
Prior (now partly corrected) root-cause: `docs/2026-06-25-ddrsbm-identify-irq-race-handoff.md`.

---

## 1. VERDICT (one line)
The plan's H1 ("settle too short") vs H2 ("a later command races") fork is **moot**: both assume
a "driver sets the transfer-pending state byte AFTER the command write → instant IRQ → ISR skips
the drain" race that **does not exist on any ddrsbm drive-check command path**. The committed
`IDENT_SETTLE=2048`/`S_PREP` fix (`a5823f7`) therefore cannot change anything — which is exactly
why BOOT CHECK persisted. **Do NOT spend a build tuning the settle.** The real fault is in
atapi.v's INTRQ-edge / data-in handshake on silicon; the cheapest next step is a sim-vs-MAME ATA
transaction diff (no build), then a targeted SignalTap — details in §6.

## 2. How this was established (Phases 0–2, all offline)
- **Disasm** of `local/ddrsbm_code.bin` (MIPS32 LE, R3000A; base **0x803c0000** — confirmed: at
  0x803cb324 `lbu 4($v0)`=trace "seccnt/ir", 0x803cb334 `lbu 8($v0)`=trace "lbamid/bc", every
  landmark PC is a load exactly where the MAME trace shows a read). Full listing:
  `local/tracedig/ddrsbm_full_code.asm`.
- **MAME trace** `local/ddrsbm_ata_full.log` (PC-annotated, every task-file access) — the WORKING
  reference. Timeline in `local/tracedig/MAME_TIMELINE.md`.
- **RTL** `rtl/atapi.v` (the fix under test).
- **Adversarial verification** (a workflow: 3 independent re-derivations + 3 refutation skeptics).

## 3. Clock/units (the linchpin — resolved)
- atapi.v runs on `clk` = **clk1x = 33.8688 MHz**; `IDENT_SETTLE=2048` decrements once/clk in
  S_PREP → **2048 clk1x = 60.5 µs**. The PSX **R3000A CPU is also 33.8688 MHz = clk1x**, so 1 CPU
  cycle ≈ 1 settle count (loads/stores add I/O wait states).
- **T_timeout** = `0xf690` = **63120** loop iterations, passed in $a0/$a2 to the bounded waits
  (0x803cb010, 0x803cb104, 0x803cb4b8). `IDENT_SETTLE` (2048) ≈ **3%** of it → "settle too long"
  (H1's mirror) is impossible, as already suspected.
- **W_setup** (cmd-write → state-set) — the quantity the plan wanted to pin — **does not exist as
  a positive value**: on every path the state-set (or the completion-counter snapshot) precedes
  the IRQ-triggering write. Its effective value is "always safe," so it cannot select H1 vs H2.

## 4. THE MECHANISM (what the driver actually does)
State byte **@0x803d228f** drives the ISR (`0x803cb2dc`) dispatch: `0`→skip-to-exit/no-drain
(`beqz 0x803cb364`), `1`→ISR PIO-drain (0x803cb284), `2`→ISR DMA-drain (0x803cddb8), `3`→done.
Completion is detected by a **count-based foreground wait** `0x803cb4b8`: it spins until the ISR's
IRQ counter `[0x803d2280]` differs from a **snapshot `[0x803d2284]` taken before the command**. The
ISR *always* bumps that counter (and saves status @0x803d2288), regardless of the state byte.

Two drain styles, both race-free by construction:
- **Self-drain** (IDENTIFY + several PACKETs): set state=0, **snapshot the counter BEFORE the
  command/CDB write**, issue, wait for the counter to advance, then the *foreground* drains via its
  own PIO loop. The ISR's state==0 skip is **by design**.
- **ISR-drain** (async PACKETs): the caller sets state=1/2 **BEFORE** `jal` to the packet-issue
  core (`0x803cbc90`) that writes the 12th CDB byte (the IRQ trigger).

## 5. EVERY drive-check command path (exhaustive; none races)
Verified across the disasm; all 7 command-register (offset 0xe) writes + all state-byte writes.

| Command / routine | IRQ-trigger write | state-set / counter-snapshot | Order |
|---|---|---|---|
| IDENTIFY 0xA1 `0x803cb7c4` (self-drain) | cmd `0x803cb840` | snapshot `0x803cb834` (state=0 `0x803cb7d8`) | **before** |
| PACKET core `0x803cbc90` (ISR-drain) via callers ↓ | 12th CDB (`0x803cb258`) | caller sets state before `jal` | **before** |
| · READ(12) 0xA8 caller `0x803cbe94` | " | state=2 `0x803cbef8` | **before** |
| · async-read caller `0x803cc2b0` | " | state=1/2 `0x803cc324` | **before** |
| · SET CD SPEED 0x4B caller `0x803cc4ec` | " | state=1 `0x803cc548` | **before** |
| · READ SUB-CHANNEL 0x42 caller `0x803cc578` | " | state=1 `0x803cc5d8` | **before** |
| PACKET self-drain core `0x803cbd30` (READ TOC 0x43, MODE SENSE 0x5A, READ CAP 0x25) | 12th CDB | snapshot `0x803cbdc8` (state=0 `0x803cbd5c`) | **before** |
| TEST UNIT READY 0x00 `0x803cba34` (non-data) | 12th CDB | snapshot `0x803cbac4` (state=0 `0x803cba48`) | **before** |
| REQUEST SENSE 0x03 `0x803cbb14` (data-in) | 12th CDB | snapshot `0x803cbbb4` (state=0 `0x803cbb28`) | **before** |
| MODE SELECT(10) 0x55 (data-OUT) | CDB `0x803cc16c` | snapshot before each write | **before** |
| PLAY AUDIO 0x45 `0x803cc3e0` | non-data (atapi.v → CHECK COND) | only READS state as a guard | n/a |
| SET FEATURES 0xEF `0x803cb9e8` | cmd write | non-data | n/a |

**No path sets the state byte to 1/2 (or omits the counter snapshot) AFTER the IRQ-trigger write.**

## 6. Empirical confirmation (MAME = the oracle, from the existing trace)
MAME with this exact data (Gate −1 satisfied — MAME reads it fine):
- **f140:** IDENTIFY 0xA1 issued once → the ISR fires (state=0, skip, counter++) → the foreground
  drains **256 half-word reads at 0x803cb8b4 = the full 512-byte IDENTIFY block** → completion IRQ.
  So IDENTIFY draining is a *foreground* job; the ISR skip the prior session saw is normal.
- **f141:** ~10 PACKET commands, each a 12-byte CDB (6 writes at 0x803cb26c), all drained.
- **f142→165 (truncation):** only periodic post-completion ISR status reads. MAME **completed the
  whole drive check in ~2 frames** and moved on. The "stuck" tail was just where the capture was
  killed (`local/ddrsbm_ata_full.log` has no `# end` marker), not a wedge.

Corollary: the 2026-06-25 root cause **misattributed** the drain to the ISR. Its SignalTap
evidence ("ISR takes state==0 skip on the 512-byte IDENTIFY IRQ; ridx=0 during the ISR window") is
**consistent with normal operation** — the foreground drain runs *after* the ISR window, so ridx=0
during the ISR window proves nothing.

## 7. ADVERSARIAL VERIFICATION (this is the build-gating check)
Workflow `ddrsbm-race-verify` (6 agents, 572k tokens):
- **3 independent analysts** (one blind to the brief; one critiquing it; one on the RTL/silicon
  angle): **all `race_exists=false`** (2 high-confidence, 1 medium). The blind analyst independently
  found 4 command paths the brief missed — all still race-free.
- **3 refutation skeptics**, instructed to try HARD to find a race and to *default to "the fix was
  correct"*: **all returned `no-race-confirmed`**, `found_racing_path=false`. Skeptic 0 audited all
  7 command-register writes. None could construct a racing path OR a non-race "settle-helps"
  mechanism (ISR storm rejected — reg7 read clears irq_pending, one clean ack/event; DRQ/ridx
  perturbation rejected — both RED and settle raise DRQ+INTRQ together).

## 8. THE REAL CAUSE (ranked, convergent across agents)
1. **[HIGH] Missed / dropped INTRQ edge on silicon.** The count-based wait `0x803cb4b8` only
   advances when the ISR actually runs, which requires atapi.v's INTRQ *rising edge* to be latched
   into psx `irq.vhd` I_STATUS bit10. If an edge is lost — the `irq_out` 1-clk re-arm gap
   (atapi.v:314-319) too short for irq.vhd's sampling, a data-ready→completion double-event
   collision, nIEN/`r_devctl[1]` masking, or the 573 IDE INTRQ→IRQ10 wiring/latch @0x1f802030 —
   the counter never advances → `0xf690` timeout → drive check fails → BOOT CHECK. This is
   edge-*timing*, invisible in MAME's logical model, and unaffected by IDENT_SETTLE.
2. **[MED] The stall is on a PACKET data-in command (not IDENTIFY)**, or a byte-count/handshake
   mismatch (atapi.v response fields vs what the POST validates), or a missed *completion* edge on
   the ISR-drained path. IDENT_SETTLE does nothing for any of these.
3. **[MED] BSY/DRQ status-poll timing vs the real CR-589**: the `0x803cb010`/`0x803cb104` poll
   loops sample a status the RTL presents a cycle off from what silicon expects → bounded-wait
   timeout on a specific command.

## 9. RECOMMENDED NEXT STEP (NOT another settle build)
- **(A) Nearly-free, NO build — do this first:** run the RTL in sim through the drive check
  (existing NVC/iverilog harness + the CD-image/ATAPI model), capture the ATA register R/W
  transaction sequence, and **diff it per-command against `local/ddrsbm_ata_full.log`**. The first
  divergence (a command whose data/completion IRQ, byte count, or status differs) pinpoints the
  failing handshake without any FPGA build. Consider a fresh, **non-truncated** MAME trace
  (`with_progress.sh "mame ddrsbm ata-tap" -- …`) as the golden side.
- **(B) Definitive — one instrumented build:** SignalTap on de10 capturing atapi.v
  `{state, irq_out, irq_pending, irq_event, r_devctl[1], r_status, ridx}` **plus** psx irq.vhd
  I_STATUS bit10, triggered on the command-reg write and on each PACKET 12th-CDB-byte write. Count
  INTRQ asserts vs ISR entries vs counter increments @0x803d2280 — proves/refutes the dropped-edge
  hypothesis directly. (Uses the SignalTap rig already planned in `[[fabricore-573-digital-bringup]]`.)

## 10. Disposition of the committed fix `a5823f7` (S_PREP / IDENT_SETTLE)
**Benign but not the fix.** It only delays IDENTIFY's DRQ+INTRQ raise by 60 µs; IDENTIFY
self-drains regardless, and both paths raise DRQ+INTRQ together, so it neither helps nor harms
(well under the 0xf690 timeout). Recommendation: **leave it in place for now** (harmless, mirrors
the disc-read S_FETCH pacing, documented here) and **stop tuning it**; fold a revert-or-keep
decision into the real INTRQ-edge fix when it lands. The RED/GREEN test `sim/tb_atapi_settle.v`
stays valid as a regression for the S_PREP behavior itself.

## 12. DIAGNOSTIC (A) RESULT — sim register + modeled-IRQ levels are CLEAN; suspect localized to the ce-gated IRQ edge
Ran diagnostic (A) (§9). Outcome: **the offline sim does NOT reproduce the hang — at either level it
models — which pins the divergence to the one thing it can't model: the ce-gated INTRQ edge delivery.**

- **`sim/tb_drivecheck.v` (register handshake) → PASS.** Replays the drive-check register sequence
  (IDENTIFY 0xA1 + REQUEST SENSE/READ TOC/MODE SENSE/MODE SELECT) against `system573_top`; every DRQ,
  status, byte-count, ireason matches. So atapi.v's register-level responses are correct. (It uses
  BSY/status *polling* for completion and explicitly isolates the CPU/IRQ path — so it can't see an
  IRQ-delivery bug.)
- **`sim/tb_irqdeliver.v` (modeled INTRQ edge) → PASS.** Drives atapi.v through the exact drive-check
  IRQ sequence and checks that every interrupt event yields a fresh `intrq` 0→1 edge (no coalescing),
  through a *behavioral* replica of irq.vhd's bit10 latch. Passes: `intrq` edges == events.

**The gap between those passing sims and the hanging silicon — located exactly:**
- atapi.v drives `intrq` **free-running on `clk_1x`** (system573_top `.clk(clk_1x)`, no clock-enable).
  It reaches the CPU via `psx_patches/0001` which OR's `exp_irq10` **combinationally** into
  `irq_LIGHTPEN` → `irqIn(10)` (emu.sv `.cdrom_irq(exp_irq10)`).
- The real `psx/rtl/irq.vhd` samples `irqIn` and does its rising-edge detect
  (`irqIn_1<=irqIn; I_STATUSNew := … or (irqIn and not irqIn_1)`) **only inside `elsif (ce='1')`**
  (lines 97,125-126). `ce` (generated in the clk2x domain) drops to 0 while the clk1x core stalls on
  memory/bus accesses — which is most of the drive check (slow EXP1/IDE reads).
- `tb_irqdeliver`'s replica is **ungated** (samples every clk), so it structurally cannot expose this.
- **Hazard:** the edge detector must sample the intervening LOW (`irqIn_1<=0`) on a `ce=1` cycle
  before it can detect the *next* rise. An `intrq` fall→rise that straddles a `ce=0`-only window (or a
  1-clk re-arm gap in a `ce=0` window) is **never latched into I_STATUS bit10** → the ISR isn't
  re-entered → the driver's IRQ-counter (`0x803d2280`) never advances → the count-based completion
  wait `0x803cb4b8` times out (`0xf690`) → BOOT CHECK. This is precisely the [HIGH] hypothesis (§8),
  now mechanistic. Held-high levels are safe; the exposure is the fall→rise timing under real `ce`
  stalls, which the isolated Verilog TBs (held levels + inter-access `ce=1` gaps) don't recreate.

**Why (A) can't go further offline:** faithfully reproducing it needs the real `ce`/EXP1-wait +
CDC dynamics — effectively the full CPU-driven sim (Verilator can't build the VHDL PSX core; NVC can
elaborate it but a mixed atapi(V)+irq(VHDL) co-sim needs an FFI bridge — see `[[sim-toolchain-verdict]]`).
So (A) has done its job: **ruled out the register/logic level and localized the fault to the ce-gated
/ CDC INTRQ-edge delivery (or silicon timing on that path).**

**DECISIVE NEXT = (B) SignalTap on de10** (one instrumented build). Capture, in the clk1x domain:
`atapi.irq_out`, `atapi.irq_pending`, `atapi.irq_event`, the psx `ce`, `I_STATUS[10]`, `I_MASK[10]`;
trigger on the command-reg (offset 0xe) write and each PACKET 12th-CDB-byte write. **Invariant to
check:** count `irq_out` 0→1 rising edges vs `I_STATUS[10]` 0→1 sets vs ISR-counter increments
`@0x803d2280`. If `irq_out` edges **>** `I_STATUS[10]` sets → a dropped edge (ce-gating/CDC) is
confirmed. **Fix direction (NOT another settle):** make the `exp_irq10`→psx IRQ10 injection
ce-robust — latch the edge in the `ce` domain / hold-until-acked so the ce-gated detector cannot miss
it (an atapi/patch change), rather than relying on atapi's free-running `intrq` level.

## 11. Artifacts
- Disasm: `local/tracedig/ddrsbm_full_code.asm` (base 0x803c0000), `…/ddrsbm_code_b000_e000.asm`.
- Evidence brief handed to the verifier: `local/tracedig/EVIDENCE_BRIEF.md`.
- MAME timeline: `local/tracedig/MAME_TIMELINE.md`. Raw MAME trace: `local/ddrsbm_ata_full.log`.
- BIOS pulled for the dig: `local/tracedig/573bios.bin` (md5 48304fdb). SignalTap decoders:
  `local/tracedig/read_atapi_{pc,csv}.py` (from `dbg-signaltap-atapi-irq`).
- Verifier workflow result: task `wool7zgy4` (6 agents; unanimous no-race).
- Stuck-state evidence (prior): `local/ddrsbm_de10_bootcheck_a5823f7.png`.

## 13. SIGNALTAP RESULT (diagnostic B, live on silicon) — the drain never completes; NOT delivery, dispatch, or the ce-edge
Built + captured a re-scoped ATAPI-IRQ SignalTap probe on the CURRENT core (branch
`dbg-signaltap-atapi-wedge`, rbf `bf341bc4`, 94 signals incl. full I_STATUS[10:0]+I_MASK[10:0],
PC, ridx, r_status, irq_out/irq_pending, ce; depth 4096 @ clk2x). De-confounded on de10,
Heisenbug-gate PASSED (still parks at BOOT CHECK). Live capture `local/signaltap/20260630_183607/`,
decoded in `local/tracedig/wedge_capture_{decode,timeseries}.txt`. **Adversarially verified by a
3-agent workflow (task `wqekudb5o`) that independently re-derived every number and CORRECTED two
over-reads of mine.**

**CONFIRMED (robust across all 3 captures — this + the two 2026-06-24 ones — independently re-derived):**
- IRQ **delivery + latch is clean**: `ce`=1.000 the whole window; **only** I_STATUS bit 10 (ATAPI)
  ever sets (no rogue IRQ); exactly **1 `irq_out` rising edge → 1 I_STATUS[10] latch** (no dropped/
  doubled/coalesced edge); `I_MASK[10]`=1 (enabled) throughout. So it is **NOT** a dropped edge,
  **NOT** ce-gating (§12 walked back), **NOT** a rogue-IRQ storm, **NOT** an IRQ10/LIGHTPEN routing
  mismatch. The exp_irq10→irq_LIGHTPEN→I_STATUS[10] path and the ce-gated latch behave correctly.
- **The recurring FAILURE INVARIANT across every capture:** the ATAPI data-in block **never fully
  drains** — `ridx` stalls (0 in the live capture; 102 of 256 in the best prior capture) — **and
  `irq_out` is never cleared by a reg7 status read** (INTRQ never acked to completion), so the
  foreground sits forever in the counter-based completion-wait `0x803cb4b8` → BOOT CHECK.
- The completion INTRQ in `atapi.v` (lines ~540-559) is **DATA-DRIVEN** — it fires only the cycle the
  host consumes the LAST word. Since the drain never reaches `resp_len`, the completion INTRQ is
  **never generated**, the ISR's counter (`0x803d2280`) never gets its final increment, and the
  foreground wait never returns.

**REFUTED / corrected (my live-capture over-reads):**
- "~10× re-entering the 0x80000080 exception" → actually **one** exception entry + a ~10-sample dwell.
- "CPU permanently trapped in the BIOS kernel; game ISR never dispatches" → **REFUTED.** The game ISR
  (`0x803cb2dc`) **does** run in the two prior captures (195945: 338 samples; 201105: runs AND drains
  to ridx=102). The kernel dispatches IRQ10 normally via the standard PSX `SysEnqIntRP` chain
  (handler `0x803c7b88` + verifier `0x803c7bf0`, registered at `0x803c7ad8`). The live 60 µs snapshot
  merely caught a pre-dispatch phase (verifier read "not mine" before the ISR's turn). **The exact
  trap-location is phase-of-hang, not ground truth.**

**CORRECTED FIX DIRECTION (both skeptics converge, high confidence):** aim at the **ATAPI data-in
DRAIN / COMPLETION-HANDSHAKE**, not delivery/dispatch/edge. Investigate why the drain (ISR PIO
`0x803cb284` / ch5-DMA `0x803cddb8`, or IDENTIFY's own foreground loop `0x803cb8b4`) does not consume
all words on silicon → `atapi.v` data-in serving: `data_consume`/`pio_data_rd` qualification (line
289-290), the S_FETCH/S_DATAIN prefetch+skid pipeline, `dma_req`/`dma_dout` valid-on-consume
(528-562). **Prime suspect = the LATENT bug in §10:** `dma_req` is gated to `datain_disc && cd_attached`
only, so any drive-check data-in command that the driver drains via **ch5 DMA (state=2)** on a
NON-disc response (IDENTIFY/INQUIRY/TOC/etc.) gets **no `dma_dout` data** → `ridx` never advances →
exactly this stall. Confirm which drive-check data-in commands take the DMA (state=2) path.
Deprioritize the `IDENT_SETTLE` fix (confirmed dead).

**NEXT EVIDENCE (to pin the stall):** re-capture with the reg7-read strobe (`sel&re&addr==7`, the ack)
+ the `dma_rd`/`data_consume` strobe, and **trigger on the completion transition (S_DATAIN→S_IDLE) or
ridx==resp_len-2** (anchor on the event the foreground blocks on) with a longer/rolling window — to
see whether the block ever drains, where it stalls, and whether the ack ever fires.

## 14. DRAIN-PATH ANALYSIS (free, no build) — the `data_consume` strobe is the suspect (hypothesis; over/under-count unresolved)
3-analyst + synthesis workflow (task `wr330sru6`) on the PIO data-in drain. Convergent finding:
- **atapi.v `data_consume` is a free-running LEVEL term** — `pio_data_rd = sel && re && addr==4'd0`
  (atapi.v:289-290), sampled every posedge clk_1x, **no `re` rising-edge qualifier, no `ce` gate.**
  Its strobe `re = atapi_sel & exp1_re` traces to `bus_exp1_read` = a LEVEL held while the psx
  memorymux FSM is in `EXT_READ_NEXT` (memorymux.vhd:956), and that FSM only advances on `ce=1`.
- So ONE CPU `lhu` from reg0 (0x1f480000) can register as the WRONG number of `data_consume`
  events → `ridx` drifts out of lockstep with the driver's fixed read count (256 words for IDENTIFY)
  → the data-driven completion INTRQ (`ridx+2>=resp_len`) never lines up → never fires → BOOT CHECK.
  Two over-count mechanisms: (a) 16-bit `lhu` at EXP1 **width=0** → two `EXT_READ_NEXT` beats
  (byteStep 00,01) → 2 consumes/read; (b) **ce-stall level-hold** → `bus_exp1_read` held across N
  frozen clk_1x edges → N consumes/read. Both are invisible to `tb_drivecheck`/`tb_atapi_cdread`,
  which pulse `re` for exactly ONE posedge per read (1 read = 1 consume) — the sim/silicon gap.
- **Candidate fix (RTL, ~3 lines):** edge-qualify the consume — `reg re_q; re_q <= sel&&re&&addr==0;`
  and `pio_data_rd = sel&&re&&addr==4'd0 && !re_q;` — so one bus read = one `ridx` advance regardless
  of hold length/beats. Leaves both tbs green; a new `exp1_read_twobeat`/`_cestall` tb task (or a
  co-sim feeding the REAL memorymux strobe into atapi) reproduces the desync and proves the fix offline.

**HONEST residual uncertainty (do NOT treat as confirmed):**
- The double-beat is conditional on EXP1 **width=0**; `psx_patches/0001` says normal 573 runs EXP1
  16-bit (width=1 → one beat/read), and `ce`=1.000 in the (pre-dispatch) window that had ce data —
  both weaken the over-count mechanisms. What ddrsbm actually programs into `ex1_memctrl` is unseen.
- **Direction unresolved (over- vs under-count):** "completion NEVER generated" + `ridx` observed
  LOW (0, or 102 of 256) with **DRQ HELD** and **state staying S_DATAIN** actually fits an
  UNDER-count / missed-read (or a narrow-strobe not sampled) better than an over-count — an
  over-count would reach `resp_len` EARLY, fire completion, and LEAVE S_DATAIN (DRQ would drop),
  which we do NOT see. The edge-detect fix targets over-count, so it may be the wrong direction.
- The current captures carry **no `data_consume`/`re`/reg7-ack strobe**, so none actually shows a
  miscount — over/under/correct-count is undetermined from them.
- **DEFINITIVE cheap disambiguator = the drain-anchored SignalTap re-capture (§13 NEXT):** add the
  `data_consume`/`re`(addr==0) strobe + the reg7-read (ack) strobe + `ext_byteStep`/`reqsize` + `ce`,
  trigger on S_DATAIN entry with a rolling window → directly count consumes-per-`lhu` and see whether
  `ridx` over- or under-advances and whether the ack ever fires. That picks the exact fix.
