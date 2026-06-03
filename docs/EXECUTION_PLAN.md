# System 573 core — execution plan to full game compatibility

This is the ordered plan to drive the core to full game compatibility. Read §1–§4
once to set up; §5 onward is the ordered work.

Status anchor: the peripheral layer is **done and green** (19 modules, `make -C
sim`). What remains is the PlayStation core integration and everything that rides
on it. See also [`PHASE1_PSX.md`](PHASE1_PSX.md) (PSX integration detail),
[`../dumps/README.md`](../dumps/README.md) (the dump manifest), and
[`ROADMAP.md`](ROADMAP.md).

Current state (2026-06-02): the CPU i-cache crash that produced the color bars is
**fixed** (`psx_patches/` 0004/0005), the 18E (H8/3644) I/O-MCU self-test fix is
**merged** (`rtl/s573_io.v`, PR #16), and the BIOS now boots to the GX700 power-on
self-test on real hardware (next gate: the CDR / CD-ROM check). Builds run on x86-64
Linux with Quartus Prime Lite 17.0.x (the `raetro/quartus:17.0` Docker image works).

---

## 1. Verification model

Verification uses a three-rung ladder, top rung preferred because it's the most
observable and scriptable:

1. **Unit sim** (`make -C sim`, iverilog) — already the suite; stays green always.
2. **Full-system sim** (NVC — the PSX core is VHDL-2008, which Verilator cannot
   consume) — the workhorse. PSX core + this fabric + the real BIOS/CD/security
   dumps, booting for real, with **total observability**:
   - dump the GPU framebuffer to a **PNG** that can be opened and inspected,
   - trace the CPU (PC, BIOS milestones), peripheral accesses, IRQs,
   - assert on known good states ("BIOS POST reached", "CD boot sector read").
3. **Hardware** (the MiSTer board) — final confirmation, also self-verifiable:
   - **MiSTer screenshot** (standard scaler PNG) `scp`'d back and inspected, to
     confirm video,
   - a **debug status block** the core exposes and an HPS-side script polls,
   - audio captured to a file where feasible.

Each phase's sim gate must be green before moving on; hardware builds/loads/readbacks
run at the marked gates. **Steps that need maintainer input:**
 - a required **dump is missing** (named in the build/sim output),
 - **Quartus or the MiSTer is unreachable** (build/load can't run),
 - a check is **irreducibly subjective** (e.g. "does the dance chart feel right"),
 - a decision would **change scope** (new dependency, a design fork).

---

## 2. Toolchain & environment

| Tool | Use | How it's obtained |
|------|-----|-------------------|
| iverilog | unit sim | apt (session-start hook already installs it) |
| **NVC** (VHDL-2008 sim; the PSX core is VHDL, so Verilator cannot consume it) | full-system sim | `brew install nvc` (apt on Ubuntu) |
| zlib/libpng (or stb_image_write) | dump sim frames to PNG | apt / vendored header |
| **Quartus Prime Lite 17.0.x** (matches `pll_q17`; Cyclone V) | build the `.rbf` for hardware | any x86-64 Linux host with Quartus 17.0.x (the `raetro/quartus:17.0` Docker image works) |
| ssh/scp | load core + read back from the MiSTer | present; needs the connection config |
| chdman / bin-cue tools | read CD images | apt (`mame-tools`) or vendored |

**MiSTer connection:** copy `local/mister.env.example` to `local/mister.env` and
fill it in (IP, user, SD path, SSH key). The deploy scripts (`tools/mister_*.sh`)
read that file to reach the board. `local/` is git-ignored.

If Quartus is unavailable, RTL + full-system sim development can proceed and the
hardware build can be staged for a CI runner or any x86-64 Quartus host.

---

## 3. Observability harness (built early, in Phase 2)

- `sim/system573/` — an NVC harness that wires PSX_MiSTer + `system573_top`, loads
  the dumps, runs N cycles, and on exit writes the GPU framebuffer (`.gra` → PNG via
  `tools/gra2png.py`) + CPU PC / EXP1 / I/O traces. (The PSX core is VHDL, so this is
  NVC, not Verilator.)
- `tools/check_boot.py` — scans a trace for milestone markers and exits non-zero
  if a gate isn't met (so phases self-gate).
- On hardware: `tools/mister_load.sh` (scp the `.rbf`, trigger load),
  `tools/mister_shot.sh` (trigger a screenshot, pull the PNG), `tools/mister_dbg.sh`
  (poll the debug status block). Built in Phase 4.

---

## 4. Dumps

The full, ordered manifest with exact paths lives in
[`../dumps/README.md`](../dumps/README.md). The short version of what's needed and
when:

| When first needed | Dump | Path |
|---|---|---|
| Phase 3 (BIOS POST) | 573 BIOS (512 KB) | `dumps/bios/573.bin` |
| Phase 3 | a security cart's data + DS2401 (any installed cart the BIOS accepts) | `dumps/bios/cart/…` |
| Phase 5 (first game) | game CD image | `dumps/<game>/cd.chd` (or `.bin`+`.cue`) |
| Phase 5 | that game's security cart (X76F100) + DS2401 | `dumps/<game>/security/…` |
| Phase 5 | M48T58 RTC/NVRAM (if the game needs a seeded one) | `dumps/<game>/m48t58.bin` |
| Phase 7 | onboard flash image / PCMCIA card (install-type games) | `dumps/<game>/flash.bin`, `pccard.bin` |
| Phase 9 | BEMANI titles: DIO board DS2401 + the game's MP3 data is on the CD | `dumps/<game>/dio_ds2401.bin` |

Each maps to the MAME `ksys573` set for the chosen game (easiest single source).
Each phase checks for the file it needs before running; a missing dump is named in
the build/sim output.

---

## 5. The phased plan

Each phase: **Goal · Build · Verify (gate) · Hardware**. Drive each to its gate,
commit, then continue.

### Phase 1 — Vendor the PSX core + EXP1 adapter
- **Build:** add `MiSTer-devel/PSX_MiSTer` as a submodule under `psx/`; write
  `rtl/exp1_adapter.v` translating the PSX CPU's `0x1f000000`-page accesses into
  `system573_top`'s `exp1_*` contract (lane-steer 8/16/32-bit, wait-states); swap
  the 512 KB Konami BIOS in; apply the **4 MB main RAM / 2 MB VRAM** edits as small
  isolated diffs.
- **Verify:** unit suite stays green; the adapter has its own iverilog testbench
  (drive PSX-style accesses, check EXP1 reads/writes land on the right peripheral).
- **Hardware:** none yet.

### Phase 2 — Full-system sim harness + observability
- **Build:** §3 harness — NVC top, framebuffer dump, trace, `check_boot.py`.
  Extend the session-start hook to install NVC and (when dumps exist) run a
  smoke sim. (NVC, not Verilator — the PSX core is VHDL.)
- **Verify:** harness elaborates and runs the PSX core executing from the Konami
  BIOS for a few frames without the fabric faulting; produces a PNG + trace.
- **Gate:** a frame PNG is produced and the trace shows the CPU fetching BIOS.

### Phase 3 — BIOS POST in simulation  ← first dumps needed
- **Build:** load `dumps/bios/573.bin` + a security cart; fix whatever the BIOS
  pokes (watchdog cadence, RTC, ASIC I/O, security handshake) until it POSTs.
- **Verify:** trace shows POST reached; the **framebuffer PNG shows the 573 boot
  screen** (compare against MAME's output of the same BIOS). `check_boot.py`
  gates on the POST marker.
- **Gate:** PNG visibly matches the BIOS boot screen; security check passes.

### Phase 4 — BIOS POST on hardware
- **Build:** `tools/mister_*` scripts; wire MiSTer screenshot + a debug status
  block into `emu.sv`; produce a `.rbf` (Quartus — see §9).
- **Verify:** `mister_load.sh` loads it; `mister_shot.sh` pulls a PNG that confirms
  the boot screen; `mister_dbg.sh` confirms the POST marker.
- **Gate:** hardware screenshot matches the sim boot screen.

### Phase 5 — First game boots (target: a plain, non-DIO title)
- **Target:** **Hyper/Great Bishi Bashi Champ** or **Konami 80's Arcade Gallery**
  — SPU audio (no MP3), JAMMA buttons, X76F100 security, CD boot. (Music games are
  deferred to Phase 9 precisely because of MP3 decode.)
- **Build:** load `dumps/<game>/cd.chd` + security; bring up the **ATAPI CD read
  path end-to-end** (BIOS reads boot sectors → game code runs); map JAMMA inputs
  in `emu.sv` to MiSTer `joystick`/keyboard.
- **Verify:** sim PNG shows the game's title/attract; CPU runs game code; inputs
  register. Then hardware screenshot confirms; a maintainer confirms it's playable.
- **Gate:** the game reaches attract/playable in sim and on hardware.

### Phase 6 — Security variants
- **Build:** prove `x76f041` and `zs01` titles authenticate through the fabric
  (the devices are tested; this is wiring + per-cart data from dumps).
- **Verify:** one X76F041 game and one ZS01 game pass their security check in sim.
- **Gate:** both variant games get past security to boot.

### Phase 7 — Flash / PCMCIA install-type games + saves
- **Build:** back `s573_flash`/`flash_nor` and the PCMCIA banks with **DDR3**;
  HPS save/restore of flash + NVRAM + security state to SD; handle install carts.
- **Verify:** an install-type game installs to flash and re-boots from it across a
  power cycle (sim: persist the backing; hardware: SD save survives reload).
- **Gate:** install persists and the game boots from flash.

### Phase 8 — CD timing + DMA channel 5
- **Build:** wire **DMA ch5** for ATAPI block transfers and IRQ10; tune CD access
  timing the BIOS/loader expect (vs. the current PIO fallback).
- **Verify:** large CD reads complete via DMA; load times sane; no PIO stalls.
- **Gate:** a CD-heavy game loads cleanly via DMA.

### Phase 9 — The BEMANI / MP3 path (DDR & friends)  ← the hard one
- **Problem:** these need **MP3 → PCM decode** (the MAS3507D), which is not a small
  RTL job. Options, in order: (a) **HPS-assisted decode** — stream the
  descrambled MP3 (already produced by `k573_mp3stream`) to the ARM, decode there,
  feed PCM back (MiSTer supports HPS audio helpers); (b) integrate an existing
  open MP3-decoder core if one fits the Cyclone V; (c) RTL decode (last resort).
- **Build:** whichever path (a) proves viable; finish the DIO board video/light
  outputs and timing.
- **Verify:** a DDR song plays in-sync audio in sim (PCM compare) and on hardware.
- **Gate:** one BEMANI title plays a song with correct audio + steps. **This is the
  most likely place a design decision (the decode approach) needs maintainer input.**

### Phase 10 — Inputs, OSD, per-game config, analog/JVS
- **Build:** MiSTer OSD menu (video options, dip switches, region), input mapping
  incl. dance-pad/JVS where applicable, the analog I/O (`adc0838`) board path.
- **Verify:** controls + OSD work across a few games; analog title reads its pots.
- **Gate:** input/OSD solid on the test set.

### Phase 11 — Compatibility sweep to "full"
- **Build:** iterate per-game across the library: timing quirks, per-title security
  data, video modes, save formats. Maintain a `docs/COMPAT.md` matrix.
- **Verify:** each title to attract → in-game → save, screenshot-checked; the
  matrix tracks pass/fail/known-issue. Real-time runs happen on hardware (sim is
  too slow for a full sweep); scripted screenshot checks flag regressions.
- **Done when:** the targeted library boots and plays with correct A/V + saves.

---

## 6. Ordered files created / modified

Roughly the order they appear:

1. `psx/` (submodule), `rtl/exp1_adapter.v`, `sim/tb_exp1_adapter.v`, BIOS/RAM/VRAM
   edits in the PSX core (isolated patch set), `Konami_System_573.qsf`/`files.qip`
   updates. *(P1)*
2. `sim/system573/` (NVC harness + VHDL EXP1 responder), `tools/check_boot.py`,
   `.claude/hooks/session-start.sh` (add NVC), `tools/gra2png.py`. *(P2)*
3. boot-bringup fixes across `rtl/s573_io.v`, `rtl/m48t58.v`, `rtl/watchdog.v`,
   `rtl/s573_seccart.v` as the BIOS demands. *(P3)*
4. `rtl/emu.sv` (MiSTer video/audio/inputs, screenshot, debug status block),
   `tools/mister_load.sh`, `tools/mister_shot.sh`, `tools/mister_dbg.sh`. *(P4)*
5. `rtl/emu.sv` input mapping; ATAPI/CD glue in `rtl/atapi.v` + `system573_top`. *(P5)*
6. per-variant wiring/tests for `x76f041`/`zs01` games. *(P6)*
7. DDR3 backing for `s573_flash`/PCMCIA + HPS save/restore (`rtl/emu.sv`,
   HPS-side glue). *(P7)*
8. DMA ch5 + IRQ10 wiring (PSX DMA ↔ `atapi`). *(P8)*
9. MP3 decode path (HPS helper or decoder core) + DIO finalization. *(P9)*
10. OSD/config/input/`adc0838` analog path. *(P10)*
11. `docs/COMPAT.md` + per-game fixes. *(P11)*

The full **dump order** is the table in §4 / [`../dumps/README.md`](../dumps/README.md).

---

## 7. Hardware test loop (per build, Phase 4 on)

```
build .rbf (Quartus)  →  tools/mister_load.sh  →  run/boot
                      →  tools/mister_shot.sh   →  open PNG, check video
                      →  tools/mister_dbg.sh    →  check the debug markers
                      →  (audio capture where feasible)
```
The screenshot/markers gate the loop; a build only needs maintainer review when they
say something is wrong that can't be resolved from the trace, or when only eyes/ears
can judge.

---

## 8. Where maintainer input is needed

- **Dumps** — copyrighted BIOS/CD/security data can't be obtained automatically; place
  them per `dumps/README.md`. Work proceeds the instant they're present.
- **Quartus / the physical MiSTer** — if a session can't run Quartus or reach the
  board, RTL + sim proceed and the hardware step is staged.
- **The MP3 decode decision (Phase 9)** — needs a design call (see Phase 9).
- **Final subjective QA** — "does it play/feel/sound right" on a few titles.
