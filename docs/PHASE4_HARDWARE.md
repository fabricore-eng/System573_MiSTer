# Phase 4 — boot the Konami BIOS on real MiSTer hardware

The goal: a buildable `.rbf` (Quartus 17.0.2, Cyclone V `5CSEBA6U23I7`, DE10-Nano)
whose `sys_top`/`emu` boots the Konami 573 BIOS and shows the boot screen on the
physical board.

## Key insight

`emu.sv` should be a **near-clone of the upstream `psx/PSX.sv`** (the proven
PSX_MiSTer top), with surgical 573 deltas — NOT an expansion of the trimmed
scaffold. The boot screen comes almost entirely from `psx_mister` (CPU/GPU/SPU +
SDRAM/DDR3); `system573_top` is a *slave on EXP1* and is not on the
gchgchmp-boot-screen critical path. `psx/PSX.sv`'s top module is already named
`emu` (psx/PSX.sv:23) and its port list matches `sys/sys_top.v`'s `emu`
instantiation, so cloning it solves the "full Template interface" problem for free.

The full-system NVC harness `sim/system573/tb_system573.vhd` is the authoritative
`psx_mister` EXP1 port-map reference (it instantiates the real, patched core).

## Minimum path to a first BIOS-boot screenshot (defer CD/security/MP3/flash)

1. **Apply patches** — `tools/apply_psx_patches.sh` (0001 EXP1 widening + IRQ10,
   0002/0003 NVC-strictness; all synthesis-safe). Re-run NVC boot (`sim/system573/
   run.sh` + `tools/check_boot.py build --require main_init`) as the pre-silicon gate.
2. **`rtl/emu.sv` = clone of `psx/PSX.sv`** (`cp`, then surgical edits):
   - Add the 6 EXP1 ports to the `psx_mister psx (...)` instance (after
     `.biosregion(biosregion)`, psx/PSX.sv:1113), mirroring tb_system573.vhd:436-442:
     `.exp1_addr(exp1_addr) .exp1_dataWrite(exp1_dataWrite) .exp1_we(exp1_we)
      .exp1_re(exp1_re) .exp1_dataRead(exp1_dataRead) .exp_irq10(exp_irq10)`.
   - Declare those wires; instantiate `system573_top u_s573` on `clk_1x`/`reset`,
     looping EXP1 (name map: psx `exp1_dataWrite`→573 `exp1_wdata`; 573 `exp1_rdata`→
     psx `exp1_dataRead`; 573 `cdrom_irq`→psx `exp_irq10`). 573 inputs conservative
     (dip_sw=0, p1/p2_ctrl=joy[7:0], coin/service/test=0, pcmcia=0, adc=0); outputs
     observed-only — **leave `wdog_reset` UNWIRED from core reset for first boot**.
   - Force `.ram8mb(1'b1)` (573 has 4 MB; matches sim) and `.fastboot(1'b0)`
     (SCPH-specific, OFF for Konami BIOS). Leave the BIOS-download path + `biosregion`
     logic as-is: index-0 BIOS lands at SDRAM 0x800000 = region 0, exactly the
     sim-validated location.
3. **Delete `rtl/ps1_stub.v`** + remove from `files.qip`.
4. **`files.qip`**: add nested `psx/rtl/{psx,mem,pll,pll2}.qip` +
   `psx/rtl/{sdram,ddram,savestate_ui}.sv` + `psx/rtl/hps_ext.v` + `SEARCH_PATH psx/rtl`.
   Do NOT source `psx/files.qip` or `psx/PSX.sv`/`.sdc`.
5. **`Konami_System_573.qsf`**: `TOP_LEVEL_ENTITY=sys_top`; `source sys/sys.tcl`;
   add `set_global_assignment -name VHDL_INPUT_VERSION VHDL_2008` (PSX core is
   VHDL-2008 — upstream sets this in psx/PSX.qsf:71); drop the local FAMILY/DEVICE
   (sys.tcl sets them). Keep `MISTER_FB=1` (PSX needs the DDR3 framebuffer).
6. **`Konami_System_573.sdc`**: drop the `CLK_50M` placeholder clock (sys.sdc +
   PLL constraints come from sys). If timing fails, port multicycle/false-path
   lines from `psx/PSX.sdc`.
7. **Build** the `.rbf` — Colima + `raetro/quartus:17.0` (see docs/DEPENDENCIES.md):
   `colima start` → `quartus_sh --flow compile Konami_System_573` →
   `output_files/Konami_System_573.rbf`. ~30–60 min.
8. **Deploy tooling** (TODO, don't exist yet): `tools/mister_load.sh` (scp `.rbf` +
   BIOS, load) and `tools/mister_shot.sh` (pull the screenshot) using `local/mister.env`
   (192.168.1.40, key mister_crt, `/media/fat/_Arcade`, `/media/fat/screenshots`).
9. **Deploy + boot gchgchmp BIOS, screenshot, LOOK.** Compare to the sim `.gra`→PNG.

## BIOS delivery on hardware

PSX.sv loads the BIOS as HPS `ioctl_index==0` → SDRAM `{4'd1,2'b00,index[7:6],addr[18:0]}`
(psx/PSX.sv:701), i.e. region-0 at 0x800000 — matches the sim. Deliver the 512 KB
Konami BIOS (`dumps/bios/573.bin`, or `700a01(gchgchmp).22g` for the no-CD/no-cart
game-in-BIOS) as the index-0 ROM (OSD load for bring-up; an `.mra` is cleaner later).
CD images + security carts come via the HPS `sd_*`/`img_mounted` path later.

## Risks / verify items
1. **VHDL-2008** must be enabled in the qsf (item 5) — else the VHDL core won't analyze.
2. **Patch 0003 `maximum()`** is VHDL-2008; synthesizable once 2008 is on.
3. **`PSX.sdc` skipped** — port multicycle/false-path constraints if timing fails.
4. **Resource fit** on `5CSEBA6U23I7` — PSX fits stock; 573 fabric is small (low risk).
5. **Watchdog** (`system573_top.v:72`) — keep `wdog_reset` off the reset path for first boot.
6. **Build = ~1 hr**; iterate functionality in the NVC sim, build only at the gate.

See docs/EXECUTION_PLAN.md (Phase 4), docs/DEPENDENCIES.md (Colima/Quartus recipe),
docs/PHASE1_PSX.md (EXP1 contract), and the project memory.

## Build status (2026-06-01)

The integration **compiles** — Quartus elaborates the full hierarchy
(`emu | psx_mister | psx_top | cpu | spu | gpu | memorymux | datacache | …`).
Three elaboration errors were found and fixed by iterating the Colima/Quartus
build: (1) `emu.sv` must be `SYSTEMVERILOG_FILE` (it's the PSX.sv clone); (2)
patch 0003 `maximum()` → portable `clamp0()` (Quartus 17.0 lacks the VHDL-2008
builtin); (3) build against `psx/sys` not the repo `sys/` (HPS_BUS packing).

**Open: build-host RAM.** `quartus_map` (analysis & synthesis) of the full PSX
core **OOMs** in the 11 GB Colima VM on this 16 GB Mac (`Error 293007: ended
unexpectedly … sufficient memory`), even serial (`NUM_PARALLEL_PROCESSORS=1`).
Synthesizing the PS1 core needs **>11 GB**. Options to actually produce the
`.rbf`: (a) build on a **≥32 GB** machine (VM ≥ ~16 GB); (b) add **VM swap**
(`colima ssh -- sudo sh -c 'fallocate -l 8G /swapfile && mkswap /swapfile &&
swapon /swapfile'`) for a slow paging build (the VM root is small/full though —
may need a bigger `colima --disk`); (c) a large CI runner (standard GitHub
Actions ~7 GB is too small). The integration itself is validated, so the build
is purely an environment-capacity issue.

## Deploy (once a .rbf exists)
- `tools/mister_load.sh [core.rbf]` — scp the `.rbf` to `/media/fat/_Arcade` and
  `load_core` it via `/dev/MiSTer_cmd` (verified present on the board).
- `tools/mister_shot.sh [out.png]` — pull the newest `/media/fat/screenshots` PNG.
- BIOS delivery: the PSX core wants the BIOS as HPS index-0; for first boot use
  the OSD file picker or author a `.mra` mapping the Konami BIOS to ROM index 0.
