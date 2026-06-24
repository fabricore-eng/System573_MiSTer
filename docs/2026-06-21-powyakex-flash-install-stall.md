# powyakex (baseball) — de10 boot stalls at FLASH ROM CHECK (banks J/H BAD)

## ★★★ RESOLVED (2026-06-23) — root cause = the dual-lane flash JEDEC ID

**FIXED** in `feat-flash-id-dual-lane` (commit c16559d). The root cause was NOT an install-flow
gap or a blank-J/H read divergence — **both theories below are red herrings.** MAME boots an
all-blank onboard flash (J/H included, all 8 chips 0xFF — verified in its nvram) and passes. The
gate was the **flash autoselect JEDEC ID**:

- Each onboard 16-bit flash word is TWO byte-wide x8 chips (.31x low lane / .27x high lane), so
  autoselect drives the ID into BOTH lanes → real HW + MAME return **MFR 0x0404 / DEV 0xADAD**
  (id `0xADAD0404`). Our `flash_nor` modeled a SINGLE lane (`0x0004 / 0x00AD`, high lane 0x00).
- A MAME oracle trace (`tools/trace/pwk_flash_tap.lua`) showed the BIOS does exactly ONE flash
  access in 150 s — a **bank-0 autoselect reading `0xADAD0404`** — then boots to title. It NEVER
  does a per-bank J/H scan. So the de10's single-lane `0x00AD0004` failed that ID gate and
  dropped the BIOS into the per-chip FLASH ROM CHECK *diagnostic* (M/L OK, J/H BAD) → halt.
  **The M/L-vs-J/H asymmetry was a downstream diagnostic symptom, not the cause.**
- Fix: override `MFR_ID`/`DEV_ID` to `0x0404`/`0xADAD` in `s573_flash`'s two `flash_nor`
  instantiations (the board fact lives in the board module; the generic default stays the
  datasheet single-byte ID). iverilog-green across the flash testbenches.
- **Validated on de10:** powyakex boots past the check into attract (objectively LEFT the
  byte-stable FAIL state — 0.35 ssim / 63% diff vs the old halt, was stuck at ssim 0.067);
  hyperbbc + hypbbc2p no regression. (Formal `verify_frame` PASS pending `method=vramspace` +
  a deterministic anchor — a geometry-confound-free follow-up, not a powyakex blocker.)
- **Lesson:** the `req_cnt=0` "zero array reads → it's the status path" decode was a RED HERRING
  that mis-aimed a build + a SignalTap attempt. The **dumb-things sweep** (ruled out
  data/romset/install) + the **MAME oracle trace** (pinned the actual gating read) cracked a
  week-stuck bug. The single-lane ID had been filed as "separate, probably inert" — it was the
  whole fix. (See `CORE_DEV_PLAYBOOK.md`.)

_Everything below is the original 2026-06-21 investigation, preserved as the record of how we got
here — but the conclusion is the section ABOVE, not the sections below._

---

_Session 2026-06-21 (573). Subject: the baseball test-stream bring-up. PROOF verdict =
honest FAIL (ssim 0.067). Verify every claim with a NUMBER, never vision._

## ★★ DECODE RESULT (2026-06-21 live, instrument build dbg-jh-573)

Built an instrumented core (emu.sv dbg_field: field0=J/H ch4 read word `dbg_jh_q`,
field2=`dbg_wr_last` download extent; status[94]=On via System573.CFG paints the field as a
solid 24-bit color), deployed to de10, booted baseball, decoded all 4 painted fields:
- **The boot REACHES the flash check** (verified: normal-video boot still shows the J/H-BAD
  screen; field1 stage latches `io04_seen=atapi_seen=idecmd_seen=bankctl_wr=winsel=1`, heart
  advancing) — it reads the DIP/config, does the CD/ATAPI drive check, WRITES the bank-select
  reg, and READS the flash window.
- **BUT it does ZERO array-DATA reads of ANY bank** — `req_cnt=0, fill_cnt=0, first_seen=0,
  jh_seen=0` (field0 + field3 both painted black/zero). The s573_flash ch4 array-fill path
  never fires during the whole boot.

**Conclusion:** baseball's FLASH ROM CHECK does NOT read the banks' program DATA — it judges
each chip via the **autoselect/STATUS query** (the combinational `id_read`/`cmd_dout` path in
flash_nor, which doesn't trigger a ch4 fill). So "upper banks J/H BAD" is a chip
STATUS/ID-response difference for banks 2/3, **NOT a data-content mismatch or a data-read
bug**. The array-read probe was the wrong layer (it can't see the status path).

**Open tension:** s573_flash's autoselect returns a FIXED, bank-independent MFR/DEV ID, so it
shouldn't distinguish M/L from J/H — yet the check does. So either the status/autoselect
response IS bank-dependent in a way the current model doesn't capture (e.g. a per-chip
program/erase STATUS bit), or the check reads a bank-specific status the RTL answers
incorrectly for banks 2/3. **Next probe (follow-up build):** instrument `cmd_dout`/`id_read`
+ the win_dout returned for each bank (capture the value the BIOS actually consumes on the
window read, gated by bank), to see what J/H answers vs M/L. That pins the exact divergence.

## ★ UPDATE — corrected conclusion (this is NOT a flash-read core bug)

The "deep core bug / needs a build" framing below was WRONG. The de10 CD-install path
WORKS — it's **operator-TEST-triggered**:
- Booted **hypbbc2p with a blank flash** → it prompts **"DO YOU WANT TO INITIALIZE
  FLASH-ROM? Yes: please press test button"**. Injecting the headless TEST keypress
  (`mister_press.py key t` → `key_test` → `test_btn`, the recent commit 35e6d8a) drove it
  to **"INITIALIZING FLASH-ROM"** with a progress bar (21%→…→complete). So the board
  installs CD games via the operator TEST press. The earlier "no .sav / no flash writes"
  was simply because **nobody had pressed TEST**.
- **powyakex behaves differently**: boot banner ("GX802 JIKKYO PAWAFURU PRO YAKYU …
  VER. JAB") → it runs a **FLASH ROM CHECK** (M/L OK, J/H goes `--` then `BAD`) → **HALTS**.
  It shows NO "press test to initialize" prompt, and a TEST press at the check does nothing
  (md5 unchanged). So powyakex's game/installer code halts on bad flash instead of offering
  to initialize — its install trigger differs from hypbbc2p.

**Remaining gap (powyakex-specific, real) — quick paths RULED OUT (2026-06-21 live):**
- **Operator TEST (tap OR hold-during-boot): NO effect.** Held TEST through the whole boot
  (CHECKING RTC-RAM → FLASH ROM CHECK) → same halt, no service/install screen. powyakex's
  code treats the bad upper banks as a fatal fault and halts (unlike hypbbc2p, whose code
  prompts "INITIALIZE FLASH-ROM? press test"). So the install is NOT operator-TEST-triggered
  for powyakex.
- **Pre-built-flash-from-MAME: dead end.** MAME boots powyakex from a BLANK onboard flash
  with NO halt (it does NOT install to flash; nvram stays empty) — so there is no installed
  image to extract and load on the de10.

- **Populated-flash test (live): J/H stays BAD with a WRONG-data populated flash too.**
  Loaded `hbbflash.bin` (hyperbbc's real 16 MB, all banks) as powyakex's flash via a test
  `.mgl` → powyakex's FLASH ROM CHECK settles to the SAME halt (M/L OK, J/H BAD; byte-
  identical frame to the blank case). So it is NOT a simple blank-vs-populated issue. Either
  the check is content-aware (J/H must hold powyakex's OWN program — a checksum) OR the J/H
  read doesn't reflect the loaded SDRAM content for this access path (a read quirk). Note the
  asymmetry: M/L reads OK with BOTH blank and hbbflash (a lenient check), J/H rejects both.

**Root divergence PINNED:** the de10's BLANK upper flash banks (J/H, SDRAM
0x01800000–0x01FFFFFF) read as a FAULT, where MAME reads the same blank as OK-and-boots. So
the de10's flash-init/read of the upper 8 MB differs from the reference for a *blank* flash.
**Next phase = instrument it (a build):** expose the actual J/H read word (`dbg_first_q` for
a bank≥2 burst) + the blank-download extent (`dbg_wr_last`) in the flash debug readback
(`rtl/emu.sv:1897+` `dbg_field`, painted via status[94]) — the shipped rbf only exposes
access *counts*, not the data — then a ~45 min build → capture+decode → see whether J/H reads
0xFFFF (correctly blank, so powyakex's check is stricter than MAME's) or garbage (the
blank-16M download isn't reaching/initializing the upper 8 MB in SDRAM). Or SignalTap the
flash bus. `dip_sw = {status[93], 3'b111}` — only SW4 wired, SW1-3 hardcoded off (a hidden
install DIP is also possible but secondary).

The original investigation below (banks J/H, flash plumbing) is preserved for reference but
the root cause is the install-flow gap above, not a flash-read defect.

---

## What works (verified)
- **Gate −1 (MAME oracle):** `powyakex`/`jppyex98` staged on dell, MAME 0.285 `verifyroms`
  = both OK/best-available (security-cassette dumps match MAME's hashes). MAME boots
  powyakex from the NAS data to a full attract loop: intro movie → **title screen**
  (Jikkyou Powerful Pro Yakyuu EX, INSERT COIN) → demo gameplay. Reference frames in
  `local/mame_ref/mame_powyakex_*.png` (title = the no-input PROOF anchor). So the DATA
  is good.
- **de10 core load:** powyakex `.mgl` authored (`/media/fat/_Console/Powerful Baseball
  EX (573).mgl`), security cassette `gx802ja.u1` (sha1 9019de5f…, authentic, X76F041
  tier) + CHD staged. Core loads (CORENAME=System573), BIOS runs, cassette boot-signature
  check PASSES (no −11N), CD program loads (~40-70s, like MAME), game/installer runs.

## The failure (objective)
- de10 stalls at the **BIOS/game "FLASH ROM CHECK"**: `27M/27L/31M/31L = OK`,
  `27J/27H/31J/31H = BAD` (upper flash banks J/H, i.e. banks 2/3 of 4). Static for >15 min
  (board responsive, NOT wedged).
- frame_diff vs the MAME title ref = **ssim 0.067, 89.2% pixels differ, MISMATCH**
  (verify_frame FAIL, uptime 177s = valid). Fed to /public/status for the stream PROOF.
- Board screenshot AND the 1280×720 HDMI capture agree (the "de10 screenshot is noise"
  worry was stale — both paths render this cleanly).

## What it is NOT (ruled out)
- **Not a J/H read-path bug:** hyperbbc uses the FULL 16 MB (all 4 banks incl J/H) and
  boots+runs on the de10 (HW-confirmed). The flash-persistence roundtrip also proved 16 MB
  reads byte-exact. So the de10 READS programmed J/H correctly.
- **Not a general install regression:** `hypbbc2p.sav` is dated Jun 14 20:12, built on the
  SAME `_Console` rbf (Jun 14 10:22, md5 3bd9419e) my powyakex .mgl uses. So hypbbc2p's
  CD-install path works on this exact rbf. → **powyakex-specific.**
- **Not a missing operator button:** injecting the headless TEST keypress
  (`mister_press.py key t` → `key_test` → `test_btn`) did NOT change the screen (identical
  md5 before/after). The FLASH ROM CHECK is a hard halt, not a button prompt.
- **Not blank-data content I loaded:** `flash16m_blank.bin` is uniformly 0xFF across all 4
  banks (verified on the board). No `powyakex.sav` was auto-created → **zero flash-write
  activity** (no install programming happened — the saver auto-saves on flash_dirty).

## The open question (decisive, unresolved)
Why M/L pass but J/H fail on a uniformly-0xFF flash, with no flash writes:
- (A) **Install not programming:** powyakex's installer should program the onboard flash
  from CD (like hypbbc2p) but isn't — the game's self-test then finds J/H un-programmed →
  BAD. (But: no flash writes at all, and hypbbc2p installs fine on this rbf.)
- (B) **Blank J/H reads wrong:** the `flash16m_blank` download fills SDRAM M/L (lower 8 MB)
  with 0xFF but leaves J/H (upper 8 MB, SDRAM 0x01800000–0x01FFFFFF) as stale garbage →
  the check reads non-0xFF for J/H → BAD. (But: hyperbbc downloads a full 16 MB image and
  J/H work — so the download CAN reach J/H.)
- MAME runs powyakex with blank onboard flash and boots (empty nvram, no persisted flash) →
  the de10's FLASH ROM CHECK diverges from MAME's for the same blank flash.

## Next step (precise): the built-in flash-path debug readback
`rtl/emu.sv:1897+` + `rtl/s573_flash.v` ship a flash-path debug readback that paints
captured state as a SOLID 24-bit RGB color (a screenshot decodes it). It is **settable
headlessly via System573.CFG** (persistent O-bits): `O[94] 573 Flash Debug = On`,
`O[96:95] Dbg Field = ch4Q | expQ | cnt/sz | wrAddr`.
- `status[94]` = byte 11 bit 6 (0x40); current CD-boot byte 11 = 0x20 → set 0x60.
- field select = byte 11 bit 7 (status95) + byte 12 bit 0 (status96).

Capture each field during a fresh powyakex boot and decode:
- **ch4Q / `dbg_first_q`** — the first ch4 burst word for J/H. 0xFFFF (blank) ⇒ case (A);
  garbage ⇒ case (B).
- **wrAddr / `dbg_wr_seen`+`dbg_wr_last`** — was any flash write issued? (install activity)
- **cnt/sz / `dbg_req_cnt`/`dbg_fill_cnt`/`sdram_sz`** — fill requests vs acks, SDRAM size.
- Confirm the paint mechanism (emu.sv after :1971) and the screenshot decode before reading.

Alternative: SignalTap (fabricore:signaltap) on `flash_wr_req/flash_wr_ack/flash_mem_*`
during a powyakex vs hypbbc2p boot to see exactly where the install flow diverges.

## Stream-test deliverables (done this session)
- PROOF FAIL verdict (ssim 0.067) → chat badge + verdict-history TSV → /public/status.
- WORKROOM thought-cards (`/tmp/fabricore-cockpit/workroom_cards.json`) tracking the live
  debug (public-safe, board="the board"/core-573).
- The live debugging of THIS bug is the build-in-public stream content.

## Artifacts
`local/mame_ref/mame_powyakex_*.png` (MAME refs), `local/de10_bb/de10_powyakex_flashcheck_*`
(board + HDMI flash-check frames), `local/mame_dense/` (MAME dense early boot).
de10 staging: `/media/fat/games/System573/powyakex.{u1,chd}` + the `.mgl`.
