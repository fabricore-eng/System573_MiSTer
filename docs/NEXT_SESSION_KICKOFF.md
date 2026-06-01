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

### Current state (don't re-derive)
- 20+ peripheral modules done; unit sim 19/19 green (`make -C sim`).
- Vendored: `psx/` (PSX_MiSTer submodule, pinned) + `sys/` (MiSTer framework snapshot).
  Toolchain: iverilog 13, verilator 5.048, chdman (rom-tools). bsdtar reads `.7z`.
- Dumps in `dumps/` (git-ignored): BIOS in `dumps/bios/` (incl.
  `700a01(gchgchmp).22g` — a game-in-BIOS that boots with NO CD/security; use it to
  bring up CPU+video first), 44 Redump discs, and `dumps/mame573/` = 43 game carts +
  33 disc CHDs + `k573dio`/`k573msu` device ROMs. Split carts into per-game device
  `.bin` at bring-up (`dumps/README.md`); pair each Redump disc with its matching
  `mame573` cart by game/region.
- `rtl/ps1_stub.v` is still the placeholder — replacing it via an EXP1 adapter is Phase 1.
- Board reachable: `ssh mister` works (`local/mister.env`). Builder = this Mac (below).

### Verification ladder (self-verify every step — you have eyes, use PNGs)
1. **Unit sim** (iverilog): keep 19/19 green; add tests for new RTL.
2. **Full-system Verilator sim** — the workhorse and primary iteration loop. Build the
   `sim/system/` harness EARLY (EXECUTION_PLAN §3): PSX core + `system573_top` + real
   BIOS/CD/cart dumps, dumping the GPU framebuffer to PNG + a CPU/IRQ/peripheral trace,
   with `tools/check_boot.py` gating on milestones (BIOS POST, CD boot sector, attract).
   Compare your PNGs against MAME `ksys573` output for the same title. Use `chdman` to
   turn `dumps/mame573/*/<disc>.chd` into sectors for the ATAPI model.
3. **Hardware**: build the `.rbf` (below), scp to the MiSTer, load, screenshot back,
   LOOK; poll a debug status block. Build `tools/mister_{load,shot,dbg}.sh`.

### Hardware build path (Quartus in x86 Docker on this Mac)
- The `.rbf` needs x86-64 Quartus Prime Lite (Cyclone V; 17.0.x to match `pll_q17`).
  The MiSTer's ARM CPU cannot build it. Run Quartus headless in an amd64 Linux
  container on this Apple-Silicon Mac. Colima is pre-staged for this (see
  `docs/DEPENDENCIES.md` / the Colima section) — prefer the Apple-Virtualization +
  Rosetta x86_64 path over plain qemu for speed.
  * Build headless: `quartus_sh --flow compile Konami_System_573` →
    `output_files/Konami_System_573.rbf` (after the DEPENDENCIES.md `.qsf`/`.qip`
    wiring: TOP_LEVEL_ENTITY sys_top, `source sys/sys.tcl`, nested `psx/rtl/*.qip`).
- Emulated builds are SLOW and RAM-hungry: iterate functionality in the Verilator sim;
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
