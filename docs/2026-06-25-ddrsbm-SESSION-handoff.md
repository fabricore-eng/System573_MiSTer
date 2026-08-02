# ★ SESSION HANDOFF — ddrsbm BOOT CHECK: root cause FOUND, fix not yet written (2026-06-25)

Read this FIRST to resume. Deep technical proof: `docs/2026-06-25-ddrsbm-identify-irq-race-handoff.md`.
Memory: `[[fabricore-573-digital-bringup]]`. Branch to work on: **`feat-digital-bringup`**.

This session took ddrsbm's "BOOT CHECK" gate from the prior session's WRONG hypothesis ("the ATAPI
completion IRQ is dropped") all the way to the EXACT root cause, verified on silicon with SignalTap.
The fix is designed but **deliberately NOT written** — Human parked it for a live stream.

---

## 1. THE ONE-LINE ROOT CAUSE
`rtl/atapi.v` raises the IDENTIFY (0xA1) **data-ready IRQ instantly on the command write**, so
ddrsbm's interrupt handler runs BEFORE the driver has set its software "transfer-pending" state byte.
The handler sees that byte still 0, takes the skip-to-exit dispatch branch, and **never drains the
512-byte IDENTIFY block** -> DRQ stuck -> drive check times out -> BOOT CHECK. A real CR-589 (and MAME)
delay that interrupt by the drive's data-prep latency, so the driver finishes setup first.

IRQ *delivery* is fully working (latch + I_MASK enable + CPU exception all verified). The bug is a
**timing race**, not a dropped/missed interrupt.

---

## 2. THE FIX TO WRITE (this is the next stream)
**Add a BSY settle before raising DRQ+INTRQ for the fixed-response data-in commands**, mirroring the
`S_FETCH`/`FETCH_SETTLE` pacing that disc READ(10/12) already uses.

Sites in `rtl/atapi.v` that currently fire `r_status<=DRDY|DRQ; irq_pending<=1; irq_event<=1;
state<=S_DATAIN` in the SAME cycle as the command (the race):
- **`8'hA1` IDENTIFY @454-461 (line 460)** — the proven gate; fix this FIRST.
- `8'h12` INQUIRY @329-333, `8'h25` READ CAPACITY @334-339, `8'h03` REQUEST SENSE @340-344,
  `8'h5A` MODE SENSE(10) @357-361, and the READ TOC data phase @567-572 (line 570).
- (Disc READ @386-404 already settles via `S_FETCH`; non-data completions like TEST UNIT READY @323
  don't drain, so leave them instant for now -- but watch whether the completion IRQ races too.)

Template already in the file: `FETCH_SETTLE`/`PACE_CLKS` localparams @88-89, `fetch_wait` counter
@118, `S_FETCH` state @78 used @393/395 + @519. Implementation sketch: on these commands set
`r_status<=ST_BSY` + `fetch_wait<=SETTLE_N` + go to a settle state (generalize `S_FETCH`, or add an
`S_PREP` that, when `fetch_wait` hits 0, raises `DRDY|DRQ` + `irq_pending` + `irq_event` +
`state<=S_DATAIN`). **SETTLE_N tuning:** must be long enough for the driver's "write cmd -> set
state byte -> start waiting" window (a handful of instructions, ~tens of clk1x) but well under the
driver's wait timeout (`0xf690` in the bounded waits 0x803cb010/0x803cb104). Start ~`13'd2048` clk1x
(between FETCH_SETTLE=4 and PACE_CLKS=4096) and tune DOWN if the driver's DRQ-wait times out, UP if
the race persists. Likely 1-2 build iterations to land the value.

Constraint: keep DRQ reachable by polling (status read shows DRQ after the settle) so the polling
games **powyakex / hypbbc2p** still pass -- they never use the IRQ, only poll status with a big timeout.

---

## 3. VERIFY PLAN (objective, per the no-vision rule)
1. **Sim first** (fast, before the 45-min build): `make -C sim` runs the suite (`tb_atapi`,
   `tb_drivecheck`, `tb_atapi_cdread`, `tb_irqdeliver`, `tb_system573_top`). Add/extend a TB that
   issues IDENTIFY and asserts the IRQ fires AFTER a settle (not on the command write) AND the data
   still drains. RED->GREEN it.
2. **Build** via the hub launcher ONLY (this lands a clean NON-instrumented `feat-digital-bringup`
   rbf that also REPLACES the v2 debug rbf currently on the de10):
   `DELL_PROJECT=573 DELL_TARGET=Konami_System_573 DELL_REPO=System573_MiSTer ~/Dev/fabricore/tools/tools/dell_build.sh feat-digital-bringup`  (~45 min; monitor /tmp/dellbuild-573.log).
3. **Deploy + de-confounded de10 test:** fetch rbf -> `scp` to `de10:/media/fat/_Console/Konami_System_573.rbf`; `devlock de10 acquire 573`; `devlock de10 reboot 573`; wait uptime<60s; re-acquire devlock; ONE `load_core` of `/media/fat/_Console/DDR Solo Bass Mix (573).mgl`.
4. **Objective verdict:** capture the screen (`~/Dev/fabricore/tools/tools/grab_card.sh de10`; SIGTERM the av_publish de10 child first so the capture re-syncs past the warm-reboot HDMI standby), then `frame_diff` vs the MAME oracle `local/mame_ddrsbm.png` ("INITIALIZE FLASH-ROM"). PASS = ddrsbm advanced PAST BOOT CHECK. Also regress powyakex + hypbbc2p drive checks (still boot).
5. If it advances: the next ddrsbm gate is the FLASH-ROM init / the digital-board (DIO/MP3) layer.

---

## 4. STATE OF THE WORLD (what's where)
- **Git (all pushed to origin = fabricore-eng public):**
  - `feat-digital-bringup` @ **3b0fc41** -- the work branch. Has both 2026-06-25 handoff docs + the
    earlier 76f0274 IDENTIFY-content fix (kept, correct-but-not-the-gate). **Work here.**
  - `dbg-signaltap-atapi-irq` @ **44ef6c0** -- ALL the SignalTap probe work (generators, qsf SLD
    expansions, decoders). NEVER merge; it carries ENABLE_SIGNALTAP. Reuse for re-probing.
  - Untracked (intentional, not committed): `de10` (scratch), `tools/trace/ddrsbm_ata_full.lua`
    (MAME ATA tap), `tools/wf_cockpit_progress.sh` (hub tool copy).
- **de10 board:** currently running the **v2 instrumented debug rbf** (md5 `4b4c8583`), NOT a
  production core -- the step-2 build replaces it. ddrsbm game data staged at
  `de10:/media/fat/games/System573/ddrsbm.{u1,u6,chd}` + `573bios.bin`.
- **Probe tooling** (`tools/signaltap_573/`, on the dbg branch): `atapi_irq_stp.tcl` (v1, 66-bit IRQ
  chain) + `atapi_irq2_stp.tcl` (v2, 82-bit: adds `cpu:icpu|PC[31:0]` + atapi `ridx` + byte count);
  `capture_atapi.sh` (arm via dell JTAG -> CSV); decoders `read_atapi_csv.py` (a/b/c IRQ verdict) +
  `read_atapi_pc.py` (PC region histogram + drain check). RECON modes retune the trigger with NO
  rebuild (all nodes are trigger inputs). RUNBOOK: `tools/signaltap_573/RUNBOOK.md`. Net-name gotchas:
  `state[2:0]` ties to GND (FSM re-encode -> PRESERVE ignored, Warning 12069, benign); `PC[31:0]`
  preserves clean. Build was ~1h38m at 99% LAB (PC tap) -- still under the 2.5h kill threshold.
- **Captures** (`local/signaltap/`): `175832` (v1 RECON=any center -- IRQ chain works), `180648` (v1
  pre-pos -- the ~96us service + DRQ-never-completes), `195945` (v2 PC trace -- byte count 0x0200 =
  IDENTIFY, ridx=0), `201105` (v2 RECON=pc handler-entry -- the skip-to-exit proof). `175249` = a
  no-trigger run (armed too late), kept for the record.
- **MAME oracle on dell:** `cd ~/System573_MiSTer; mame ddrsbm -rompath 'dumps/mame573;dumps' -video
  none -sound none -nothrottle -seconds_to_run N -autoboot_script /tmp/x.lua`. The handler-trace lua
  + the IDENTIFY/DMA tap are at `/tmp/ddrsbm_*.lua` on dell. MAME drains this data via PIO (1193 reg0
  reads, 0 ch5-DMA arms) -- confirms ddrsbm PIO-reads the IDENTIFY.

---

## 5. SESSION CLEANUP DONE (so you start clean)
- de10 devlock **released**; chat **disconnected** (`/fabricore:group-chat off`, watcher killed,
  watchdog cron deleted -- re-arm with `/fabricore:group-chat on` if you want chat back).
- Status card set to: "ROOT CAUSE FOUND ... fix parked for next stream."
- No build running. Working tree clean (only the 3 untracked scratch files above).
- Posted the cross-core finding to dvd (573's symptom is NOT the f2sdram bridge -- it's the IRQ race).

---

## 6. LATENT / DON'T-LOSE
- **LATENT bug (real, not ddrsbm's gate):** atapi.v's DMA drain is disc-only -- `data_consume = ... ||
  (dma_rd && datain_disc)` @278 and `dma_dout` @630 serve only disc data. A game that DMAs a non-disc
  data-in command (IDENTIFY/INQUIRY/TOC) would get no drain + wrong data. ddrsbm uses PIO so it dodges
  this; fix it when convenient (extend the DMA path + dma_req to datain_ident/datain_toc/resp_byte).
- Keep commit 76f0274 (exact CR-589 IDENTIFY content) -- correct, just not the gate.
- The "IRQ is dropped/not-latched/not-taken" framing in the OLD handoff (2026-06-24) is DISPROVEN.
- powyakex still parked (its ~10h "HARDWARE ERROR" is a CD/data-loader timeout) -- re-check after this
  fix only if it shares the ATAPI data path; see `[[powyakex-baseball-flash-stall]]`.

---

## 7. NON-NEGOTIABLES (don't relearn the hard way)
- Build ONLY via `~/Dev/fabricore/tools/tools/dell_build.sh` (DELL_REPO = bare `System573_MiSTer`).
- Verify with a NUMBER (frame_diff / state byte / sim), never a screenshot read.
- De-confound EVERY HW verdict: warm-reboot via `devlock de10 reboot 573`, uptime<60s, ONE load_core.
- Vendored `psx/` stays pristine -- any PSX edit is a numbered `psx_patches/NNNN-*.patch`. (The atapi.v
  fix is in `rtl/`, NOT psx/, so it's a normal edit.)
- Commit as Fabricore; push as fabricore-eng; end commit msgs with the Claude co-author trailer.
