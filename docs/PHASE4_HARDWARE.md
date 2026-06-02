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

The integration **compiles and synthesizes**. Quartus elaborates the full
hierarchy (`emu | psx_mister | psx_top | cpu | spu | gpu | memorymux |
datacache | …`) and Analysis & Synthesis runs clean. Errors found and fixed
along the way:

Elaboration: (1) `emu.sv` must be `SYSTEMVERILOG_FILE`; (2) patch 0003
`maximum()` → portable `clamp0()` (Quartus 17.0 lacks the VHDL-2008 builtin);
(3) build against `psx/sys` not the repo `sys/` (HPS_BUS packing); (4)
`files.qip` must include `psx/rtl/pll.qip` — emu.sv instantiates both `pll` and
`pll2`, and `pll_0002` lives in the `psx/rtl/pll` subdir that the bare
`SEARCH_PATH` does not reach.

**Build-host RAM — SOLVED.** `quartus_map` of the full PSX core needs ~11 GB,
which OOMs the ~10 GB Colima VM on this 16 GB Mac. The fix: a **30 GB swapfile
on the Colima data disk** (`/mnt/lima-colima`, which has room — the VM *root*
disk does not), giving 10 GB RAM + 30 GB swap. A&S then completes without OOM.
(Recipe in docs/DEPENDENCIES.md.)

**573-fabric synthesis — FIXED (commit "make the fabric + emu integration
synthesizable").** Two classes of Quartus-hostile RTL were resolved so the
device fits (Cyclone V `5CSEBA6U23I7`):
- *Clocked single-cycle full-array writes* (flash erase/program, x76 mass-erase
  /lockout, the zs01 security-packet engine, the atapi sim disc fill) build N
  parallel write ports / unroll huge loops. All are wrapped in `synthesis
  translate_off` — unreachable during the gchgchmp boot, and iverilog/NVC still
  run them so the 19/19 unit suite is unchanged.
- *Async-read RAM register overflow* (Error 276003: ~196k registers > device).
  `m48t58` now reads its 8 KB NVRAM **synchronously** → infers M10K (the
  wait-stated EXP1 bus, memorymux `EXT_READ_WAIT`, holds the address stable
  before the read strobe, absorbing the +1 cycle). `flash_nor` is **read-only
  in synthesis** (program/erase guarded) so the four windows fold to constant
  `0xFFFF` instead of ~131k registers. The standalone 573 A&S then passes with
  0 errors (~32 s, 2 GB).

The full `quartus_sh --flow compile Konami_System_573` (map→fit→asm→sta) runs
with the 30 GB swap and assembles `output_files/Konami_System_573.rbf`. Fit:
**98% ALMs (41,076/41,910), 100% DSP (112/112, no headroom), 76% RAM blocks,
4 PLLs** — it fits, but DSP is fully consumed, which matters for any later
video/VRAM work.

**Two build-config defects in the first full build (found by investigation + an
adversarial PR review; both now fixed):**
1. **Mis-pinned bitstream** — the qsf sourced the framework HDL (`sys.qip`) but
   *no* pin-location files, so all 145 board pins (SDRAM/HDMI/VGA…) auto-placed
   to arbitrary balls. SDRAM on wrong pins ⇒ the PSX core can't reach main RAM ⇒
   the BIOS almost certainly never executed on hardware (the HPS side works
   regardless, masking it). **Fix:** `sys_pins.tcl` (pin locations extracted from
   `psx/sys/sys.tcl` + `sys_analog.tcl`), sourced from the qsf.
2. **Timing not met** — `psx/PSX.sdc` (the pll2→clk_vid generated clock + cross-
   PLL false-paths) was never sourced, so STA reported worst setup slack
   −18.8 ns and clk_1x closing at ~28.5 MHz vs the ~33.8 it needs. "0 A&S errors"
   is *tool success, not timing met*. **Fix:** `set_global_assignment -name
   SDC_FILE psx/PSX.sdc`.

So the *original* "builds clean / runs on hardware" claim was wrong. **With both
fixes, the rebuilt `.rbf` BOOTS:** on a SuperStation One the gchgchmp BIOS comes
up to its test screen — clean color bars + a working menu — with a locked
component signal on a CRT (and a matching HDMI scaler capture). The CPU runs from
real SDRAM, the GPU renders into VRAM, and video scans out. The sim's "black
framebuffer" (Phase-3) was a sim artifact (the NVC harness's behavioral EXP1
responder returns zeros); on correct silicon the render→display path works.

Timing after the fix: clk_1x **+1.43 ns** and clk_vid **+0.94 ns** now MEET (were
−18.8 / −8.9); **clk_2x −3.29 ns and pll_hdmi −1.75 ns are still short** at the
worst hot/slow corner (98% ALM congestion) — so it is *not fully timing-clean*,
but the core demonstrably works (those corners are pessimistic vs a board at
typical temp). Closing clk_2x is a tracked follow-up.

**Build prerequisite:** `quartus_sh --flow compile Konami_System_573` needs a
project file. If `Konami_System_573.qpf` is absent (it is git-ignored, since
Quartus rewrites its timestamp), create a minimal one:
`printf 'PROJECT_REVISION = "Konami_System_573"\n' > Konami_System_573.qpf`.

**Known first-boot limitations (revisit after a verified boot screen):** flash is
read-only on hardware (no game can persist save data yet — gchgchmp doesn't
need it; a sync-friendly M10K 2-cycle program + an HPS flash-image load are TODO);
JAMMA inputs are routed conservatively and not yet polarity/bit-mapped to real
controls; the security cart / CD / MP3 paths are present in sim but not exercised
at boot; the 573's 2 MB VRAM (vs the PSX core's 1 MB) is not yet addressed.

## Deploy (once a .rbf exists)
Our `emu.sv` is a PSX-core clone, so it identifies as **"PSX"** in its CONF_STR
and auto-loads the index-0 BIOS from the MiSTer console path
`/media/fat/games/PSX/boot.rom`. The board already holds a real PlayStation BIOS
there, so first-boot bring-up swaps in a 573 BIOS with a backup/restore:

- `tools/mister_boot573.sh [core.rbf] [bios]` — back up the real PSX `boot.rom`,
  install the 573 BIOS (default `dumps/bios/700a01(gchgchmp).22g`) as `boot.rom`,
  scp the `.rbf` to `/media/fat/_Console`, and `load_core` it via `/dev/MiSTer_cmd`.
- `tools/mister_boot573.sh --shot [out.png]` — pull the newest screenshot.
- `tools/mister_boot573.sh --restore` — put the genuine PlayStation BIOS back.
- (`tools/mister_load.sh` / `tools/mister_shot.sh` remain the generic .rbf load /
  screenshot helpers.)

A cleaner long-term delivery is to rename the core (CONF_STR `SYSTEM573`) so it
uses its own `games/SYSTEM573/boot.rom`, or to author an `.mra` mapping the BIOS
to ROM index 0 — both deferred until after the first boot screen.
