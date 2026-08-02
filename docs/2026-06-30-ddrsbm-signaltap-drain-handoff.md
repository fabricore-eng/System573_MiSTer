# ★ SESSION HANDOFF — ddrsbm BOOT CHECK: drain-anchored SignalTap building; decode picks the fix (2026-06-30)

Read this FIRST to resume. Full detailed record: `docs/2026-06-30-ddrsbm-bootcheck-tracedig.md`
(§1-14). Memory: `[[fabricore-573-digital-bringup]]`. This handoff is the resume-critical subset +
the exact next steps.

---

## 1. ONE-LINE STATE
The ddrsbm BOOT CHECK bug is pinned (via trace-dig + sim + on-silicon SignalTap, all adversarially
verified) to **the ATAPI data-in transfer never completing** — `ridx` never reaches `resp_len`, so
the data-driven completion INTRQ never fires and the driver's completion-wait spins → BOOT CHECK.
The remaining question is **over- vs under-count of `data_consume`** in `atapi.v`. A **drain-anchored
SignalTap build is RUNNING on dell** to answer it definitively; when it lands, deploy + capture +
decode (§5) picks the exact `atapi.v` fix.

---

## 2. WHERE WE ARE RIGHT NOW (the build in flight)
- **Build RUNNING on dell** (launched ~2026-07-01T01:5x UTC): branch **`dbg-signaltap-atapi-wedge`**
  HEAD **`442b407`** (drain probe v2, SLD-expanded). Instrumented (~35 min). Watch:
  `~/Dev/fabricore/tools/tools/dell_build.sh --status`; log `dell:/tmp/dellbuild-573.log`; cockpit
  `http://localhost:8573`. A completion watcher was armed (`build_watch.sh`, background) — but if this
  is a NEW session, just poll `--status` / grep the log for `== dell build DONE ... rc=0 ==`.
- **When it finishes (rc=0):** do §5 (verify probe inserted → deploy de-confounded → capture → decode).

---

## 3. THE PROBLEM
ddrsbm (DDR Solo Bass Mix, digital-I/O-board DDR) freezes at a **BOOT CHECK** screen (white text
top-left on black; VALID evidence, not a black frame — `local/ddrsbm_de10_bootcheck_a5823f7.png`) —
the CD/ATAPI drive check in its POST. MAME with the SAME data completes the drive check in ~2 frames
(Gate −1 satisfied — it's RTL/timing, not data).

---

## 4. WHAT'S BEEN RULED OUT (verified — do NOT re-litigate)
Each ruled out with evidence (details in the finding doc §1-14):
- **NOT a driver state-race** (trace-dig §5-8, 6-agent unanimous): every drive-check command sets its
  transfer-pending byte / snapshots the IRQ counter BEFORE the IRQ-trigger write. The committed
  `IDENT_SETTLE=2048`/`S_PREP` fix (`a5823f7` on `feat-digital-bringup`) targets a non-existent race →
  **confirmed dead, benign, deprioritize** (leave in place; don't tune).
- **NOT a dropped edge / ce-gating** (SignalTap §13): `ce`=1.000, exactly 1 `irq_out` edge → 1
  `I_STATUS[10]` latch. (My diagnostic-A ce-gating lead was refuted on silicon.)
- **NOT a rogue/other IRQ storm** (§13): only `I_STATUS` bit 10 (ATAPI) ever sets.
- **NOT an IRQ10/LIGHTPEN routing mismatch, NOT a kernel dispatch failure** (§13, adversarially
  corrected): the IRQ is delivered+latched fine; the game ISR (`0x803cb2dc`) DOES run (in the other
  captures). My "CPU trapped in kernel, ISR never dispatches" read was REFUTED — that was a
  phase-of-hang snapshot.
- **MAME/data is fine** (Gate −1): MAME drains via PIO and completes.

## 4b. THE VERIFIED INVARIANT (the actual bug)
Across ALL captures: the ATAPI data-in block **never fully drains** (`ridx` stalls: 0 in one
capture, 102 of 256 in another), `irq_out` is **never cleared by a reg7 read**, so the **DATA-DRIVEN
completion INTRQ** (`atapi.v` ~line 540-559, fires only when the host consumes the LAST word,
`ridx+2>=resp_len`) is **never generated** → the ISR's counter (`0x803d2280`) never gets its final
bump → the foreground completion-wait `0x803cb4b8` spins forever → BOOT CHECK.

**Suspect (drain-analysis §14, task `wr330sru6`):** `atapi.v` `data_consume` is a **free-running
LEVEL term** — `pio_data_rd = sel && re && addr==4'd0` (atapi.v:289-290), no `re` rising-edge
qualifier, no `ce` gate — while the real bus strobe (`exp1_re`→`bus_exp1_read`) is a LEVEL held in the
ce-gated memorymux `EXT_READ_NEXT` FSM. So one CPU `lhu` from reg0 can register as the WRONG number
of `data_consume` events → `ridx` desyncs from the driver's fixed 256-word read → completion never
lines up. The tbs (`tb_drivecheck`, `tb_atapi_cdread`) pulse `re` once/read (1 read=1 consume), so
they PASS and never expose it — the sim/silicon gap.

**OPEN: over- vs under-count is UNRESOLVED** and it picks the fix:
- Analysts leaned OVER-count (16-bit `lhu` at EXP1 width=0 = two `EXT_READ_NEXT` beats; or a ce-stall
  level-hold = N consumes/read). Fix = **edge-qualify** `data_consume` (see §6).
- But the evidence (DRQ **held**, `ridx` **low** 0/102, state **stays** S_DATAIN) fits UNDER-count /
  missed-read better (an over-count would hit `resp_len` EARLY, fire completion, and LEAVE S_DATAIN —
  which we do NOT see). Under-count fix is different (widen/synchronize the read strobe into the atapi
  clk domain, or a proper consume handshake).
- The current captures carry NO `data_consume`/`re`/reg7 strobe, so they can't tell. **That is exactly
  what the running build adds.**

---

## 5. RESUME STEPS when the build lands (the whole point)
**(a) Verify the probe inserted (hollow-build gate, no deploy needed):** on dell
`~/System573_MiSTer/output_files/`:
```
grep -c CONNECT_TO_SLD ...map/fit; grep -i "signal tap" Konami_System_573.map.rpt | grep -iE "warn|cannot|not found|ignored"   # must be NONE
grep -i "auto_signaltap_0" Konami_System_573.fit.rpt | head    # must EXIST
```
Confirm the `dbg_*` nodes resolved (dbg_sel/dbg_re/dbg_we/dbg_addr/dbg_pio_rd/dbg_consume + state).
Get the rbf md5.

**(b) Deploy de-confounded to de10** (recipe proven this session):
```
scp dell:System573_MiSTer/output_files/Konami_System_573.rbf <mac>; scp <mac> de10:/media/fat/_Console/Konami_System_573.rbf   # verify md5
dell_coord.sh devlock de10 acquire 573
dell_coord.sh devlock de10 reboot 573        # board drops ~90s, WIPES the on-board devlock
# wait for de10 back; re-acquire devlock; then ONE load_core WHILE uptime<60s (target; ~77s was OK — only load this boot):
ssh de10 "echo 'load_core /media/fat/_Console/DDR Solo Bass Mix (573).mgl' > /dev/MiSTer_cmd"
```
Heisenbug-gate: `grab_card.sh de10` + LOOK — must still show BOOT CHECK.
**GOTCHA (learned):** the drive check runs ~20-40s AFTER load_core and then goes STATIC (no ATAPI
activity in the parked BOOT CHECK state). So **arm the capture IMMEDIATELY after load_core** to catch
it live — a parked-state capture times out. (See `scratchpad/live_capture.sh` pattern this session.)

**(c) Capture:** `tools/signaltap_573/capture_atapi.sh 150` (uses the drain `atapi_irq.stp` on dell,
signal-set `ss_atapi_irq`, trigger `trig_atapi_irq` = `dbg_re high & dbg_addr==0` = a reg0 DATA read
in progress). If it TIMES OUT (no reg0 read → extreme under-count / drain never issues reads), that is
itself a finding; retune the trigger (regenerate the .stp, NO rebuild — same node set = CRC-compatible):
`RECON`-style to `state==S_DATAIN` or `r_status[3]` (DRQ) high, re-stage on dell, re-arm.

**(d) Decode → the answer.** Adapt `local/tracedig/decode_wedge.py`/`ts_wedge.py` to the drain columns
(`dbg_sel,dbg_re,dbg_we,dbg_addr[0..3],dbg_pio_rd,dbg_consume,state[0..2],ridx[0..12],r_status,r_bclo,
r_bchi,irq_out,irq_pending,I_STATUS[10],I_MASK[10],ce`). Compute:
- **Per reg0 read (`dbg_re` high & `dbg_addr`==0), how many `dbg_consume` pulses fire, and by how much
  does `ridx` advance?** `>1 consume`/`ridx+=4` per read → **OVER-count**. `0 consume`/`ridx` doesn't
  advance despite the read → **UNDER-count / missed read**.
- Does the reg7 read (`dbg_re` high & `dbg_addr`==7) ever fire (the INTRQ ack)? Does `irq_out` clear
  after it?
- Correlate with `ce` (does a ce=0 window coincide with a miscount?) and `state`.
→ **This picks the fix (§6).**

---

## 6. THE FIX CANDIDATES (capture decides which)
- **If OVER-count** (the analysts' lead): edge-qualify `data_consume` in `rtl/atapi.v` (~3 lines) —
  `reg re_q; re_q <= sel && re && (addr==4'd0);` in the clocked block; `wire pio_data_rd = sel && re
  && (addr==4'd0) && !re_q;`. Collapses a multi-cycle/multi-beat held strobe to one consume per read.
  (Note: only collapses a CONTINUOUS hold; two SEPARATE re pulses per lhu would still double — the
  capture shows which.) Leaves both tbs green; add a `exp1_read_twobeat`/`_cestall` tb task to
  reproduce+prove offline.
- **If UNDER-count / missed read**: the read strobe isn't being sampled by atapi — widen/synchronize
  `re` into the atapi clk domain, or add a consume handshake so every host read advances `ridx` once.
- Apply the chosen fix on `feat-digital-bringup` (`rtl/atapi.v`, a normal edit — NOT a psx_patch),
  RED/GREEN it in `sim/` (extend `tb_drivecheck`), then ONE clean build → de-confounded de10
  BOOT-CHECK gate. Do NOT touch `IDENT_SETTLE` (dead).
- **LATENT (lower priority for THIS gate but real):** `dma_req` is gated `datain_disc && cd_attached`
  only (atapi.v ~528), so a non-disc data-in command drained via ch5 DMA gets no data — the drive
  check uses PIO so it dodges this, but fix when convenient.

---

## 7. STATE OF THE WORLD
- **Git — `feat-digital-bringup`** (main WIP, trunk-bound): HEAD **`621c36f`** = finding doc §14. Chain:
  621c36f(§14) → 6996f02(§13 SignalTap) → e60021e(§12 diag-A) → 2a76ebe(§1-11 trace-dig) → 3a5d1bc
  (handoff) → a5823f7 (THE dead IDENT_SETTLE fix) → … . In sync with `origin` (private). The
  `IDENT_SETTLE` fix is in `rtl/atapi.v` here (benign).
- **Git — `dbg-signaltap-atapi-wedge`** (⚠️ DEBUG, NEVER MERGE): HEAD **`442b407`** = drain probe v2
  SLD-expanded (building). Carries the SignalTap tooling (`tools/signaltap_573/`), the drain probe
  (`atapi_irq_drain_stp.tcl` → `atapi_irq.stp` + `.qsf.snippet`), the `dbg_*` register block in
  `rtl/atapi.v`, and the SLD-expanded `Konami_System_573.qsf`. Prior probe on it: `531302b` (wedge
  94-bit, rbf `bf341bc4`, captured 20260630_183607).
- **Git — `dbg-signaltap-atapi-irq`** (older): source of the decoders (`read_atapi_pc.py`,
  `read_atapi_csv.py`, `read_stp_csv.py`) — already copied to `local/tracedig/`.
- **dell:** `~/System573_MiSTer` on `442b407` (building). origin=private (SSH deploy key
  `~/.ssh/id_573deploy`). After the build: rbf at `output_files/Konami_System_573.rbf`. **Clean the
  working tree (`git reset --hard`) before any launcher checkout** (the launcher aborts on a dirty QSF
  — bit us twice this session; the `quartus_stp --enable` leaves the QSF dirty).
- **de10:** devlock **FREE**. ddrsbm staged: `/media/fat/games/System573/ddrsbm.{chd,u1,u6}` +
  `573bios.bin`; `.mgl` = `/media/fat/_Console/DDR Solo Bass Mix (573).mgl`. Currently running the
  WEDGE instrumented core (`bf341bc4`) parked at BOOT CHECK — redeploy the new drain rbf.
- **Capture:** `tools/grab_card.sh de10` → `/tmp/mister-testdata/card_de10.png` (live HDMI). SignalTap
  capture via `tools/signaltap_573/capture_atapi.sh` (passive JTAG on dell's USB-Blaster; reads the
  `atapi_irq.stp` from dell's checkout — so dell must be on `442b407` at capture time).

---

## 8. KEY ARTIFACTS & PATHS
- Finding doc (full record): `docs/2026-06-30-ddrsbm-bootcheck-tracedig.md` (§1-3 trace-dig root; §12
  diag-A sim; §13 SignalTap; §14 drain analysis).
- Disasm (base 0x803c0000): `local/tracedig/ddrsbm_full_code.asm`. Key PCs: IDENTIFY `0x803cb7c4`
  (self-drain loop `0x803cb884`), ISR `0x803cb2dc`, ISR PIO drain `0x803cb284`, completion-wait
  `0x803cb4b8`, IRQ counter `@0x803d2280`, byte-count save `@0x803d228c`, state byte `@0x803d228f`.
- SignalTap: probe generator `tools/signaltap_573/atapi_irq_drain_stp.tcl` (dbg branch); captures under
  `local/signaltap/` (wedge = `20260630_183607`); decoders + `wedge_capture_{decode,timeseries}.txt`
  in `local/tracedig/`.
- MAME trace + timeline: `local/ddrsbm_ata_full.log`, `local/tracedig/MAME_TIMELINE.md`.
- Evidence brief: `local/tracedig/EVIDENCE_BRIEF.md`. Verifier workflow results (task ids): `wool7zgy4`
  (no-race), `wqekudb5o` (SignalTap verify), `wr330sru6` (drain analysis).
- `local/` is gitignored — evidence stays local; only `docs/` + code are committed.

---

## 9. NON-NEGOTIABLES / GOTCHAS
- Build ONLY via `~/Dev/fabricore/tools/tools/dell_build.sh` (`DELL_REPO`=bare `System573_MiSTer`). A
  hook blocks off-protocol builds. **`git reset --hard` dell's tree before launching** (dirty QSF from
  `--enable` aborts the launcher's checkout).
- SignalTap flow: generate `.stp` → append `.qsf.snippet` → `quartus_stp … --enable` ON DELL (writes
  SLD_*) → scp QSF back → commit → build. **KEEP on combinational nets is REJECTED by Quartus 17.0** —
  use PRESERVE_REGISTER on registers only (hence the `dbg_*` register block). Trigger retune = regen
  the `.stp` only (same node set = CRC-compatible, NO rebuild); re-stage on dell.
- De-confound EVERY HW verdict: warm-reboot via `devlock … reboot`, uptime <60s target, ONE
  `load_core`. Arm the SignalTap capture IMMEDIATELY after load_core (drive check is early + goes
  static). Verify with a NUMBER **and LOOK** at the frame.
- Vendored `psx/` stays pristine (patches). The `dbg_*` block + any real fix are in `rtl/` (normal
  edits). Commit as Fabricore, push PRIVATE (`origin`) by default.
- Lock shared HW (de10 devlock) before use; release after.

---

## 10. THE ARC (so the reasoning isn't lost)
trace-dig (disasm) → ruled out the state-race; sim (tb_drivecheck/tb_irqdeliver pass) → ruled out
register + modeled-edge; SignalTap wedge capture → ruled out ce-gating/dropped-edge/rogue-IRQ/routing/
dispatch, CONFIRMED delivery-clean + drain-never-completes; drain analysis → suspect = `data_consume`
level-vs-edge miscount, over/under UNRESOLVED. **This build's capture resolves over/under → the fix.**
Every step was adversarially verified (workflows), which twice CORRECTED an over-read of mine — keep
that discipline: verify the decode before claiming the fix.
