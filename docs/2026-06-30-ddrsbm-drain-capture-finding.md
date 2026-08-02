# ★ FINDING — ddrsbm BOOT CHECK: the IDENTIFY (0xA1) data-in block NEVER DRAINS (no-drain, not a consume miscount)

Verdict from the drain-anchored on-silicon SignalTap capture (`local/signaltap/20260630_204524`),
adversarially verified (workflow `w055yphmp`: 3 independent decoders → reconcile → 2 refuters → final;
both refutations collapsed against the RTL). Supersedes the over/under-count framing of
`docs/2026-06-30-ddrsbm-signaltap-drain-handoff.md` §5-6. Full prior record:
`docs/2026-06-30-ddrsbm-bootcheck-tracedig.md`. Memory: `[[fabricore-573-digital-bringup]]`.

---

## 1. ONE-LINE VERDICT
The stuck command is **IDENTIFY PACKET DEVICE (0xA1)**. The device correctly reaches **S_DATAIN with
DRQ (r_status=0x48), byte-count 0x0200 (512 B)** and delivers exactly **one clean, latched INTRQ**
(`I_STATUS[10]`) — but **`ridx` stays 0, no reg0 read / `data_consume` ever advances the drain**, so the
data-driven completion INTRQ (needs `ridx→510`) never fires → the foreground completion-wait spins →
BOOT CHECK. The fault is **host/handshake-side "no-drain," NOT `atapi.v` consume arithmetic.** The
over-vs-under-count question is **moot for this window** (zero consumes to miscount) and the evidence
**directionally contradicts over-count**.

## 2. THE CAPTURE (de-confounded, clean, Heisenbug-gated)
- Branch `dbg-signaltap-atapi-wedge` @ `442b407`, rbf `112bc47d…` (rc=0; probe verified inserted:
  142 CONNECT_TO_SLD, `sld_signaltap:auto_signaltap_0` in the fit, 0 SignalTap warnings — not hollow).
- de10: warm-reboot via devlock → MENU-ready → **one** `load_core` → **BOOT CHECK confirmed by eye**.
  JTAG clean (**0× Error 12852**), analyzer PRE→DONE (triggered). Trigger = `irq_out` high (RECON=irqout).
- Depth 8192, sample clk = core PLL `outclk_wire[1]`, storage qualifier = `ce==high`. 8193 valid rows.
- Cross-checked against the prior wedge capture `20260630_183607` (4097 rows) — same signature.

## 3. VERIFIED FACTS (agreed to the row across 3 decoders + 2 adversaries; checked vs `rtl/atapi.v`)
- **Stuck command = 0xA1 IDENTIFY.** Byte-count `r_bchi:r_bclo` = `0x02:0x00` = 512, constant every valid
  row in BOTH captures. `r_bchi<=8'h02` is written at **exactly one site** (`atapi.v:468`, the 0xA1
  branch) → a **unique RTL fingerprint**.
- **Parked in S_DATAIN, DRQ live.** `r_status`: `0x80` (BSY) ×1022 rows → single step to `0x48`
  (DRDY|DRQ) at row 1023, held to the end. `0x48` is **not stale**: the only S_DATAIN exit (completion,
  `atapi.v:549-559`) rewrites status to `0x50/0x80/ERR` and **requires `data_consume`** — which never
  fired — so the FSM cannot have left S_DATAIN. `0x50` (DRDY|DSC completion) **never appears**.
- **`ridx` FLAT 0** — min=max=0, **zero change events** across 8193 rows (and 4097 in the other capture).
  This is the load-bearing no-drain fact (`ridx` is a plain counter, reliably tapped every stored row).
- **Zero drain activity:** `dbg_consume`, `dbg_re`, `dbg_sel`, `dbg_pio_rd`, `dbg_addr` all idle the whole
  window.
- **IRQ path clean (§13 CONFIRMED):** `ce`=1 every row, `I_MASK[10]`=1. Exactly **1** `irq_out` 0→1
  (row 1025) → **1** `I_STATUS[10]` latch (row 1027). Only `I_STATUS` bit10 ever sets (no rogue IRQ).
  Ordered deassert: `I_STATUS[10]`↓7543, `irq_pending`↓7687, `irq_out`↓7689.
- **`state[0..2]` column is DEAD — ignore it.** Quartus extracted/re-encoded the atapi `state` machine
  (map.rpt item 14); the tapped `state~8/9/10`, `state.S_IDLE` nets are **"Lost fanout"** → the column
  reads constant 0 (decodes to a bogus "S_IDLE" while `r_status=0x48` proves S_DATAIN). FSM phase is
  inferred from `r_status`, not `state[]`.

## 4. WHY THE NO-DRAIN CONCLUSION IS TRUSTWORTHY (not a `ce`-aliasing artifact)
- The `ce==high` storage qualifier **can** alias single-cycle strobes (proven: `irq_pending` clears at
  row 7687 with `dbg_sel`=0 everywhere, yet RTL requires a `sel`-asserting reg7 read to clear it).
- **But the drain path is `ce`-gated by construction**, so it cannot hide in dropped `ce`-low samples:
  atapi's read strobe `re ← atapi_sel & exp1_re`, `bus_exp1_read ← ext_state==EXT_READ_NEXT`, and
  `ext_state` in `psx/rtl/memorymux.vhd` (l.1033-1043,1189-1190) transitions **only under `ce='1'`**.
  For IDENTIFY `datain_disc=0`, so `pio_data_rd` is the **only** live `data_consume` term
  (`atapi.v:290`) — any reg0 read is by construction a `ce=1` event → retained.
- **`ridx` is immune regardless:** it is tapped on every stored row; even a `ce`-low consume would show
  as a `ridx` step on the next stored row. `ridx` is flat 0 in two independent captures. → **no-drain
  holds.** (Precise phrasing: *"no reg0 read reached atapi's consume path in a way that advanced `ridx`,
  within the captured epoch."*)

## 5. OVER vs UNDER — MOOT, AND OVER-COUNT DIRECTIONALLY CONTRADICTED
The §14 "over/under-count of `data_consume`" question presupposes consume events to miscount. There are
**zero** (and `ridx`=0). You cannot mis-count zero events — the capture answers the strictly prior
question ("does the drain begin at all?" → **no**). Further, an **over-count** (free-running level term)
would drive `ridx` to `resp_len` early, fire completion, and **leave** S_DATAIN (DRQ→0x50). We observe
the **opposite** — DRQ held at 0x48, `ridx` pinned at 0. That is a no-drain signature, not a miscount.

## 6. ROOT CAUSE + THREE LIVE CANDIDATES (deeper mechanism NOT separable from this capture)
Device side (HIGH confidence): no reg0 read advances the drain → `data_consume` never fires → `ridx`
stays 0 → completion INTRQ never generates → completion-wait spins → BOOT CHECK.
Host/handshake mechanism (MEDIUM — the tap can't separate these three; the next capture must):
- **(a)** the driver's IDENTIFY foreground drain loop never issues its reg0 reads (ISR skip-to-exit /
  wrong drain path). *(Note: the wedge capture's PC hits show driver high-region code executing —
  `0x803c7eb0/ec0`, `0x803cb530/594` — yet `ridx` never moves.)*
- **(b)** the driver drains via **ch5 DMA**, but `dma_req = state==S_DATAIN && datain_disc && cd_attached`
  (`atapi.v:679`) is gated **OFF** for IDENTIFY (`datain_disc=0`) → no data — the **§13 LATENT** suspect.
- **(c)** reads are issued but never assert `sel` to atapi's decode (wrong address decode / memorymux mux
  never routes EXT_READ to atapi).

## 7. FIX GUIDANCE — NO CODE FIX SELECTED YET (next step is a build-gate)
Committing an `atapi.v` change now would be a guess among (a)/(b)/(c). The evidence does say:
- ❌ **Do NOT ship the §14 edge-qualify-`data_consume` fix** — it targets an over-count this capture
  directionally contradicts. **§14 (over-count prime suspect) is DEMOTED.**
- ❌ **Do NOT re-tune `IDENT_SETTLE`** — CONFIRMED dead: the settle ran (BSY→0x48 after the hold) and the
  block still never drained. (Leave `a5823f7` in place; it is inert.)
- ⚠️ The one `atapi.v` lead with independent RTL rationale is the §13 LATENT `dma_req` gate
  (`atapi.v:679-680`, `datain_disc && cd_attached`) — widen the DMA data path to serve
  `datain_ident`/`datain_toc`, OR confirm the driver never takes the DMA path for IDENTIFY. **Must be
  confirmed by the next capture before building** (this window shows no PIO reads either, so a DMA-only
  fix might miss the real cause).

## 8. NEXT CAPTURE ("capture X") — REQUIRES A FULL REBUILD (the pending build-gate)
The needed nets are NOT in the current 54-signal tap → this is a new probe + full build, not a .stp regen.
- **Trigger:** on **S_DATAIN entry** (`r_status` write to 0x48 / a reliable state net) — anchor on the
  event the drain should *follow*, not on `irq_out`.
- **Storage qualifier: OFF** — record every clk2x cycle (ce and non-ce) so single-cycle `sel` strobes and
  ce-low stalls cannot be aliased out (closes the one proven aliasing hole).
- **Add nets one level UP from atapi:** memorymux `EXT_READ`/`exp1_re`/`atapi_sel` decode; the reg7-ack
  strobe (`sel && re && addr==7`); `dma_rd`/`dma_req`/`ext_byteStep`; **CPU PC** (does the foreground
  drain loop / ISR PIO path execute its reads?). Keep `ridx`, `r_status`, `ce`, `dbg_*` as invariants.
- **Window:** rolling/segmented, long enough to span the full ~256-read drain + completion.
- **Resolves in one shot:** (1) are reg0 reads issued? (2) do they reach atapi `sel`? (3) if so, does each
  `lhu` yield 1 vs 2+ consumes — **finally making over/under answerable** IF a drain exists; (4) DMA path?

## 9. CONTRADICTIONS WITH THE RULED-OUT LIST
- **§14 over-count** → **DEMOTED** (directionally contradicted; do not ship the edge-qualify fix on this
  evidence — not disproven as a *latent* issue elsewhere, only shown not to be the mechanism firing here).
- **§12 ce-gating / dropped-edge** → stays **CLOSED** (ce=1 whole window, 1 edge→1 latch).
- **§13 IRQ delivery/latch clean** → **RE-CONFIRMED** (both captures).
- **IDENT_SETTLE fix** → **CONFIRMED dead**.
- Honest residual: candidate (c) "reads never assert atapi `sel`" is alive and is exactly what the next
  capture's upstream memorymux probes settle. A wholly *prior* IDENTIFY cycle before the window is the
  only coverage gap the data can't close — but it can't be a successful drain of *this* block (window
  opens on a fresh undrained block ridx=0/0x0200 and closes still parked at 0x48/ridx=0, `0x50` never).

## 10. ARTIFACTS
- Capture: `local/signaltap/20260630_204524/atapi_irq_20260630_204524.csv` (+ prior wedge `…_183607`).
- Decoders: `scratchpad/decode_drain2.py` (name-mapped, authoritative), `decode_drain.py`.
- Probe generator (dbg branch, dell): `tools/signaltap_573/atapi_irq_drain_stp.tcl` (RECON=irqout used;
  the `.stp` on dell = the irqout trigger, backup `atapi_irq.stp.reg0bak` = the reg0-read trigger).
- Verification workflow: task `w055yphmp` (full transcript in the session subagents dir).
- RTL load-bearing lines: `rtl/atapi.v` 289-290, 466-490, 534-561, 644-652, 679-680; `psx/rtl/memorymux.vhd`
  1033-1043, 1189-1190.
- Re-encoded/dead `state` tap evidence: dell `output_files/Konami_System_573.map.rpt` (state machine
  item 14; `state~8/9/10`, `state.S_IDLE` "Lost fanout").
