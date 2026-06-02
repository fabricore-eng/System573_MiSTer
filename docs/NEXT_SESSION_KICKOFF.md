# Next-session kickoff

**How to launch:** start a new session, enable **ultracode** (`/effort` → ultracode),
then paste the *Mission* below (or this whole file). Optionally wrap with `/loop`
(no interval) as a safety net so the harness re-wakes it if it ever stalls.

---

## Mission

Finish the Konami System 573 MiSTer FPGA core — autonomously, to completion. Take it
from "peripherals done + dependencies vendored" to a legit, fully working MiSTerFPGA
core that boots and plays the real game library with correct video, audio, inputs and
saves, verified in full-system simulation AND on real hardware.

### Operating mode
- Ultracode is on: orchestrate with the Workflow tool by default. Go WIDE — fan out
  parallel agents to research, design competing approaches, implement, and
  ADVERSARIALLY verify. Never trust a single "it works": confirm with independent
  agents, diverse lenses, loop-until-dry bug hunts. Token cost is irrelevant;
  correctness and completeness are everything.
- Work CONTINUOUSLY. Drive each phase to its gate, land the PR, immediately start the
  next. Do NOT end your turn to ask whether to continue, and do NOT ask for
  confirmation on routine work. The ONLY reasons to stop: (1) the whole core is
  complete and verified per *Definition of done*, or (2) a hard blocker you have
  exhausted every conceivable fix for — and even then, make progress on everything
  else first, document it precisely, and keep the rest moving.

### Authority (all pre-approved — never pause for permission)
- Read/write code, install tools, run sims and builds.
- Full git: branch, push, open PRs, review, and merge your own PRs (see *PR
  discipline*). Keep `main` green.
- Build the bitstream (see *Hardware build path*) and load/test on the physical MiSTer
  over `ssh mister` (192.168.1.40); pull screenshots back and LOOK at them yourself.

### PR discipline (build an auditable history of PRs + reviews)
- One PR per phase or coherent unit of work. For EVERY PR, before merging, run an
  **adversarial review**: fan out parallel reviewer agents with distinct lenses —
  correctness/logic bugs, RTL timing & synthesis-safety, security-device & protocol
  accuracy vs MAME, sim-vs-hardware parity, MiSTer conventions, and test coverage.
  Post findings as review comments on the PR (use `gh pr comment` / review API).
- Fix every confirmed must-fix issue, push, and RE-review. **Loop review→fix until a
  review pass finds no confirmed must-fix issues** (cap ~5 rounds; if still not clean,
  document the residual and proceed only if it's non-blocking). Then **merge the PR
  yourself** and keep `main` green. The PR threads + review comments are the project's
  audit trail — make them substantive, not rubber stamps.

### The plan (follow it; keep it updated)
- `docs/EXECUTION_PLAN.md` — master phased plan (1–11, each Build/Verify-gate/Hardware).
- `docs/PHASE1_PSX.md` — PSX integration detail. `docs/DEPENDENCIES.md` — pins,
  toolchain, exact build-wiring recipe. Also `docs/ROADMAP.md`, `ARCHITECTURE.md`,
  `MEMORY_MAP.md`, `dumps/README.md`. Read your memory files. Keep `ROADMAP.md`
  checkboxes current; maintain `docs/COMPAT.md` as you bring titles up.

### Current state (don't re-derive — updated 2026-06-02)
**Phases 1 & 2 are DONE and merged to `main` (7 reviewed PRs, #5–#10); the Konami BIOS
executes on the integrated PSX+573 core in simulation and reaches main init.**
- i-cache fixes `psx_patches/` 0004 (redirect) + 0005 (BIOS-uncached) are MERGED; the
  18E (H8/3644) self-test fix (`rtl/s573_io.v`, PR #16) is MERGED. On real hardware the
  BIOS now boots **past the color bars** (which were an i-cache crash) to the GX700
  power-on self-test, parked at the CDR gate.

Read
`sim/system573/README.md`, `docs/PHASE1_PSX.md`, and project memory (`MEMORY.md` →
`phase1-2-integration-done`, `sim-toolchain-verdict`) for the precise verified state.
- 20+ peripheral modules done; unit sim 19/19 green (`make -C sim`).
- Vendored: `psx/` (PSX_MiSTer submodule, pinned) + `sys/` (MiSTer framework snapshot).
- **Sim toolchain reality:** the PSX core is **VHDL-2008 → Verilator CANNOT sim it**;
  **NVC** (`brew install nvc`) is the sim. No open-source tool co-sims VHDL+Verilog, so the
  573 fabric is verified in iverilog and the full system via the NVC harness + a VHDL EXP1
  responder (later: NVC↔Verilator FFI, or hardware). chdman (rom-tools); bsdtar reads `.7z`.
- **Phase 1 (PSX integration) — done:** EXP1 widened to a full 16-bit master + IRQ10 inside
  `psx/` as **`psx_patches/`** (the submodule pin never moves; `tools/apply_psx_patches.sh`
  re-applies). 573 fabric `exp1_rdata` is registered to match the PSX bus contract.
  `sim/nvc/elaborate.sh` is the reproducible "patched core elaborates" gate. NOTE: `rtl/
  emu.sv` still instantiates `ps1_stub` — wiring the real `psx_mister` into `emu.sv` for the
  `.rbf` is **Phase 4**, not done yet.
- **Phase 2 (sim harness) — done:** `sim/system573/run.sh` runs the BIOS under NVC.
  `FAST_RAMTEST`/`TURBO` accelerators + CPU PC tap + I/O tap. **Verified (clean 150 ms run):
  BIOS → main init `0x1FC05504` → GPU init (GPUSTAT poll resolves) → grinding a large
  uncached BIOS→RAM copy.** Framebuffer still black (no draw yet).
- **Phase 3 — done on hardware:** the boot reaches the GX700 power-on self-test on real
  silicon (color bars were an i-cache crash, fixed). Current frontier is the **CDR (CD-ROM)
  gate** in the sequential POST, plus the hyperbbc flash-load path (docs/FLASH_LOAD_PLAN.md).
  **PROCESS LESSON:** run the NVC harness SINGLE-WRITER to `build/` — a concurrent run
  clobbering `build/` once produced corrupted traces and an overclaim (caught in review).
- Dumps in `dumps/` (git-ignored): BIOS in `dumps/bios/` (incl. `700a01(gchgchmp).22g` — the
  game-in-BIOS that boots with NO CD/security; the current harness target), Redump discs, and
  `dumps/mame573/` carts + disc CHDs + `k573dio`/`k573msu` ROMs. Salaryman Champ (`salarymc`)
  = a clean plain CD + X76F100 first-game target. See `dumps/README.md`.
- Board reachable: `ssh mister` works (`local/mister.env`). Builder = **slave1** (Dell
  OptiPlex 7050, Ubuntu 26.04, `ssh slave1`); the Mac Colima VM was deleted (fallback-only).

### Verification ladder (self-verify every step — you have eyes, use PNGs)
1. **Unit sim** (iverilog): keep 19/19 green; add tests for new RTL.
2. **Full-system NVC sim** — the workhorse (CORRECTION: the PSX core is VHDL so this is
   **NVC, not Verilator**; that plan assumption was wrong). The harness EXISTS:
   `sim/system573/` (run via `sim/system573/run.sh [stop-time] [ram8mb]`) — PSX core +
   BIOS + a VHDL EXP1 responder, dumping the GPU framebuffer to `.gra` (→ PNG via
   `tools/gra2png.py`) + CPU PC / EXP1 / I/O traces. `tools/check_boot.py` (milestone gating)
   is still TODO. Compare PNGs against MAME `ksys573`. Use `chdman` to
   turn `dumps/mame573/*/<disc>.chd` into sectors for the ATAPI model.
3. **Hardware**: build the `.rbf` (below), scp to the MiSTer, load, screenshot back,
   LOOK; poll a debug status block. Build `tools/mister_{load,shot,dbg}.sh`.

### Hardware build path (native Quartus 17.0 on slave1)
- The `.rbf` needs x86-64 Quartus Prime Lite 17.0.x (Cyclone V, to match `pll_q17`).
  Build it on **slave1** (Dell OptiPlex 7050, Ubuntu 26.04, `ssh slave1`), which runs
  Quartus natively: `quartus_sh --flow compile Konami_System_573` →
  `output_files/Konami_System_573.rbf`. The Mac Colima/Docker recipe in
  `docs/DEPENDENCIES.md` is fallback-only (that VM was deleted).
  * Build headless: `quartus_sh --flow compile Konami_System_573` →
    `output_files/Konami_System_573.rbf` (after the DEPENDENCIES.md `.qsf`/`.qip`
    wiring: TOP_LEVEL_ENTITY sys_top, `source sys/sys.tcl`, nested `psx/rtl/*.qip`).
- Builds are SLOW and RAM-hungry: iterate functionality in the NVC sim;
  run the Quartus build only at phase gates, not per change.
- If the Quartus image/installer isn't fully staged (Intel gates the installer behind a
  login), DO NOT BLOCK: keep doing ALL sim-based development + verification (that covers
  functional completeness), stage the build, and flag "need Quartus Lite 17.0.x
  installer in `local/`" as a single non-blocking note. Resume the build when available.
- Once a `.rbf` exists: scp to `/media/fat/_Arcade` (per `local/mister.env`), load,
  screenshot, inspect.

### Definition of done (all of it)
- The targeted library boots attract → in-game → save/reload with correct video, audio
  and inputs, across all security types (X76F100/F041/ZS01), the BEMANI MP3 path, and
  analog I/O — validated in full-system sim AND, wherever a `.rbf` has been built, on
  the physical MiSTer via screenshots you've inspected.
- It is a legit MiSTer core: `sys_top` top, builds a `.rbf`, OSD/config/inputs wired,
  loads on the DE10-Nano.
- `docs/COMPAT.md` tracks every title; `ROADMAP.md` fully checked; all merged to `main`
  green via reviewed PRs.

### When you'd otherwise pause
Decide and proceed with the best reversible default, document the assumption, keep
going. Missing dump → name the exact file, proceed with everything that doesn't need it.
Scope-fork (e.g. Phase 9 MP3 decode approach) → pick the most viable path per the plan,
note it, proceed. Do NOT check in for approval. Run to completion.
