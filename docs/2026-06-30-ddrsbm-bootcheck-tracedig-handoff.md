# ★ SESSION HANDOFF — ddrsbm BOOT CHECK: 2048-cycle settle BUILT+TESTED on silicon, did NOT clear it; trace-dig planned (2026-06-30)

Read this FIRST to resume. Prior deep root-cause proof: `docs/2026-06-25-ddrsbm-identify-irq-race-handoff.md`.
Memory: `[[fabricore-573-digital-bringup]]`. Branch: **`feat-digital-bringup`**.

---

## 1. ONE-LINE STATE
The IDENTIFY-IRQ-race fix (a BSY settle, `IDENT_SETTLE=2048` cycles) is **written, sim-proven
(RED/GREEN), committed, built on dell, and deployed de-confounded to de10 — and ddrsbm STILL
parks at BOOT CHECK** (objectively captured). Next step is a **free, no-build trace-dig** (plan
in §5) to decide whether the settle is too short (H1) or a later command races (H2), and to pin
the correct settle value — BEFORE spending another build. **The plan is APPROVED; the user will
say "start" — then execute §5 top to bottom.**

---

## 2. THE PROBLEM (root cause, proven on silicon last session via SignalTap)
ddrsbm (DDR Solo Bass Mix), a digital-I/O-board DDR game, freezes at a **BOOT CHECK** screen —
the CD/ATAPI drive check in its power-on POST. `rtl/atapi.v` raised IDENTIFY's (0xA1) data-ready
IRQ **in the same cycle as the command write**. The driver's sequence is: write cmd → set a
software *transfer-pending* state byte → wait for the IRQ. Firing instantly means the ISR runs
**before** the state byte is set, sees it 0, takes the skip-to-exit branch, and **never drains
the 512-byte IDENTIFY block** → DRQ stuck → drive check times out → BOOT CHECK. It is a **timing
race**, not bad data or a dropped IRQ (delivery verified working). A real CR-589 (and MAME) delay
this IRQ by the drive's data-prep latency, so the real driver finishes setup first.

---

## 3. WHAT THIS SESSION DID
- **Wrote the fix** (`rtl/atapi.v`, commit `a5823f7`): new state `S_PREP` (3'd6) + localparam
  `IDENT_SETTLE = 13'd2048`. IDENTIFY now sets `r_status<=ST_BSY; fetch_wait<=IDENT_SETTLE;
  state<=S_PREP`, and S_PREP holds BSY for the settle then raises `DRDY|DRQ + IR_IO + irq_pending
  + irq_event` and goes to S_DATAIN. The OLD instant-IRQ path is preserved behind
  `` `ifdef ATAPI_IDENT_NOSETTLE `` as the RED reference (never synthesised). Mirrors the disc-read
  S_FETCH pacing. Scope = **IDENTIFY-only** (the other fixed-response cmds + completion still fire
  instantly, by design — they're on the already-working CD-init path).
- **Sim RED/GREEN proven:** new `sim/tb_atapi_settle.v` asserts the IRQ fires AFTER the settle
  (not on the cmd-write cycle) AND the 512-byte block still drains + completes. GREEN by default,
  RED with `make ATAPI_IDENT_NOSETTLE=1 atapi_settle` (Makefile knob added, same pattern as
  `S573_CH4_NOARB`). Updated `tb_atapi`/`tb_drivecheck`/`tb_cdboot`/`tb_irqdeliver` to poll
  BSY-clear / wait the IRQ on IDENTIFY. **Full suite green** except a **pre-existing, unrelated**
  failure `s573_io` (confirmed fails identically on a clean tree; depends only on `s573_io.v`,
  untouched).
- **Committed + pushed PRIVATE:** `a5823f7` on `feat-digital-bringup` (+ a later docs commit
  `7e29d0b` on top = current HEAD; the fix tree is intact in HEAD). Authored as Fabricore, Claude
  co-author trailer. Pushed to `origin` = `fabricore-eng/System573_MiSTer-private`.
- **Rewired dell to PRIVATE (was the silent confound):** dell's 573 checkout `origin` pointed at
  the **public** repo at a STALE `a2b0aa6` — a build then would have silently lacked the fix.
  Fixed by: generating a read-only SSH deploy key on dell (`~/.ssh/id_573deploy`), setting the
  573 repo's `core.sshCommand` to use it, repointing `origin` to
  `git@github.com:fabricore-eng/System573_MiSTer-private.git`, and adding the **public** key to
  the private repo as a **read-only deploy key** "core-573-deploy-readonly" (id 155700322) via
  `gh` from the Mac. Verified dell fetches `a5823f7`. Also `git stash`ed dell's local uncommitted
  edit to `tools/signaltap_573/atapi_irq.stp` (stash msg "dell-local stp before 573 feat build
  switch (2026-06-27)", on branch `dbg-signaltap-atapi-irq`) — it had blocked the branch switch.
- **Built** (hub launcher, `a5823f7`): `rc=0`, Quartus full compile 0 errors, ~33 min, 0 timing
  errors. rbf md5 **`05344ad0e92d678a27d884f9029b0263`**, 4,151,428 bytes. Clean NON-instrumented
  core (no ENABLE_SIGNALTAP).
- **Deployed de-confounded to de10:** scp'd rbf to `de10:/media/fat/_Console/Konami_System_573.rbf`
  (md5 verified `05344ad0`). Warm reboot via `devlock de10 reboot 573`, board down in ~2s, fresh
  boot uptime 19s, re-acquired devlock, **exactly ONE** `load_core` of the ddrsbm `.mgl` at
  uptime 24s. (Script: was `scratchpad/deconfound_load.sh`, ephemeral.)
- **RESULT = STILL BOOT CHECK (objective):** capture shows "BOOT CHECK" white text, top-left, on
  black — preserved at **`local/ddrsbm_de10_bootcheck_a5823f7.png`** (md5 08d258f5). `frame_diff`
  vs the FLASH-ROM oracle `local/mame_ddrsbm.png` = **MISMATCH** (SSIM 0.94, correct — different
  screen). The fix did not clear the gate.

⚠️ **Lesson banked** ([[look-before-calling-black]]): I first misread the dark capture as
"black/invalid" from mean-luma 0.31 alone. The user looked and saw the "BOOT CHECK" text. The
de10 HDMI capture works fine (`grab_card.sh de10`); a mostly-black POST screen with corner text
is VALID evidence. Numbers + vision are complementary — LOOK before calling a frame black.

---

## 4. CURRENT DIAGNOSIS (what we know, before the trace-dig)
- **RULED OUT "settle too long":** 2048 cycles is ~3% of the driver's own DRQ-wait timeout
  (`0xf690` ≈ 63,120). It cannot have tripped that. **Tuning DOWN is off the table.**
- **Two live hypotheses:**
  - **H1 — settle too SHORT:** the IDENTIFY race still wins. Last session's SignalTap noted a
    **~96µs service window (~3,250 cycles)** — *longer* than the 2,048-cycle (~60µs) settle.
    This actively points at H1.
  - **H2 — a LATER step races:** IDENTIFY now drains, but the **completion IRQ** or one of the
    other fixed-response commands (INQUIRY/REQUEST SENSE/READ CAP/MODE SENSE/READ TOC — all left
    firing instantly) races next → same BOOT CHECK screen, different gate. The prior handoff
    explicitly flagged "watch whether the completion IRQ races too."

---

## 5. THE APPROVED NEXT STEP — TRACE-DIG PLAN (free, NO build). Execute on the user's "start".
**Goal:** pin **W_setup** (cycles from IDENTIFY cmd-write → driver sets the transfer-pending
flag), **T_timeout** (the IDENTIFY wait loop timeout in cycles, decode `0xf690`), **L_mame**
(MAME/CR-589 IDENTIFY data-prep latency) → decide **H1 vs H2** + the right `IDENT_SETTLE` value
and scope. Card stage → `observe`; any multi-minute step gets a live bar+ETA
(`tools/with_progress.sh "<label>" -- <cmd>` + `fab_beat.sh`).

**Inputs (confirmed present):** `local/ddrsbm_ata.txt`, `local/ddrsbm_ata_full.txt`,
`local/ddrsbm_ata_full.log` (88 KB), `local/ddrsbm_code.bin` (64 KB POST code), SignalTap
captures `local/signaltap/20260624_{175249,175832,180648,195945,201105}`, the lua tap
`tools/trace/ddrsbm_ata_full.lua`. Disassembler = **capstone 5.0.7** (MIPS32 little-endian; R3000A).
No cross-objdump installed.
**Prep dependencies:** (a) the BIOS is NOT at `dumps/bios/` locally — pull `573bios.bin` from
`de10:/media/fat/games/System573/573bios.bin` (or the NAS). (b) The SignalTap decoders
`read_atapi_pc.py` / `read_atapi_csv.py` live in `tools/signaltap_573/` on the
`dbg-signaltap-atapi-irq` branch — fetch via `git show dbg-signaltap-atapi-irq:tools/signaltap_573/read_atapi_pc.py`
(do NOT switch branches).

- **Phase 0 — Locate & map the code (~10 min, local):** find the BIOS + ddrsbm_code load address;
  run the PC-histogram decoder on the existing SignalTap captures (esp. `195945`, `201105`) to
  confirm WHICH code (BIOS `0x803cb…` routines vs the game's stricter POST) owns the IDENTIFY
  issue/wait/ISR. Anchors the disassembly target.
- **Phase 1 — Disassemble the driver window (~20 min, capstone):** disassemble around the IDENTIFY
  cmd-write + ISR (known PCs: `0x803cb7c4` IDENTIFY, `0x803cb4b8` wait, `0x803cb010`/`0x803cb104`
  bounded waits). Extract **W_setup**, **T_timeout**, confirm the skip-to-exit branch.
- **Phase 2 — MAME timing reference (~5–15 min):** pull the IDENTIFY (0xA1) timeline from
  `ddrsbm_ata_full.log` → **L_mame**. Only if the log lacks timing granularity, re-run the MAME
  tap on dell (`mame ddrsbm … -autoboot_script` the lua) — **that single step gets a progress
  bar** (`with_progress.sh "mame ddrsbm ata-tap" -- …`). MAME run recipe is in the 2026-06-25 doc.
- **Phase 3 — Decide (~10 min):**
  - `2048 < W_setup` → **H1**: new value = W_setup + margin (< T_timeout); IDENTIFY-only bump
    likely suffices.
  - `2048 ≥ W_setup` yet still hangs → **H2**: broaden the settle to the completion phase + the
    other fixed-response commands.
- **Deliverable:** `docs/2026-06-30-ddrsbm-bootcheck-tracedig.md` with the numbers + H1/H2 verdict
  + recommended value/scope → then ONE informed, targeted build.

(Alternatives the user weighed and deferred: SignalTap re-probe on de10 (~1.5 h instrumented
build) for definitive on-silicon telemetry; a fast reasoned fix-swing (bump+broaden, ~33 min)
without diagnosis. Trace-dig chosen because it's free and resolves H1/H2 first.)

---

## 6. STATE OF THE WORLD
- **Git:** `feat-digital-bringup` HEAD = **`7e29d0b`** (docs) → `a5823f7` (THE FIX) → `32ace1a` …
  In sync with `origin` (private). Working tree: `M CLAUDE.md` (pre-existing, NOT ours), plus
  untracked scratch (`de10`, two `docs/2026-06-27-*.md`, `tools/trace/ddrsbm_ata_full.lua`,
  `tools/wf_cockpit_progress.sh`) and the NEW `local/ddrsbm_de10_bootcheck_a5823f7.png` (evidence)
  + this handoff doc. `dbg-signaltap-atapi-irq` carries the SignalTap probe tooling — NEVER merge.
- **dell:** 573 checkout `origin` = **private** (SSH, deploy key `~/.ssh/id_573deploy`,
  `core.sshCommand` set on the repo). Builds the right ref now. Built rbf at
  `~/System573_MiSTer/output_files/Konami_System_573.rbf` (md5 `05344ad0`). No build running.
- **de10 board:** running the fix core (md5 `05344ad0` = a5823f7), parked at BOOT CHECK. ddrsbm
  data staged at `de10:/media/fat/games/System573/ddrsbm.{chd,u1,u6}` + `573bios.bin`; `.mgl` =
  `/media/fat/_Console/DDR Solo Bass Mix (573).mgl`. **⚠️ The de10 devlock is currently HELD by
  573** (re-acquired during load) — release it (`dell_coord.sh devlock de10 release 573`) if not
  resuming HW work immediately, or re-acquire fresh in the new session.
- **Capture:** WORKS. `tools/grab_card.sh de10` → `/tmp/mister-testdata/card_de10.png` (live HDMI
  via the mediamtx relay on the capture host). Do NOT force-kill the capture host's procs
  (shared; blocked + correct). `frame_diff.py` / `verify_frame.sh` for the verdict.
- **Cockpit card:** the launcher last set it to a "build DONE" line (with a hash). Consider
  resetting to a clean `verify`/`observe` stage at next session start.
- **Chat:** not armed in this session. Arm with `/fabricore:group-chat on` if wanted.

---

## 7. NEW STANDING RULES (banked as memories this session)
- **[[progress-bar-every-long-process]]** (user 2026-06-27): ANY time-consuming run gets a live
  bar+ETA on the cockpit card — `tools/with_progress.sh "<label>" -- <cmd>` (guaranteed
  start+STOP) + `tools/fab_beat.sh <pct> <eta_s> "<detail>"` for live %. Builds self-scrape;
  Workflows use `tools/wf_cockpit_progress.sh --key 573 &`. NEVER hand-roll progress start/beat/stop.
- **[[look-before-calling-black]]** (user 2026-06-27): when a frame reads black/blank by luma or
  numeric stats, LOOK at the PNG with vision before calling it invalid — sparse corner text is
  valid evidence. Numbers + vision are complementary.

---

## 8. NON-NEGOTIABLES (don't relearn the hard way)
- Build ONLY via `~/Dev/fabricore/tools/tools/dell_build.sh` (`DELL_REPO` = bare `System573_MiSTer`).
  A PreToolUse hook blocks off-protocol builds.
- Verify with a NUMBER **and LOOK** at the frame; never a vision-only verdict, never a number-only
  dismissal of a sparse frame.
- De-confound EVERY HW verdict: warm-reboot via `devlock de10 reboot 573`, uptime <60 s, then
  EXACTLY ONE `load_core`.
- Lock shared HW before use; release after. Reboot a board only via `devlock … reboot`.
- Vendored `psx/` stays pristine (the atapi.v fix is in `rtl/`, a normal edit).
- Commit as **Fabricore**, push to **private** by default (`origin`); `public` is release-only.
  End commit msgs with the Claude co-author trailer.
- Gate −1: a wrong/synth dump fails like an RTL bug. (ddrsbm data is authentic — MAME advances
  PAST BOOT CHECK with it, so this is RTL/timing, not data.)

---

## 9. KEY ARTIFACTS & PATHS
- Fix commit: `a5823f7` (HEAD `7e29d0b`). rbf md5 `05344ad0`. Stuck-state evidence:
  `local/ddrsbm_de10_bootcheck_a5823f7.png`. Target oracle: `local/mame_ddrsbm.png` (320×240,
  "DO YOU WANT TO INITIALIZE FLASH-ROM? / Yes: Please press test button").
- Fix RTL: `rtl/atapi.v` (`IDENT_SETTLE`=2048 @ line ~101, `S_PREP` @ ~79, dispatch @ ~481,
  handler @ ~636). RED/GREEN test: `sim/tb_atapi_settle.v` + `sim/Makefile` `ATAPI_IDENT_NOSETTLE=1`.
- Traces/code: `local/ddrsbm_ata*.txt`, `local/ddrsbm_ata_full.log`, `local/ddrsbm_code.bin`.
- SignalTap: captures `local/signaltap/20260624_*`; decoders on `dbg-signaltap-atapi-irq` branch
  (`tools/signaltap_573/`). RUNBOOK there too.
- Prior deep proof: `docs/2026-06-25-ddrsbm-identify-irq-race-handoff.md`.

---

## 10. OPEN / LATENT
- **LATENT (real, not ddrsbm's gate):** atapi.v's DMA drain is disc-only — a game DMAing a
  non-disc data-in command (IDENTIFY/INQUIRY/TOC) gets no drain + wrong data. ddrsbm uses PIO so
  it dodges this. Fix when convenient (extend the DMA path to datain_ident/datain_toc/resp_byte).
- **Pre-existing unrelated:** `s573_io` sim test fails on a clean tree (JVS/IO detect, status
  50ca vs e7ca). Not ours; worth a separate look.
- **powyakex** still parked (its ~10 h "HARDWARE ERROR" is a CD/data-loader timeout); re-check
  after this fix only if it shares the ATAPI data path. See [[powyakex-baseball-flash-stall]].
- Keep commit `76f0274` (exact CR-589 IDENTIFY content) — correct, just not the gate.
