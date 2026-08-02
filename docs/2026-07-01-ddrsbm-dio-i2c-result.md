# RESULT — k573dio MAS3507D I2C de-stub: DIO gate CLEARED on silicon; next gates found (2026-07-01/02)

Executes `docs/2026-07-01-k573dio-i2c-destub-plan.md` (A0–A5). Read together with the A0
deliverable `docs/2026-07-01-ddrsbm-dio-i2c-transactions.md`. Memory:
`[[fabricore-573-digital-bringup]]`. **Next session: see §6 (plan) — a ready handoff.**

## 1. HEADLINE

The ddrsbm BOOT CHECK freeze is **FIXED on silicon**: build `fe0c406` (rbf md5
`419f31c3`, on de10) clears the MAS3507D I2C gate — the game runs its whole boot chain
and, for the first time on hardware, reaches screens *beyond* the freeze:

- unmodified boot → `=SYSTEM UNIT ERROR= THIS CD-ROM CANNOT BOOT ON THIS SYSTEM`
  (a NEW, deliberate game decision — not a hang), root-caused to the **DDR Solo cabinet
  strap** (§3), then
- with the strap faked via input-inject → **`GQ894 JAA / DO YOU WANT TO INITIALIZE
  FLASH-ROM?`** (the MAME-oracle target screen), and pressing TEST →
- `FLASH-ROM DEVICE ERROR / ERASE TIMEOUT` — the **known-latent flash-ERASE no-op**,
  now an active install blocker (§4).

Gate chain today: **I2C ✅ cleared → Solo strap ✅ root-caused+confirmed (fix designed)
→ flash ERASE ⏳ (fix designed, not implemented)**.

## 2. THE DE-STUB ITSELF (plan A0–A4)

- **A0**: transaction list derived (MAME 0.285 source + full-EXE capstone disasm),
  adversarially verified by two independent lanes (game-side: ALL claims re-derived from
  raw bytes and CONFIRMED; MAME-side: confirmed with 2 refinements). The boot gate is
  **ACK-only** — T1 `WRITE_MEM bank0 0x32f=0x00030` + T2 `RUN 0x0fcb`, 16 bytes, no
  read-back compare, no version/ID register (MAME has none). A read-only MAME DIO tap
  dynamically confirmed all 16 ACKs at f=207 and NO other 0x1f6400a0–cf reads in 90 s.
- **A1**: `rtl/mas3507d_i2c.v` (new minimal slave: START/STOP any-state, MSB-first
  rising-edge sampling, ACKs 0x3a/0x3b only, ACK-and-drop writes behind a DBG-off
  `$display`, 0x69-armed frame-count read = truthful zero, master-NACK honored, no clock
  stretch) + the 0xac endpoint in `rtl/k573dio.v` (host latches **reset HIGH** → pristine
  read 0x3000; read mux `{scl, sda_host & ~sda_pull}<<12`, DS2401-style wired-AND).
  `files.qip` updated.
- **A2**: `sim/tb_dio_i2c.v` drives the game's exact tap-verified bit-bang.
  **RED** = `make DIO_I2C_STUB=1 dio_i2c` reproduces the hang against the old stub;
  **GREEN** by default. Full suite 34/34 (incl. the previously-red `s573_io`, fixed
  separately in `3752b84` — stale tb expectation from bcaf9a4, MAME-verified).
- **A3**: commit `fe0c406`, hub-launcher build rc=0 in 34 min; fit 91% ALM / DSP 100%
  (known wall) / 39% BRAM. No SignalTap in this rbf.
- **A4** (de-confounded: devlock warm reboot → CORENAME=MENU → ONE load_core, uptime 19 s):
  - Run v1 (no input): t80/t120 frames = SYSTEM UNIT ERROR, stable.
    `frame_diff` vs the INITIALIZE oracle: 3.022% px differing / SSIM 0.9184 = MISMATCH
    (correct — it is not that screen). Frames `local/dio_verify_t80/85/120.png`.
  - Run v2 (P2-START held ~t29–139 via two virtual uinput pads): t130 frame = **the
    INITIALIZE FLASH-ROM prompt** (`local/dio_verify_v2_t130.png`), live-confirmed by the
    Human on stream+CRT. `frame_diff`: 2.421% / SSIM 0.9396 — still "MISMATCH" **only due
    to a geometry/scale confound** (720p letterboxed capture downscaled vs MAME-native
    320×240 shifts the text raster; see §5 lessons). Content read = exactly the oracle
    screen.
  - Injected TEST (keyboard 't' path) → install starts → `ERASE TIMEOUT`
    (`local/dio_verify_v2_posttest.png`).
  - **Regression boots (powyakex, hyperbbc) NOT run this session** — carry into the next
    build's verify pass. Risk is low (change touches only DIO reg 0xac + a new leaf
    module) but the protocol wants the boots.
- Why "I2C cleared" is airtight without a PC probe: the old spin is **unbounded**
  (counterless — verified in disasm) and only exits when the SCL readback works; and the
  solo strap state did not change between builds, so if the solo check preceded the I2C
  init, the OLD core would have shown SYSTEM UNIT ERROR instead of freezing. It froze.
  New core reaches the error/prompt → the I2C init passed. (Plus MAME-oracle + RED/GREEN
  sim equivalence of the exact byte sequence.)

## 3. GATE 2 — the DDR Solo cabinet strap (root-caused + silicon-confirmed)

- Chain (from the CD's `PSX.EXE`, loads at `0x80010000`, byte-identical to our RAM dumps):
  `0x80019c4c: jal 0x800a0a34(a0=1); beqz → jal 0x800a3d3c` (SYSTEM UNIT ERROR,
  infinite redraw). `0x800a0a34` → `0x8009ad80` reads the JAMMA input regs
  `0x1f400004/6/8/c/e`, **inverts** them, packs halfwords; check = `buf16[1] & 0x80`
  = bit7 of `~[0x1f400008]` = **the P2-START line must read LOW (grounded)**.
- MAME ground truth: base konami573 `IN2` bit 0x80 = `IPT_START2` ACTIVE_LOW;
  `INPUT_PORTS_START(ddrsolo)` remaps exactly that bit to `IP_ACTIVE_HIGH, IPT_CUSTOM`
  = **constant 0** — the Solo cab has no P2; its start line is strapped to ground and the
  game senses the cab type through it.
- Our core: `p2_ctrl[7] = ~joy2[9]` (emu.sv:2137) — idle high → "standard 2-player cab"
  → rejection. Confirmed on silicon: holding P2 START (joystick 2 Start) through the
  check window produced the INITIALIZE prompt.
- The other `0x800a0a34(0)` call sites (0x80019d08/d34) test the **P1**-START line as a
  *wait-for-release* loop, not a second strap.
- **FIX (designed, not yet implemented)**: OSD toggle, default Standard:
  - CONF_STR (rtl/emu.sv, 573 block near O[93]..O[99]): `"O[100],573 Cabinet,Standard,DDR Solo;"`
  - `wire solo_cab = status[100];`
  - emu.sv:2137: `.p2_ctrl (~{joy2[9] | solo_cab, joy2[6], ...})` (only the [7] term changes).
  - Caveat: OSD config is per-CORE — Solo must be flipped per game session (grounded P2
    START would auto-start 2P games elsewhere). Future refinement: auto-strap from the
    loaded security-cassette ID (the core knows the .u1); note only, don't build blind.
- TEST button lore (cost us minutes): `test_btn = ~(joy[11] | key_test)` — **P1-only**
  joy bit OR **keyboard 'T'** (emu.sv:2074, player-independent). A virtual uinput pad
  hogs the P1 slot and demotes the human's controller (§5).

## 4. GATE 3 — flash ERASE no-op (known-latent, now active)

- After TEST at the prompt: `FLASH-ROM DEVICE ERROR / ERASE TIMEOUT`.
- Cause (documented in-code): `rtl/s573_flash.v:95` — on the SDRAM-backed 16 MB flash,
  **ERASE is a no-op** (program compensates by overwriting instead of NOR-ANDing).
  hypbbc2p installed anyway because its `.mgl` ships a pre-blanked (0xFF) flash and its
  installer doesn't verify erase. ddrsbm's installer erases then **polls for erased
  status** → never completes → timeout. (`rtl/flash_nor.v` — the sim-only model — already
  implements chip/sector erase and documents the JEDEC sequences at its header.)
- **FIX (designed, not implemented)**: implement erase on the SDRAM-backed path:
  - Accept the JEDEC chip-erase (…80…AA,55,10) and sector-erase (…80…AA,55,ADDR,30)
    sequences (decode already exists for the command state machine — see s573_flash.v
    around line 143).
  - An erase FSM: mark busy, run a background 0xFF-fill walker over the SDRAM backing
    (chip = whole 16 MB, sector = the addressed sector), and present **busy status per
    real NOR semantics while erasing** (DQ7 data-polling reads 0 until done, DQ6 toggles
    on consecutive reads — check WHICH one ddrsbm polls by disasm of the installer's
    erase-wait loop, or MAME `fujitsu_29f016a.cpp` as oracle; implement what the real
    chip does, no shortcuts — [[no-mask-fault-with-fake-data]]).
  - Interlock with s573_ch4_arb (the SAVE-read arbiter) — the walker is a new SDRAM
    writer on the same channel; reuse the flash_saver walker pattern.
  - RED/GREEN: extend `tb_s573_flash_sdram` (the suite already has the
    `S573_FLASH_OLD_AND=1` red/green convention): RED = erase-then-poll times out today;
    GREEN = poll completes and reads 0xFF.
  - After erase works, the "program must overwrite" compensation (s573_flash.v:97-300)
    should be re-examined — with real 0xFF erase, faithful NOR AND-programming can return
    (flash_nor.v documents the old behavior; keep the overwrite only if needed).

## 5. TOOLING LESSONS (this session)

- **MAME 0.285 write taps crash the emulation on ANY address class** (died f=207
  mid-instruction-pair on a DIO MMIO write tap) — not a RAM-specific disease.
  **Read-only taps are safe** (full 90 s run) and were sufficient. Safe variant: delete
  the `install_write_tap` block from `tools/trace/ddrsbm_dio_tap.lua`.
- **MiSTer `/tmp` is tmpfs** — anything pushed there dies with the warm reboot. Push
  tools AFTER the reboot (cost: one invalid verify run).
- **Virtual uinput devices hog the P1 slot** and demote the human's physical pad — that
  is also why "hitting test did nothing" for the Human mid-session. Destroy virtual pads
  promptly; keyboard-'T' TEST is player-independent.
- **frame_diff geometry confound on text screens**: a 1280×720 letterboxed capture
  downscaled to the MAME-native raster shifts glyph positions → per-pixel MISMATCH on a
  screen whose CONTENT matches. Numbers + a content read are complementary
  ([[look-before-calling-black]] family); consider `--crop-test` calibration or an
  OCR/text-anchor mode for the verify tooling.
- `wf_cockpit_progress.sh` usage: `<key> <journal> <total> <label>` (positional, journal
  path from the Workflow tool result). `with_progress.sh` lives in the HUB tools dir.

## 6. NEXT STEPS (the next session's plan)

1. **Fix A — Solo strap** (§3 design; trivial). Note: setting the OSD option headlessly =
   OSD-nav inject (`tools/mister_menu_nav.md`, mister_press key sequences) or a direct
   per-core config-file bit poke (`/media/fat/config/Konami_System_573.cfg`) — figure out
   ONE reliable path and record it.
2. **Fix B — flash ERASE** (§4 design; the real work). Observe FIRST: disasm the
   installer's erase-wait loop (the EXE is `local/ddrsbm_psx_exe.bin`, VA base
   0x80010000, capstone; find the erase command writes + the status poll) to pin DQ7 vs
   DQ6 vs read-verify semantics before writing RTL.
3. RED/GREEN both, full suite green, ONE build (#2 of the approved budget), then the
   de-confounded verify: reboot → MENU → load ddrsbm .mgl → set/confirm Solo strap →
   expect INITIALIZE prompt with NO inject → TEST → **install completes** → game reboots
   to attract (watch for: post-install reboot re-runs the solo check — the strap toggle
   covers it; and the MP3/DIO runtime may present the NEXT gate, e.g. the free-running
   0xcc counter or frame-count polling — that's DDR-plan P4 territory, observe first).
4. **Regression: powyakex + hyperbbc boots** (owed from this session too).
5. Close out: results doc, memory banner, private push, chat.

## 7. STATE OF THE WORLD (end of session)

- Git `feat-digital-bringup` @ this commit (results doc; prior: 3752b84 tb fix,
  fe0c406 de-stub). Pushed to private origin. Public untouched.
- dell: build tree on feat-digital-bringup (launcher-managed), build artifacts in
  `~/System573_MiSTer/output_files/` (rbf md5 419f31c3). `dumps/mame573/ddrsbm_ext/`
  now holds the extracted `894jaa02.{bin,cue,iso}` (kept — useful for the erase disasm).
- de10: new rbf DEPLOYED at `_Console/Konami_System_573.rbf` (md5 419f31c3), board
  parked at the ERASE TIMEOUT screen (harmless), devlock FREE.
- Local artifacts: `local/ddrsbm_psx_exe.bin` (the game EXE, 849920 B), verify frames
  `local/dio_verify_*.png` + JSONs, recipes `local/tracedig/dio_verify_v1.sh` (plain)
  and `dio_verify_v2_soloinject.sh` (strap-inject variant, push-after-reboot fixed).
- The stub-era SignalTap dbg branch `dbg-signaltap-atapi-wedge` (487f488) still exists
  for PC-snapshot needs — never merge it.
