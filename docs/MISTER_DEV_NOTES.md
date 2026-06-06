# MiSTer / PSX-FPGA dev notes — shared across sessions (573 core ↔ DVD/SuperStation One core)

Both cores derive from the same upstream **PSX_MiSTer** (VHDL PlayStation) core, build on the same
**dell** Quartus box, and test on shared hardware (**SuperStation One**, **MiSTer**). So we share
both *resources* (must not collide) and *knowledge* (PSX-FPGA lessons transfer directly). This doc is
the contract + the lesson log. A copy lives on dell at `~/mister-shared/` (both sessions read/append).

## 1. Coordination — don't collide on shared resources

Primitive for EVERY shared resource: **lock + namespace + shared board**.

### dell build box (single-thread — one build at a time)
- Use the shared `tools/dell_build.sh` (now generic). Drive it per project:
  `DELL_PROJECT=dvd DELL_TARGET=<QuartusRevision> DELL_REPO=<repoDir> tools/dell_build.sh <ref>`
- It namespaces everything: container `quartus-$PROJECT`, log `/tmp/dellbuild-$PROJECT.log`,
  runner `/tmp/dell_build_run-$PROJECT.sh`. So `--status` / kills never touch the other project.
- **Shared atomic lock** `/tmp/dell-build.lock` serializes across projects (steals a stale lock if
  the holder died — no quartus container running). If busy it refuses with who's holding it.
- **Shared board** `/tmp/mister-dell-coord.log` — every build appends START/DONE. `tools/dell_build.sh --who`
  shows running builds + lock + recent board. Check `--who` before assuming the box is free.
- Each project's dashboard polls its OWN `/tmp/dellbuild-$PROJECT.log` (run on different ports if both).

### shared test hardware (SuperStation One, MiSTer) — TODO convention
- Same idea: before loading+testing a core on a shared device, acquire a device lock (a lockfile ON
  the device over SSH, e.g. `/tmp/devtest.lock` holding `<project> <iso>`), release after. Namespace
  artifacts (screenshots dir per core; `/dev/MiSTer_cmd` and the loaded core are singletons — only one
  session drives a device at a time). Not yet scripted — agree on the lock path + access method.

## 2. Reusable tooling (works for any MiSTer/PSX FPGA core)

- **`tools/dell_build.sh`** — reboot-proof DETACHED Quartus build on dell (`setsid nohup`, survives Mac
  reboot/SSH drop), namespaced + cross-project-locked. `--status` / `--who`.
- **`local/build_dashboard.py`** — live web dashboard (stage/%, ALM/DSP/RAM from .fit.rpt, health, ETA).
  Drive the build-start ELAPSED from the log's `build start <ts>` line, NOT `stat %W` (the log inode is
  reused → %W birth-time runs away; we hit this twice).
- **`tools/mister_filmstrip.sh`** — burst N screenshots over time (one boot rarely catches the failure;
  loops/HARDWARE-ERROR flicker need a film). Guard the `echo screenshot > /dev/MiSTer_cmd` write with
  `timeout` (a contended FIFO hangs).
- **`tools/mister_mra.sh`** — autonomous core-load over SSH: bundle BIOS/flash/NVRAM into a `.mra` + zip,
  deploy, `load_core` — no OSD button presses. (MiSTer `/dev/MiSTer_cmd` only does load_core/screenshot/
  Reset/Mount — no arbitrary ROM-load.)
- **`tools/timing_triage.tcl` + `tools/dell_timing.sh`** — re-run `quartus_sta` on a post-fit netlist
  (no re-fit) to extract failing paths + classify which are in YOUR subsystem vs upstream.
- **NVC** for VHDL-core sim (Verilator can't do the VHDL PSX core). `sim/system573/` is the full-system
  boot harness (knobs: FAST_BOOT, CORRECT_BOOT, PRELOAD_EXE, INJECT, ATAPI_EMU, SLOWVRAM, FAST_RAMTEST).

## 3. PSX-FPGA lessons (transfer 573 ↔ DVD core directly)

- **FPGA fit on Cyclone V 5CSEBA6U23I7 is the binding constraint.** The PSX core alone runs ~98% ALM /
  100% LABs. At 100% LABs ANY logic addition can break routing (a 119-min Fitter grind → Error 11802).
  Prefer **combinational ROMs over register arrays** (a 64-byte resp[] reg array + write-mux didn't fit;
  the same data as a `case` ROM did). Recover headroom by deleting **consumer-PS1 baggage the arcade/DVD
  use doesn't need** — measured (from .fit.rpt hierarchy): the DSP wall is MiSTer FRAMEWORK (ascal HDMI
  scaler 25 DSP, audio IIR 8 DSP), NOT the PSX silicon; cheats 139 ALM (safe gate-off, commit pattern in
  psx_patches/0008); savestates ~687 ALM (threaded, no toggle). Real PSX silicon (gpu 33 DSP, gte 15,
  spu 11, cpu 6 = ~65 DSP floor) must stay. See `memory/fpga-resource-budget.md`.
- **PSX interrupt controller (irq.vhd) latches I_STATUS on a RISING EDGE.** A device that holds INTRQ as
  a LEVEL across two events without a host-clear between them loses the 2nd event. Make device IRQ
  edge-clean (one 0→1 per event). [573 ATAPI hit this.]
- **Patching the Konami/PSX BIOS breaks its self-checksum.** The 573 "22G" check = last 32-bit LE word
  @file 0x7FFFC must equal the sum of all prior words. ANY sim-shortcut BIOS patch must recompute it or
  POST aborts (22G BAD). [Likely analogous self-checks in other BIOSes.]
- **NVC full-system boot is slow (~6s wall/sim-ms) AND gated by sim artifacts.** The boot stalls in a
  GPUSTAT bit28 (GPU-ready) wait — a known render→display SIM artifact (HW-fine). Shortcutting the slow
  loops (FAST_BOOT) is viable but **each NOP'd init surfaces the next real init dependency** — prefer
  re-enabling real init (CORRECT_BOOT: keep the BSS clears) over more NOPs, or the sim RAM holds garbage
  → the relocated IRQ-handler table jumps to a junk pointer.
- **Methodology that worked:** isolate logic correctness (bus + unit sims) AND timing (post-fit STA path
  extraction) BEFORE blaming either — both can be clean while HW fails for a behavioral/sim-gap reason.

## 4. Open / in-flight
- 573: drive-check (CDR) still fails on HW; logic + timing both proven clean; chasing the behavioral gap
  by getting the real BIOS to execute the drive check in the NVC sim (see `memory/573-game-boot-blockers.md`).
