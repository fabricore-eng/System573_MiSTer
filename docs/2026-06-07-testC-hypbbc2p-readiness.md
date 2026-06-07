# Test C readiness — hypbbc2p CD install (board-free audit, 2026-06-07)

Workflow `wphcb1z5i` (install-path audit + MAME oracle + batch coverage). Build `c8cb178`
(writable flash + F0 BIOS entry) is deployed to `_Console`; the staging below is ready.

## Verdict: CONDITIONAL GO for attempt #1 (no rebuild needed)

Launch `Hyper Bishi Bashi Champ 2P (573)` from the MiSTer **Console** menu, then OSD →
**573 Boot Device → CD-ROM** (status `O[93]`; maps to DIP SW4 — the install needs SW4=CD-ROM,
default is Flash). De-confound: warm-reboot, uptime<60s, ONE launch, before each capture.

Image set (current `mgl/hypbbc2p_console.mgl`, verified vs emu.sv:657-692):
`573bios.bin` (ioctl0) + `flash16m_blank.bin` (16MB 0xFF, ioctl2) + `nvram8k_blank.bin`
(8KB, ioctl3) + `hypbbc2p.chd` (ATAPI mount, slot1). **No `.u1`** — see the open question.

## #1 risk — the security cassette (UNRESOLVED, decides whether boot even reaches the installer)

The two investigations DISAGREE and the tiebreaker (ksys573.cpp `// doesn't check` scope vs
`hypbbc2p_cassette_install` lamp-strobe wiring) couldn't be re-read on-disk:
- **Audit:** hypbbc2p ships `gx908ja.u1` (X76F100, 132 B) and is NOT a "doesn't check" title like
  hyperbbc → the `.u1` is likely required at ioctl4.
- **Batch:** the cassette d-lines are wired to lamp strobes (like hyperbbc) → the blank X76F100 our
  `x76f100.v` presents is fine, no `.u1` needed (what the current mgl does).
- **MAME oracle:** with a *fabricated* `.u1`, MAME halts at **SECURITY-CASSETTE ERROR (-11N)** — the
  signature of a *present-but-wrong* cassette. Does NOT distinguish "blank passes" from "real dump
  required". Saved at `local/mame_ref_hbb2p/hbb2p_0002.png` (the **negative reference**).

**We do NOT hold the real `gx908ja.u1`** (crc 8900eaff; only gtrfrk5m/pnchmn2 `.u1`s on disk). So if
hypbbc2p checks the cart, attempt #1 fails at `-11N` and we're blocked until that dump is acquired.

**Resolve by running it:** attempt #1 = current no-`.u1` mgl (also sidesteps a real seccart-type-inference
bug: a 112-132 B X76F100 `.u1` would mis-latch as X76F041 at emu.sv:1528-1529; with no `.u1` loaded
`sec_cart_type` stays its reset default 0 = X76F100, correct). frame_diff the HW capture vs the `-11N`
reference: **HIGH SSIM = we hit the same security wall → need the (missing) real `.u1`**.

## frame_diff plan (no positive golden exists)

No MAME "correct boot" golden for hypbbc2p (blocked on the missing `.u1`). So:
1. **Negative match:** HW capture vs `local/mame_ref_hbb2p/hbb2p_0002.png` (`-11N`). High SSIM = security wall.
2. **Liveness:** filmstrip across the install — successive frames non-identical (SSIM<~0.95, luma moving) =
   install progressing; byte-identical >30s = stalled (same method that caught the green-0s stall).
3. **Success bar (honest):** install UI advances → after flipping boot device → Flash + reload, a rich
   (40KB+), dynamic frame that does NOT match the green-0s stall NOR the `-11N` wall. Strongest achievable
   claim without the `.u1` golden = "install ran + advanced past both known failure walls", NOT "matches MAME".

## No-op ERASE — DO NOT upgrade before Test C

Provably correct for single-pass program-into-blank (tb_s573_flash_sdram.v). Risk only if the install
erases-then-verifies-0xFF a sector it already programmed in one pass (circumstantial evidence: the
gtrfrk2m "check and erase 32mb" HACK). Real streamed-0xFF erase is a non-trivial ALM-budget-risky RTL
change on an UNCONFIRMED hypothesis. **Run Test C as the probe:** if install advances then stalls/errors
*mid-progress* (not a clean pre-install stop), THAT is the HW signal to implement real erase. Don't do it blind.

## Batch — only hypbbc2p is testable now

| Game | CD held | Testable now | Blocker |
|---|---|---|---|
| hypbbc2p | yes | YES | (this test) |
| darkhleg | NO | no | no CD held; CHECKED X76F041 |
| konam80s | yes | no | missing `gc826ea.u1`; CHECKED cart (Feature A auth) |
| fbait2bc | yes | no | missing `gc865ua.u1`; CHECKED cart; uPD4701 trackball |

The other three need a CHECKED security cassette (Feature A authenticate, not just present) + their `.u1`
dumps we don't hold. Effectively a single-game (hypbbc2p) HW session.

## Follow-ups (deferred, need a rebuild and/or a missing dump)
- Fix seccart size→type: a 112-132 B `.u1` must latch type 0 (X76F100), not type 1 (X76F041)
  (emu.sv:1528-1529: change the middle threshold from `>=112` to e.g. `>=256`). Batch into the next build.
- Real streamed-0xFF flash erase — only if Test C's HW probe shows it's needed.
- Acquire `gx908ja.u1` (and konam80s/fbait2bc `.u1`s) for the MAME golden + the `.u1` fallback.
- MAME oracle reusable lua: `tools/mame_snap_milestones.lua`.
