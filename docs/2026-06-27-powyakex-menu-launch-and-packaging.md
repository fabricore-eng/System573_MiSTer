# Handoff — powyakex menu-launch state + MiSTer packaging model (2026-06-27)

**Session type:** context / Q&A. **No code changed, nothing to commit.** This doc + the new
`mister-arcade-cd-packaging` memory exist so a fresh session loses nothing.

One-liner: powyakex (Powerful Baseball EX) is already menu-launchable on the de10 (the `.mgl`
launcher + cassette + CHD are staged, and the Jun 25 build with the flash-ID fix is deployed).
The session then worked through *why* 573 games live in `_Console`, not `_Arcade`, and how that
compares to Jotego's brand-new CPS3 core.

---

## 1. Can powyakex be launched from the MiSTer menu? — YES (verified on the board)

Read-only probe of the de10 (both boards `(free)` at session start; no reboot/load performed):

- Menu launcher present: `/media/fat/_Console/Powerful Baseball EX (573).mgl` (Jun 22). It
  appears in MiSTer menu → **Console → "Powerful Baseball EX (573)"**.
  - (Sibling `Baseball TEST-popflash (573).mgl` is a debug variant — ignore it.)
- Game data staged: `/media/fat/games/System573/powyakex.u1` (authentic 548-B `gx802ja.u1`,
  X76F041 tier) + `powyakex.chd` (`802jab02`). Both present.
- Deployed core: `/media/fat/_Console/Konami_System_573.rbf`, Jun 25 02:58.
- The `.mgl` boots CD-ROM (`O[93]=CD-ROM`, set persistently in System573.CFG); if it lands on a
  flash screen instead, flip "573 Boot Device → CD-ROM" in the OSD.

### Build-lineage caveat (NOT freshly re-verified)
The FLASH ROM CHECK wall that killed the 2026-06-21 stream test was root-caused + fixed: the
**dual-lane flash JEDEC ID** (`s573_flash` was modeling a single x8 lane → `0x00AD0004`; real HW
+ MAME drive the ID into BOTH lanes → `0xADAD0404`). Fix = `c16559d` on `feat-flash-id-dual-lane`,
**merged into the current branch `feat-digital-bringup` as `d56f93d` (PR #1)**. The Jun 25 rbf
post-dates that merge, so it *should* include the fix — but I did **not** re-capture powyakex on
this exact rbf this session. Last objective number on powyakex: ssim 0.35 / 63% diff vs the old
halt (i.e. "objectively LEFT the FAIL state"), NOT a verify_frame PASS.

### Honest status to give Frank
- Flash wall fixed + merged + (by lineage) in the deployed build → should boot **past** the check
  into attract (intro → title → demo), like MAME.
- NOT a verified-done: no `verify_frame` PASS (needs `method=vramspace` + a deterministic anchor,
  to dodge the moving-game geometry/timing confound). And memory notes a **~10h-runtime "HARDWARE
  ERROR" overlay** (suspected f2sdram bridge — see `no-mask-fault-with-fake-data` +
  `f2sdram-bridge-placement-marginal`).
- De-confound rule before any verdict: warm-reboot the MiSTer (`/proc/uptime` < ~60 s), then
  EXACTLY ONE load — a stale HPS↔FPGA bridge mimics a wedge.

### Open offer (not done — Frank to decide)
I offered to do a de-confounded capture run on powyakex myself to get a fresh objective frame
number on where it lands *today* on the deployed rbf, before he tries it live. Not started.

---

## 2. Why 573 games are in `_Console` (`.mgl`), not `_Arcade` (`.mra`)

- The 573 core is **PlayStation-derived**: `CONF_STR` starts `"PSX;"` (`rtl/emu.sv:383`), `emu.sv`
  is a PSX.sv clone. So the rbf + launchers inherit the console folder + framework.
- The arcade `.mra` format only **assembles fixed ROM parts from a zip** into ioctl indices. It
  **cannot mount a CHD as a live CD**, and arcade cores carry an "unsafe" guard that blocks
  runtime file mounts (see the F0 comment block, `rtl/emu.sv:388`). So any game that needs a
  mounted CD, a security cassette, or writable flash save-back **must** launch as a console
  `.mgl` (S-slot CHD mount `S1,CUECHD` + `F0..F5` index file-mounts + the `SC4,SAV` flash save).
- The ioctl index map (`rtl/emu.sv:733-741`): 0=BIOS, 1=EXE, 2=flash(16 MB), 3=NVRAM(8 KB),
  4=security EEPROM (.u1), 5=DS2401 serial (.u6); CD mounts via the S1 slot; flash save via SC4.
- **The one 573 game packaged as a proper `_Arcade` `.mra` is hyperbbc** (`mra/hyperbbc573.mra`) —
  because it's **flash-only** (all content fixed ROM in a zip, no CD, no save-back). That's the
  clean arcade case, and it works.
- **Path to move install-games into `_Arcade` later:** pre-bake the *installed* flash image and
  ship THAT as an `.mra` (the CPS3 move). Works for install-to-flash games (hypbbc2p); does
  **not** work for run-from-CD games (powyakex).

Two distinct CD models among our games:
- **Install-to-flash** (hypbbc2p): BIOS/installer reads the CHD once, programs the writable
  onboard flash, writes an install signature to NVRAM, then runs from flash (CD then dormant).
- **Run-from-CD** (powyakex; the DDR digital family): the disc is **live during gameplay**.

---

## 3. CPS3 comparison + the accuracy reasoning (the conceptual thread)

Context: Jotego's **Capcom Play System 3** core launched on MiSTer **June 2026** — the obvious
"CD-based arcade core."

- **No other MiSTer *arcade* core mounts a live CD.** CD/CHD mounting on MiSTer is a *console*-
  framework capability (PSX, Saturn, NeoGeo CD, PCE-CD … and our 573 `.mgl`). The arcade `.mra`
  path still doesn't mount discs.
- **CPS3 deliberately avoids live CD:** it ships "**No CD**" pre-decrypted memory sets (games load
  in seconds vs a ~25-min real-HW SIMM flash). Effectively a cartridge core; no CD drive modeled.
- **Does that hurt accuracy? For CPS3, no** — because on CPS3 the CD is a **one-time loader, out
  of the gameplay loop**. A faithful SIMM image ⇒ bit-identical runtime. You lose *completeness*
  (install/boot experience, drive HW), not *gameplay fidelity*.
- **The catch, and why it matters to us:** the CPS3 shortcut is only safe when the CD is out of
  the runtime loop. Install games (hypbbc2p) qualify. **Run-from-CD / streaming games do NOT** —
  powyakex, and especially the **DDR digital family where MP3 audio streams off the disc *during*
  play**. For those the modeled ATAPI CD drive is mandatory or accuracy collapses. This is exactly
  why the ddrsbm "BOOT CHECK" / ATAPI work is the hard part of the roadmap.
- **Distribution posture is identical to ours:** Jotego ships the core only; the user brings dumps
  (the "No CD" set is a MAME romset the user sources). Same as 573 = core ours, BIOS/cassette/CHD
  user-supplied (Gate −1). Our `.sav`/programmed-flash is generated on the user's machine from the
  user's own disc — no distribution difference.
- **Lineage:** CPS3 is NOT console-derived (bespoke Capcom **SH-2** arcade board) → that's *why*
  it's a native `_Arcade` core with no console framework to inherit. The 573 **is** PS1-derived
  (one of the console-based arcade boards: Namco System 11/12 = PS1, Sega ST-V = Saturn, Naomi =
  Dreamcast). We inherited the console **mount plumbing** but **not a CD drive** — Konami swapped
  the PS1 CD block for a standard **ATAPI CR-589**, which we built ourselves (the ddrsbm work).

Sources (CPS3 launch + MiSTer CD handling):
- https://www.timeextension.com/news/2026/06/fpga-gaming-history-is-being-made-capcom-cps3-core-hits-mister-today
- https://mister-devel.github.io/MkDocs_MiSTer/basics/cd/
- https://mister-devel.github.io/MkDocs_MiSTer/developer/mra/

---

## Next steps (pick up here)
1. (If Frank wants the menu launch validated) de-confounded powyakex capture on the deployed
   Jun 25 rbf → an objective frame number → confirm it boots past the flash check today.
2. (Optional packaging cleanup) author `_Arcade` `.mra` files for the games that can support it
   (flash-only / pre-baked install image) so they appear in the arcade list. powyakex stays
   `.mgl` (true run-from-CD).
3. The active milestone remains the ddrsbm BOOT CHECK / ATAPI completion-IRQ race — unchanged by
   this session. See `docs/2026-06-25-ddrsbm-identify-irq-race-handoff.md`.
