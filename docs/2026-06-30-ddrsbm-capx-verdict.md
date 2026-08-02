# ★ CAPTURE-X VERDICT — ddrsbm BOOT CHECK: atapi.v EXONERATED; the game's IRQ-chain predicate DECLINES the completion IRQ

De-confounded on-silicon SignalTap "capture-X" (`local/signaltap/20260630_223849`, PC[23:2] + dma taps,
DRQ-entry trigger), adversarially verified (workflow `w6ych2a91`: 3 analysts w/ independent capstone disasm
→ reconcile → 2 refuters → final). Supersedes the "3 host-side candidates" open question of
`docs/2026-06-30-ddrsbm-drain-capture-finding.md`. Memory `[[fabricore-573-digital-bringup]]`.

---

## 1. ONE-LINE VERDICT
The ATAPI device (`atapi.v`), the PSX interrupt latch, and the BIOS interrupt dispatcher are **ALL proven
healthy and EXONERATED**. The hang is **game-software-side, one level downstream of a fully-working dispatch
chain**: the game's own IRQ-chain **predicate `0x803c7bf0`** reads its handler-descriptor struct
`@0x803cf4fc`, finds the **enable bit ([+4]&1) set but the pending/owned bit ([+0]&1) CLEAR**, and returns
"NOT MINE" — so the drain-ISR body (`0x803cb2dc`) is never entered, no ATAPI read/ack is ever issued, `ridx`
stays 0, the IRQ is never acked, and the CPU degenerates into the BIOS ReturnFromException loop → BOOT CHECK.
**Candidate (c) "reads never reach atapi `sel`" survives (strong form: the CPU never issues ANY ATAPI read);
(a) and (b DMA) are refuted.** **Do NOT touch `atapi.v`, the PSX I_STATUS latch, or the BIOS dispatch.**

## 2. WHAT MY EARLIER (SAME-SESSION) READ GOT WRONG — corrected by the verify pass
My interim read — *"the CPU is stuck in the BIOS kernel, dispatch failed to reach the ISR"* — was an
OVER-READ. The BIOS dispatch is **healthy**: it takes the exception exactly once (`0x80000080` @row 541-564,
no re-vector storm), runs the dispatcher (`0x80000c80`), and **does invoke the game's registered predicate
`0x803c7bf0`** (rows 1551-1656, a full 106-sample visit, clean return). §13's "the game handler runs / the
kernel dispatches normally" is **literally true**. The correction is only the *label*: what runs is the
chain **predicate**, not the **drain-ISR body** — and it **declines**. The terminal BIOS loop
(`0x80001bb8-c30` = ReturnFromException machinery, capstone-confirmed) is the *consequence* of the declined
IRQ, not a stuck dispatcher.

## 3. VERIFIED FACTS (HIGH confidence — 3 independent parsers + capstone 5.0.7; both adversaries agree)
- **Stuck cmd = IDENTIFY 0xA1** (byte-count 0x0200 every defined row).
- **`ridx` flat 0; ALL seven strobes flat 0** (`dbg_re/sel/we/pio_rd/consume/dma_rd/dma_req`) — **no ATAPI
  register access of any kind, no PIO read, no consume, no DMA request.**
- **DMA(b) RULED OUT:** `dbg_dma_req = dbg_dma_rd = 0` the whole window (and absent from the 8192 probe).
- `r_status`: 0x80 (BSY) rows 1-512 → **single edge to 0x48 (DRDY|DRQ) at row 513** = S_DATAIN entry = trigger.
  Drive sits in PIO DRQ, waiting to be drained, to the end.
- **IRQ latch clean + single** (ce=1 throughout): `irq_pending`↑513, `irq_out`↑515, `I_STATUS[10]`↑517.
  Within the 4096 window the IRQ **never clears** (reg7-ack = `sel&&re&&addr==7` never fires; `dbg_re`=0).
- **The drain ISR NEVER runs:** `0x803cb2dc` (ISR), `0x803cb284` (PIO drain), `0x803cb884/8b4` (self-drain),
  `0x803cb4b8` (completion-wait), `0x803cb7c4` (IDENTIFY driver) = **0 post-trigger samples each**. The only
  `0x803cbxxx` samples (30, rows 255-284, PRE-trigger) are the completion-wait poll `0x803cb530-540`.
- **The predicate `0x803c7bf0`** (capstone-disassembled): loads `@0x803cf4fc` (ptr = `[0x803d0000-0xb04]`),
  tests `[ptr+4]&1` (enable, SET) and `[ptr+0]&1` (pending/owned, **CLEAR**) → `move $v0,$zero`; returns 0
  ("not mine"). Touches **no hardware**.
- **8192-sample corroboration** (`…_204524`, irqout trigger): also `ridx`=0, all strobes 0, `r_status` stays
  0x48, byte-count 0x200. The IRQ *does* eventually clear there — but via a **PS1-controller-side ack**
  (`I_STATUS[10]`↓ 144 rows before atapi `irq_pending`; `dbg_sel/re/we`=0; no reset signature) i.e. the CPU
  dismisses IRQ10 at the PSX side **with provably no ATAPI drain/read/reset**. **`I_MASK[10]` = 1** (IRQ10
  unmasked at the controller).

## 4. ROOT CAUSE (best supported)
A **never-drained ATAPI completion IRQ whose drain-ISR is never dispatched because the game's own chain
predicate declines it.** Hardware INTRQ → PSX latch → CPU exception → BIOS dispatch → game predicate are ALL
correct and run. The predicate declines because the game's **software pending/ownership flag `@0x803cf4fc+0`
was never set to 1** at decision time → the drain never happens → indefinite hang.

## 5. RECONCILIATION WITH §12 / §13
- **§13 "delivery+latch clean" — CONFIRMED** (single staged edge). **§13 "game ISR runs / kernel dispatches
  normally" — substantively CONFIRMED** (the game's registered predicate WAS entered). Only relabel
  predicate≠drain-ISR-body. (My interim "§13 contradicted" was itself wrong — do not re-open §13.)
- **§12 suspect AREA (0x80000000 BIOS dispatcher) — right neighborhood; MECHANISM (ce-gated INTRQ-edge
  delivery failure) — REFUTED.** The edge is delivered+latched perfectly (ce=1, one clean edge); the
  dispatcher runs and progresses. Not a missed edge, not a broken dispatcher.

## 6. THE OPEN QUESTION + NEXT STEP (no atapi.v rebuild — device exonerated)
Why is `@0x803cf4fc+0` (pending/owned) clear when the predicate runs? Two readings:
- **(1) Never-armed:** the game's ATAPI command-issue / handler-arm path never sets that bit on our core.
- **(2) Armed-late RACE:** the completion IRQ arrives before the game marks its descriptor pending. *(This
  is the SAME race the `IDENT_SETTLE`=2048 fix targeted — which is "dead" → the 2048-clk settle is either
  insufficient, or the bit is a different flag than the settle assumed.)*

**Deciding step — prefer the FREE trace-dig first (no build):**
- Disassemble the game's ATAPI command-issue/handler-arm path (from `local/tracedig/ddrsbm_full_code.asm`):
  where/when does it write `@0x803cf4fc+0` (set bit0)? Before or after the `0xA1` IDENTIFY command write
  (which raises the IRQ after the S_PREP settle)?
- **MAME oracle** (ddrsbm boots fine, Gate −1): trace MAME's writes to `@0x803cf4fc` relative to the IDENTIFY
  IRQ — the CORRECT arm timing. Compare to our core's IRQ timing. If MAME sets the bit BEFORE the IRQ and our
  core's IRQ beats it → armed-late race (fix = correct the settle/handshake). If the game never sets it on our
  core → a data/state difference the driver checks before arming.
- **Only if the trace-dig is inconclusive, capture-Y (rebuild):** a widened PC+DATA SignalTap that taps the
  runtime words the predicate reads — `@0x803cf4fc` `+0`/`+4` at the predicate's loads (~`0x803c7bf0/bfc`) —
  or a memory-write tap on `@0x803cf4fc`, to see arm-vs-IRQ timing directly. **DOWNGRADED from the prior plan:**
  CP0 Cause/EPC + I_MASK[10] are NOT needed (I_MASK[10]=1 already; the exception/dispatch/predicate all
  provably ran).

## 7. CERTAINTY
HIGH: all raw signals; drain-ISR gets 0 samples; `0x803c7bf0` is a no-hardware predicate that returns
not-mine; atapi.v exoneration; candidate (c) survives / (a),(b) refuted; the 8192 IRQ-clears-without-drain.
MED: the *reason* the predicate declines (never-armed vs armed-late race) — inferred from disasm + the clear
pending bit, not directly observed (`@0x803cf4fc` runtime contents are in neither capture).

## 8. ARTIFACTS
- Capture-X: `local/signaltap/20260630_223849/` (rbf `cd46fd77`, branch `dbg-signaltap-atapi-wedge`@`487f488`).
- Probe: `tools/signaltap_573/atapi_irq_capx_stp.tcl` (dbg branch). Decoders: `scratchpad/decode_capx.py`.
- Verify workflow: `w6ych2a91`. BIOS RAM image: `local/tracedig/573bios.bin` (capstone; off = addr−0x80000000).
- Key addrs: predicate `0x803c7bf0`, descriptor `@0x803cf4fc` (ptr `[0x803d0000-0xb04]`), drain-ISR
  `0x803cb2dc`, exception vector `0x80000080`, BIOS dispatcher `0x80000c80`, RFE loop `0x80001bb8-c30`.
