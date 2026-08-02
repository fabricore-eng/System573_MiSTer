# RESULT — ddrsbm gates 2+3 CLEARED on silicon: Solo strap + real flash ERASE; install is MAME-golden-exact (2026-07-02)

Executes §6 of `docs/2026-07-01-ddrsbm-dio-i2c-result.md`. Memory:
`[[fabricore-573-digital-bringup]]`. Build `f92fc08` (rbf md5 `f4fb784a`, on de10).

## 1. HEADLINE

ddrsbm now **erases and installs itself to flash on silicon, byte-perfectly**:

- **Gate 2 (Solo cab strap) CLEARED** — new OSD option `O[100] "573 Cabinet"`;
  with the strap set via a headless CFG poke, the boot chain passed
  `=SYSTEM UNIT ERROR=` to the INITIALIZE prompt with **zero input injection**.
- **Gate 3 (flash ERASE) CLEARED** — real JEDEC erase on the SDRAM-backed flash;
  no ERASE TIMEOUT; the installer ran to `FLASH-ROM INITIALIZE COMPLETE`, and the
  auto-saved 16 MB flash image is **md5-identical to a deterministic MAME golden
  install**: `82243fe3121cb23e97fec37b9ed0b8ef` (the strongest install-correctness
  number possible — exact byte equality over 15.35 MB of non-FF content).
- **Gate 4 found (expected — DDR plan P4 territory)**: the post-install boot runs
  the game's POST and fails **`MEMORY CHECK  22H BAD / 22J BAD / 22G BAD`**
  (`local/dio_verify_v3_memcheck.png`) — the three RAM chips on the k573dio
  digital I/O board. The MP3/DIO RAM datapath is the next observe-first target.
- **Regressions on this build**: powyakex boots to title/attract
  (`local/regress_powyakex_t120.png`, motion 62–64% frame-to-frame, luma
  1.9→84→40); hyperbbc: see §5.

## 2. FIX A — Solo cabinet strap (emu.sv, commit 53c9ee6)

- CONF_STR `"O[100],573 Cabinet,Standard,DDR Solo;"` (default Standard — a
  grounded P2-START auto-starts P2 in 2P games); `solo_cab = status[100]`;
  `p2_ctrl[7] = ~(joy2[9] | solo_cab)` (emu.sv — only the [7] term changed).
- **Headless set path (THE recorded method)**: the .mgl's
  `<setname>System573</setname>` makes Main read
  `/media/fat/config/System573.CFG` = 16 raw LE bytes of the 128-bit status;
  bit N = byte N/8, mask 1<<(N%8). Format proven empirically: the board's `.cd`
  snapshot differs from baseline in exactly byte 11 bit 5 = status[93]
  (Boot Device). So:
  `Solo ON:  printf '\x10' | dd of=/media/fat/config/System573.CFG bs=1 seek=12 count=1 conv=notrunc`
  (`\x00` to clear). On FAT → survives the warm reboot; poke any time before
  `load_core`. OSD-nav inject remains the documented-unreliable fallback.
- Strap left CLEARED at end of session (regressions need it off).

## 3. FIX B — real JEDEC ERASE on the SDRAM-backed flash (commit f92fc08)

Observe-first inputs (3-agent workflow, all high-confidence, adversarially
review-checked before the build):
- **Installer disasm** (`local/ddrsbm_psx_exe.bin`, capstone): erase driver
  0x800a0508; **sector erase only** (0x30; chip erase 0x10 never used); 128 KB
  sectors, same sector issued to all 4 banks back-to-back; poll = **DQ7
  data-polling** ((read^0xFFFF)&0x8080==0 done) + DQ5 (0x2020) error check, **no
  DQ6**; timeout = **121 VBlanks (~2 s) per sector-group**; autoselect ID check
  (0x0404/0xADAD) re-run on bank N+1 while bank N erases; after DQ7, a **full
  64K-halfword read-verify of 0xFFFF** per bank. Erase-wait primitive 0x8009f044.
- **MAME 29F016A oracle** (intelfsh.cpp): during erase EVERY read of the busy
  chip returns status 0x08^=0x44 per read (DQ7=0, DQ6+DQ2 toggle, DQ3=1, DQ5=0);
  writes to a busy chip ignored; array memset to 0xFF at command time + 1 s
  timer; maker==Fujitsu exception returns status at ANY address.

Implementation (all inside `rtl/s573_flash.v` g_sdram + two strobes from
`rtl/flash_nor.v`; **zero new emu.sv plumbing**):
- `flash_nor` exports `erase_now`/`erase_chip` (mirrors `prog_now`; its addr port
  is 16-bit, so the parent captures the sector from `win_addr[20:16]`).
- Per-bank (chip-pair) busy state; reads of a busy bank return the AMD status
  word on both x8 lanes, never stall, never line-fill; writes to a busy pair
  are ignored (sector-batching drop warns in sim).
- Background walker streams 0xFFFF over the region via the **existing flash_wr
  ch3 port** (~ms per 128 KB region vs the ~2 s budget); busy drops only on the
  final word's SDRAM ack — completion is real committed data, never a faked
  status ([[no-mask-fault-with-fake-data]]).
- NOR program now latches (`prog_pend`) and **outranks** the walker on the shared
  port; `prog_pend` (not `flash_wr_busy`) gates reads/fills, so idle banks stay
  live for the installer's interleaved ID checks mid-walk.
- Program stays **OVERWRITE** (re-examined per plan): 0x00-filled blanks/.savs +
  hypbbc2p's program-without-erase installer make the faithful NOR-AND a
  corruption. Both install styles reach the correct image with overwrite.
- RED/GREEN: `make S573_FLASH_ERASE_NOOP=1 s573_flash_erase` = RED with the
  exact silicon signature (DQ7 poll timeout); GREEN default. New
  `sim/tb_s573_flash_erase.v` drives the installer's exact shape incl. the
  4-bank back-to-back batch (added after adversarial review flagged the
  coverage gap), mid-walk ID checks, busy-bank program drop, bounds canaries,
  post-eviction persistence, scaled chip erase. Suite **36/36**;
  `S573_FLASH_OLD_AND` still RED. Review: 3 adversarial lanes, 3× READY, zero
  blocking.

## 4. THE MAME GOLDEN (new verification asset)

Background agent on dell produced a **deterministic golden install** while the
FPGA build compiled:
- md5 `82243fe3121cb23e97fec37b9ed0b8ef`; **two independent from-scratch MAME
  installs byte-identical**; boot/attract does NOT mutate flash (bookkeeping
  goes to the m48t58, a separate chip) → **exact equality expected, no
  legitimately-differing regions**.
- ddrsbm in MAME needs NO DIP change: blank flash + default DIP falls through
  to CD boot (matches our all-zeros-CFG behavior on silicon).
- Artifacts: dell `~/System573_MiSTer/local_golden/ddrsbm/` (golden .sav, raw
  nvram chips, `assemble_ddrsbm_golden.py` — interleave identical to
  `tools/pack_hyperbbc.py`, bank m,l,j,h at N*0x400000, even byte=.31x
  odd=.27x — and the install-driving `ddrsbm_install.lua`); Mac
  `local/ddrsbm_golden_md5.txt`.
- **Our core's post-install .sav matched it exactly, first try.**

## 5. SILICON RUNS (build f92fc08, rbf f4fb784a, de10; de-confounded)

- Verify (recipe `local/tracedig/dio_verify_v3_eraseinstall.sh`): reboot →
  uptime 19 s → CFG strap poke → ONE load_core → prompt with NO inject → TEST
  (the Human pressed the physical TEST on seeing the prompt; keyboard-'t' path
  also verified last session) → install visible at 35% by t=120
  (`local/dio_verify_v3_t120.png`) → complete → flash auto-save → **.sav md5 ==
  golden** → post-install reboot → `MEMORY CHECK 22G/22H/22J BAD` (gate 4).
- powyakex regression: PASS (title/attract, motion numbers §1).
- hyperbbc regression: PASS (attract demo running — `local/regress_hyperbbc_t120.png`,
  motion 64–68% frame-to-frame, luma 1.6→52→50; uptime-18s ONE-load_core run).
- frame_diff on text screens remains geometry-confounded vs MAME-native
  captures (2–3% / SSIM ~0.94 both for true matches and different-text screens
  of the same layout) — the golden md5 and same-pipeline motion numbers carried
  the verdicts tonight.

## 6. GOTCHA FOUND — Main's slot-4 remembered mount (cost: one save landed wrong)

`ddrsbm.sav` did not exist, and Main did NOT auto-create the .mgl's
`<file type="s" index="4" path=".../ddrsbm.sav">` — it silently kept the
REMEMBERED slot-4 mount (`config/System573.s4`), which still pointed at
`hypbbc2p.sav`. The install's auto-save therefore wrote a byte-perfect ddrsbm
image into `hypbbc2p.sav`. Recovered (Human-approved): golden image copied to
`ddrsbm.sav`; `hypbbc2p.sav` restored from `.bak` (back to its own MAME-golden
md5 `1d022a10`). **Lesson: pre-create the .sav file (or verify the S4 binding)
before any install run; an .mgl s-slot path is NOT authoritative on this Main
version when the file is missing.**

## 7. NEXT (gate 4 — k573dio RAM, DDR plan P4)

Observe first: what are 22G/22H/22J (MAME k573dio RAM devices + the game's
POST disasm — which registers/addresses does the check write/read through the
0x1f6400xx window), then de-stub the DIO RAM path (likely SDRAM- or BRAM-backed
per size). The MP3 decode chain (HPS minimp3 + PCM transport) remains the plan
of record after RAM. Regression owed on the NEXT build: ddrsbm re-install run
(the recipe + golden md5 make it one command now).

## 8. STATE OF THE WORLD (end of session)

- Git `feat-digital-bringup` @ f92fc08 (+ this doc), pushed to private origin.
  Public untouched. dell tree at f92fc08 (launcher-managed).
- de10: rbf `f4fb784a` at `_Console/Konami_System_573.rbf`; strap byte CLEARED;
  saves: `ddrsbm.sav` = golden install, `hypbbc2p.sav` = restored original;
  devlock released at session close.
- Suite 36/36. New assets: golden md5 + assembly/lua on dell, v3 verify recipe,
  regress_boot_v1.sh runner.
