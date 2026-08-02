# RESULT — gate 5: the CDROM-timeout FIX, cleared on silicon (2026-07-03)

Follows `docs/2026-07-03-gate5-red-bench.md` (the RED bench) and
`docs/2026-07-02-gate5-cdrom-timeout-observation.md` (the observed verdict + fix
directions). This is the FIX + its on-silicon verification. Memory:
`[[fabricore-573-digital-bringup]]`.

## VERDICT (properly scoped — read the scope, not just the headline)

The reproducible `HARD-WARE ERROR -1N / CDROM DRIVE TIMEOUT` (which killed ddrsbm
2/2 boots at gate 4) **no longer reproduces on silicon** across a de-confounded
soak that exercised the trigger workload at BOTH documented death sites (DATA
LOADING and the post-attract per-song ritual). The audited mechanism is fixed and
RED↔GREEN-proven in sim; a 4-lane RTL review and a 3-lane verdict review both
returned it sound.

This is a **did-not-reproduce over a bounded de-confounded soak with the audited
mechanism fixed** — NOT a directly-observed trace of the fixed mechanism firing
(MAME cannot model the RTL/HPS mechanism, so the exact silicon variant stays
audited, not observed — per the observation doc). It clears the **`-1N` wedge**;
it does NOT make ddrsbm playable end-to-end (song gameplay still loops on
stage-`ready` — that is the separate, unwired P4 MP3 blocker, not gate 5).

## THE FIX (commit `5ea85ce`, built rbf md5 `0e2252e3`)

Three parts, exactly the documented fix directions:
1. **`rtl/system573_top.v`** — one named `wire ide_rst` now drives BOTH `atapi`
   AND `s573_cdimg` reset (cdimg previously got only clk/rst — the "reset
   blindspot").
2. **`rtl/s573_cdimg.v`** — new `ide_rst` input PORT, FSM resets on `rst|ide_rst`;
   `sec_req` accepted in ANY state (restart the fetch + re-tag the previously
   untagged `sec_ready`), defense-in-depth.
3. **`rtl/atapi.v`** — START/STOP UNIT (`0x1b`) → GOOD non-data completion (folded
   into the TEST UNIT READY arm), instead of the default CHECK-CONDITION that
   contradicted REQUEST SENSE's key-0. Faithful to the CR-589 + MAME oracle.

## RED → GREEN → BUILD → SILICON (the chain)

- **SIM.** `make -C sim gate5_replay` → RED (RESULT: FAIL, **1033 errors**) on the
  pre-fix RTL; → GREEN (RESULT: PASS) with the fix, **no define**. Full suite
  `make -C sim` → **38/38**. RED↔GREEN independently reproduced from scratch by
  the verdict review (extracted pre-fix RTL from `5ea85ce^`, got exactly 1033).
  NOTE: the RED is reproducible only against the **RED-era bench (`3a72def`,
  no `-DGATE5_FIX`)** — HEAD's `tb_gate5_replay.v` drives the real `ide_rst` port
  and cannot compile against pre-fix RTL. A future RED re-demo must use `3a72def`.
- **RTL review.** 4 lanes (correctness / regression / synthesis / doctrine) → 0
  findings. Doctrine: STOP UNIT-as-GOOD is faithful (removes a *self-contradicting
  synthetic* CHECK-CONDITION); `sec_ready` is raised ONLY in S_DONE after a genuine
  1176-word stream; an un-reset wedge still fails LOUD (unbounded BSY → driver
  timeout → `-1N`). Non-blocking note: the fail-loud property rests on there being
  NO device-side timeout — if a future change adds one that auto-completes a
  stalled fetch, RE-AUDIT (that would be the shape of a masking regression).
- **BUILD.** Quartus rc=0 (0 errors, 193 warnings), 34:49; rbf deployed to the
  JTAG bench, on-board md5 `0e2252e3` verified == the pulled build.
- **SILICON.** See the table.

## SILICON EVIDENCE (de10, each de-confounded: warm-reboot, uptime<60s, ONE load_core)

| # | Test | Objective result |
|---|------|------------------|
| 1 | CD install #1 (operator TEST) | ERASE→INITIALIZE(CD write 13→100%)→COMPLETE, **no `-1N`**; `.sav` settled (after ~16MB flush) to md5 `82243fe3` == MAME golden, byte-identical |
| 2 | Boot → `MEMORY CHECK 22H/22J/22G` → attract | ~6 min sustained 24–69% frame-to-frame motion; vision: ddrsbm attract (INSERT COIN / GAME OVER). Run-2 death site — no `-1N` |
| 3 | Gameplay song-start | Reached the stage → the per-song CD preload ritual (READ12 + STOP UNIT) COMPLETED; then loops on `ready` = **P4 music**, not `-1N` (no error screen) |
| 4 | CD install #2 (autonomous, injected TEST via `tools/mister_press.py`) | ERASE→INITIALIZE(92% observed)→COMPLETE, **no `-1N`**; `.sav` == golden `82243fe3` again |
| 5 | **Clean ≥10-min soak** (`local/gate5_clean/soak/`) | ~14 min, 30/43 sampled frames attract-alive (55–69% motion), rest boot-phase/brief black transitions; vision: distinct attract screens (HOW TO PLAY, Dancemania, KONAMI logo, GAME OVER) → NOT a frozen feed; **no post-attract `-1N` wedge** |
| 6 | Regressions | powyakex → title screen PASS; hyperbbc → attract gameplay PASS; install-golden → `.sav` == `82243fe3` (×2) |

**The clearing artifact is `local/gate5_clean/soak/` (the manually/injection-driven
clean soak).** The earlier scripted run `local/gate5_soak/` fell into the
flash-restore confounder and sat at the `INITIALIZE FLASH-ROM?` prompt — it does
NOT show attract and is NOT the clearing evidence.

## WHY THIS IS THE REAL FIX (not masking, not a confound)

- **READ path genuine, not faked:** it is the varied, multi-screen ATTRACT imagery
  (distinct md5 per frame, full-color, vision-verified different screens over ~14
  min) that proves the CD READ path serves real data un-faked — not the `.sav`.
  (The `.sav`==golden match proves the WRITE/flash path.)
- **CD data correct:** two independent installs produced a **byte-identical** 16MB
  flash (`.sav` md5 == golden `82243fe3`), so the READ12-storm CD path completes
  correctly, not zero-filled.
- **f2sdram re-roll ruled out FOR THIS rbf:** the board booted, installed twice,
  and ran ~14 min attract — a wedging bridge re-roll would have prevented that. But
  the verdict is specific to this netlist (see caveats).

## CAVEATS / SCOPE — what "cleared" does and does NOT mean

1. **Scope:** clears the `-1N` CDROM DRIVE TIMEOUT wedge. Does NOT mean "ddrsbm
   runs/plays": actual song gameplay still loops on stage-`ready` because the P4
   MP3 decode chain is unwired (separate, known blocker — NEXT phase).
2. **Not a directly-observed mechanism trace:** a did-not-reproduce over a bounded
   (~14 min) soak with the mechanism audited (not observed on silicon). Strong
   (the original failed 2/2 within ~40s), but weaker than catching the fixed bug
   in the act.
3. **TEST-assisted, not zero-interaction:** the handoff's literal verify spec — a
   ZERO-INTERACTION cold boot surviving ≥10 min — is NOT yet demonstrated. The
   Main-firmware flash-restore from the remembered slot-4 (S4) mount is finicky and
   fell THROUGH to the install prompt on a clean warm-reboot; attract was reached
   only after an injected/operator TEST install+boot. This S4 flash-restore path is
   a **pre-existing confounder the fix does NOT touch** (the fix is CD-path-only).
4. **rbf-specific / re-rollable:** proven on ONE built netlist (`0e2252e3`). The
   f2sdram bridge placement is marginal; a REBUILD can re-roll it into a wedging
   variant. The in-RTL ballast (see `[[f2sdram-bridge-placement-marginal]]`) is
   still needed; any rebuilt rbf must be re-verified on board, and a future wedge
   must NOT be blindly attributed to a gate-5 regression.
5. **Ready-loop classification is auditable:** the gameplay loop is P4 (music-sync),
   NOT a masked CD stall — because `-1N` is a specific error SCREEN that never
   appeared AND the game reached the stage (so the per-song CD ritual completed).
6. **Oracle-anchored:** STOP UNIT-as-GOOD is per CR-589 + MAME; "matches MAME" ≠
   "matches real CR-589 silicon" (low risk, named per doctrine). Gate -1 (data) was
   already clean; the MAME oracle could not itself clear silicon — the soak is the
   operative evidence.

## ARTIFACTS

- Fix: commit `5ea85ce` (`rtl/atapi.v`, `rtl/s573_cdimg.v`, `rtl/system573_top.v` +
  `sim/tb_gate5_replay.v` now GREEN with no define + suite testbenches).
- Verify recipe: `local/tracedig/gate5_soak_verify.sh` (commit `93d35d0`). NOTE its
  `<5% vs -1N anchor` auto-verdict is UNRELIABLE — the mostly-black install/boot
  screens trip it; motion + vision is the true discriminator (learned this run).
- Clearing soak frames: `local/gate5_clean/soak/s*.png`; install filmstrip:
  `local/gate5_clean/inst_*.png`; `-1N` anchor: `local/dio_v5_watch_083.png`;
  golden md5 ref: `local/ddrsbm_golden_md5.txt` (`82243fe3`).
- Reviews: RTL fix review + verdict review (both all-sound; verdict review
  independently reproduced the 1033-error RED and confirmed distinct attract
  screens).
