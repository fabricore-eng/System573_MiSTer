# Dependencies & environment — staged for core development

Everything needed to develop and test the core, beyond the in-repo RTL. The
unit-sim suite is green (`make -C sim`, 19/19) and the heavy external pieces are
vendored and pinned.

## Vendored code

| Dep | Where | Form | Pin | License |
|-----|-------|------|-----|---------|
| **PSX_MiSTer** (the PS1 core the 573 rides on) | `psx/` | git submodule | `67153439fbb8e85e4108b9f0ff474d37aa6f7f5b` (tip of `main`, 2026-04-12; no upstream tags exist) | GPL-2.0 |
| **MiSTer `sys/` framework** | `sys/` | pinned snapshot (committed, not a submodule) | Template_MiSTer `f35083f3b40d24853abea4cd3f77caccbd71d5de` (master, 2026-05-13) | GPL-2.0 |

```sh
# Fresh clone / CI bootstrap (pulls the psx submodule at its pinned SHA):
git submodule update --init --recursive          # or: --depth 1 psx  (history is ~100 MB)
# Advance the PSX pin later:  cd psx && git fetch && git checkout <sha> && cd .. && git add psx
```

`psx/` working tree ~58 MB (no Git LFS). `sys/` is re-synced by re-copying the
snapshot (see `sys/README.md`). GPL-2.0 propagates to the whole core — keep upstream
headers/LICENSE intact; any edits inside `psx/` (4 MB RAM / 2 MB VRAM / EXP1 routing)
inherit GPL-2.0 and should be kept as isolated, offer-back-able diffs.

## Toolchain

| Tool | Version | Install | Use |
|------|---------|---------|-----|
| Icarus Verilog | 13.0 | `brew install icarus-verilog` | unit sim (`make -C sim`) |
| Verilator | 5.048 | `brew install verilator` | full-system sim (Phase 2) |
| chdman | 0.288 (via `rom-tools`) | `brew install rom-tools` | read the CHD discs in `dumps/mame573/*/` |
| bsdtar | libarchive 3.7.4 | (built-in `/usr/bin/bsdtar`) | extracts `.7z` cart archives — no p7zip needed |

> The session-start hook installs iverilog via `apt`, which **no-ops on macOS** — the
> versions above were installed with Homebrew instead. `chdman` has **no** `--version`
> flag; run `chdman` bare to print its banner. `chdman --help` lists `extractcd` etc.
> for turning the `mame573/*/<disc>.chd` images into BIN/CUE for the ATAPI model.

## Board connection

Copy `local/mister.env.example` to `local/mister.env` (git-ignored) and set the
board's host/IP, SSH user + key, `MISTER_CORE_DIR`, and `CORE_RBF`. The
`tools/mister_*.sh` scripts read it; an `ssh mister` SSH-config alias also works.
`MISTER_SHOT_DIR` is auto-created on first screenshot capture.

## FPGA bitstream build

The `.rbf` needs x86-64 Quartus Prime Lite 17.0.x (Cyclone V `5CSEBA6U23I7`); the
MiSTer ARM CPU cannot build it. Build on any x86-64 Linux host with Quartus 17.0
installed:

```sh
tools/apply_psx_patches.sh                       # apply the psx/ EXP1 widening first
quartus_sh --flow compile Konami_System_573      # -> output_files/Konami_System_573.rbf
```

If Quartus isn't installed natively, the `raetro/quartus:17.0` Docker image bundles
**Quartus 17.0.2 Build 602 Lite** + Cyclone V (no Intel-login installer needed):

```sh
docker run --rm --platform=linux/amd64 -v "$PWD":/work -w /work \
  --entrypoint quartus_sh raetro/quartus:17.0 --flow compile Konami_System_573
# -> output_files/Konami_System_573.rbf
```

Notes:
- `quartus_map` of the full PSX core needs ~11 GB RAM; on low-RAM hosts add swap (or
  build serially — `NUM_PARALLEL_PROCESSORS 1`, already set in the qsf).
- The `.sof`→`.rbf` conversion is done by MiSTer's `POST_FLOW`/`GENERATE_RBF` hook —
  ensure it's wired (the qsf sets `GENERATE_RBF_FILE ON`) or you get a `.sof` but no
  `.rbf`.
- To build your own Quartus image, the Lite 17.0 installer + Cyclone V pack are
  fetchable headlessly (no login) from
  `downloads.intel.com/akdlm/software/acdsinst/17.0std/595/ib_installers/`
  (`QuartusLiteSetup-17.0.0.595-linux.run` + `cyclonev-17.0.0.595.qdz`).

(A detailed Colima/Docker-on-macOS-under-Rosetta build recipe is kept out of the public
tree, in the git-ignored `local/`.)

## Local PSX-core patches (`psx_patches/`)

`psx/` is a submodule pinned to an upstream SHA we cannot push to, but the 573
integration *must* edit the PlayStation core (EXP1 routing, later 2 MB VRAM, DMA ch5).
Those GPL-2.0 edits are kept as **isolated, offer-back-able patch files** under
`psx_patches/` and (re)applied to the submodule working tree by
**`tools/apply_psx_patches.sh`** — the submodule pointer never moves. Run it after any
fresh `git submodule update`, and before the flows that read `psx/`: the **NVC** VHDL
sim (`sim/nvc/elaborate.sh`) and the **Quartus** `.rbf` build. (The Icarus unit suite,
`make -C sim`, only compiles the Verilog `rtl/` fabric and does not read `psx/`.)

```sh
git submodule update --init --recursive
tools/apply_psx_patches.sh            # apply (idempotent); --check / --revert also supported
sim/nvc/elaborate.sh                  # reproducible gate: patched PSX core elaborates under NVC
```

Applied so far: `0001-s573-exp1-widening.patch` — widens the EXP1 path in
`memorymux.vhd`/`psx_top.vhd`/`psx_mister.vhd` from the upstream read-only 8-bit /
13-bit-address stub to a full 16-bit master (24-bit address, 16-bit read+write) routed
to `system573_top`, plus the IRQ10 (`irq_LIGHTPEN`) injection for the 573 ATAPI INTRQ.
Verified: the patched core analyzes + elaborates clean under NVC (`nvc -e psx_mister`).

## Build-wiring TODO (Phase 1 — NOT yet applied)

Vendoring is done; the Quartus project is **not** yet wired to the vendored code.
The `.rbf` build won't link until this is done (the unit-sim flow is unaffected):

1. **`Konami_System_573.qsf`** — currently `TOP_LEVEL_ENTITY = emu` with the `sys`
   include commented out. Change to match `Template.qsf`:
   `set_global_assignment -name TOP_LEVEL_ENTITY sys_top` · `source sys/sys.tcl`
   (sets FAMILY/DEVICE `5CSEBA6U23I7` + all pin assignments and pulls in `sys.qip`,
   which adds `sys_top.v` as top + `sys_top.sdc`) · `source files.qip`. Drop the local
   FAMILY/DEVICE lines that would conflict with `sys.tcl`. Use **Quartus 17.0.x**
   (the project declares 17.0.2; `sys.qip` selects `pll_q17`).

2. **`files.qip`** — do **not** `source` upstream `psx/files.qip` (its bare relative
   paths resolve against the parent, and `PSX.sv` is upstream's MiSTer top, which the
   573 replaces with `emu.sv`). Instead add explicit nested lines in this convention:
   `set_global_assignment -name QIP_FILE [file join $::quartus(qip_path) psx/rtl/psx.qip]`
   (and `psx/rtl/mem.qip`, `sdram.sv`, `ddram.sv`, … as needed), plus
   `set_global_assignment -name SEARCH_PATH psx/rtl`. Skip `PSX.sv` and `PSX.sdc`.

3. **Replace `rtl/ps1_stub.v`** — instantiate the real PSX core inside
   `system573_top`/`emu.sv`, wiring the EXP1 master, IRQ10, DMA ch5, video and audio
   per [`PHASE1_PSX.md`](PHASE1_PSX.md).

4. **Expand `rtl/emu.sv`** — the scaffold port list must grow to the full Template
   `emu` interface that `sys_top.v` instantiates (~line 1756) before synthesis links.

See [`PHASE1_PSX.md`](PHASE1_PSX.md) and [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md) for
the surrounding plan. Dumps inventory + cart/disc layout: [`../dumps/README.md`](../dumps/README.md).

## Note on the unit suite

`make -C sim` is **19/19 green**. Two testbenches (`tb_atapi.v`,
`tb_k573_mp3stream.v`) had latent compile issues that Icarus 13.0 enforces (a
declaration-after-use net and an indefinite-width concatenation); both were fixed in
the testbenches — the RTL was untouched.
