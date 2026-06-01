# Dependencies & environment — staged for core development

Everything an autonomous session needs to develop and test the core, beyond the
in-repo RTL. Staged 2026-05-31. The unit-sim suite is green (`make -C sim`, 19/19)
and the heavy external pieces are vendored and pinned.

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

## Toolchain (installed on this machine)

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

`local/mister.env` is created and git-ignored (host `192.168.1.40`, user `root`, key
`~/.ssh/mister_crt`, `MISTER_CORE_DIR=/media/fat/_Arcade` verified to exist,
`CORE_RBF=Konami_System_573.rbf`). `ssh mister` is confirmed working (kernel 5.15.1
armv7l). `MISTER_SHOT_DIR=/media/fat/screenshots` is auto-created on first capture.

## FPGA bitstream build (Quartus in Docker via Colima) — STAGED & VALIDATED

The `.rbf` needs x86-64 Quartus Prime Lite 17.0.x (Cyclone V `5CSEBA6U23I7`); the
MiSTer's ARM CPU can't build it. The builder is **this Mac**, running an amd64 Quartus
container under **Colima + Apple-Virtualization + Rosetta**. This is set up and proven:
`raetro/quartus:17.0` (17.1 GB, bundles **Quartus 17.0.2 Build 602 Lite** + Cyclone V —
no Intel-login installer needed) is pulled into the VM. A **full compile was validated
end-to-end under Rosetta**: a minimal design targeting the DE10-Nano part
`5CSEBA6U23I7` ran the complete flow — Analysis & Synthesis → **Fitter** (placement +
routing, the mmap-heavy stage where Rosetta bugs would surface) → Assembler → and then
`quartus_cpf` `.sof`→`.rbf` — producing a real `.sof` and loadable `.rbf`, 0 errors, in
~70 s. The repo mounts cleanly via virtiofs. The VM is normally **stopped** to free RAM
— `colima start` before building.

> **CRITICAL arch gotcha (already handled, don't undo it):** this Mac's only Homebrew
> is the **Intel build under Rosetta** (`/usr/local`, no `/opt/homebrew`), so
> `brew install colima` yields **x86_64** `colima`/`limactl`, which Lima REFUSES for
> vz+Rosetta (`"limactl is running under rosetta"`). The fix in place: **native arm64**
> `colima` 0.10.1 + `lima` 2.1.1 binaries placed in `/usr/local/bin` (downloaded from
> the projects' GitHub releases; no sudo — `/usr/local` is user-owned). If you ever
> reinstall, keep them native arm64. (A few optional `lima` `libexec/` helpers
> — krunkit driver, mcp — failed to extract into the Intel-brew `/usr/local/libexec`;
> they're irrelevant to vz+Rosetta+docker and everything works without them.)

Rosetta is enabled via the **Colima template** (there is no `--vz-rosetta` CLI flag in
0.10.1): `~/.colima` template has `vmType: vz`, `rosetta: true`, `mountType: virtiofs`,
`arch: host`. Do NOT set `arch: x86_64` — the guest stays aarch64 and Rosetta translates
the x86 Quartus *process*; forcing x86_64 silently drops to slow qemu.

```sh
colima start --cpu 6 --memory 11 --disk 60          # uses the vz+rosetta template
# Build (after the wiring TODO below). The repo has NO .qpf, so compile by revision name:
docker run --rm --platform=linux/amd64 -v "$PWD":/work -w /work \
  --entrypoint quartus_sh raetro/quartus:17.0 --flow compile Konami_System_573
# -> output_files/Konami_System_573.rbf
colima stop                                          # reclaim the 11 GB when idle
```

Notes: the `.sof`→`.rbf` conversion is done by MiSTer's `POST_FLOW` hook
`sys/build_id.tcl` — ensure it's wired (`Template.qsf` / the psx subproject do this) or
you get a `.sof` but no `.rbf`. Fallback image: `theypsilon/quartus-lite-c5:17.0`
(`-slim`). To build your own image, the Lite 17.0 installer + Cyclone V pack are
fetchable headlessly (no login) from
`downloads.intel.com/akdlm/software/acdsinst/17.0std/595/ib_installers/`
(`QuartusLiteSetup-17.0.0.595-linux.run` + `cyclonev-17.0.0.595.qdz`). Rosetta-on-Linux
has rare mmap/glibc edge-case crashes — if Quartus dies oddly, qemu (slow) is the
fallback. The VM disk size is a hard cap set at `colima start`; the pulled image
persists across `colima stop`/`start` (only `colima delete` removes it).

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
