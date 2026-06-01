# `sys/` — MiSTer framework (vendored snapshot)

This directory is the **MiSTer framework `sys` files**: `sys_top.v` (the real
synthesis top), `sys.qip`/`sys.tcl`, `sys_top.sdc`, `hps_io.sv`, the video/scaler
pipeline (`ascal.vhd`, `video_mixer.sv`, `hq2x.sv`, `vga_out.sv`, …), the audio
chain, `sysmem.sv` (SDRAM/DDR3), the OSD, and the PLL wrappers. `rtl/emu.sv` is the
`emu` top level that `sys_top.v` instantiates (around line ~1756: `emu emu (...)`).

## Vendored as a pinned snapshot

Unlike `psx/` (a git submodule), `sys/` is committed here as a **plain pinned
snapshot** — this matches how mainline MiSTer cores ship it (Template_MiSTer's
`sys/` is a *subdirectory* of that repo, not a standalone repository, so it can't be
a submodule of `./sys` directly).

- **Source:** [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer)
- **Pinned commit:** `f35083f3b40d24853abea4cd3f77caccbd71d5de` (master, 2026-05-13)

Re-sync to a newer upstream:

```sh
TMP=$(mktemp -d); git clone https://github.com/MiSTer-devel/Template_MiSTer "$TMP/T"
git -C "$TMP/T" checkout <new_sha>
cp sys/README.md /tmp/sysREADME.bak
rm -rf sys && mkdir sys && cp -R "$TMP/T/sys/." sys/ && cp /tmp/sysREADME.bak sys/README.md
rm -rf "$TMP"; git add sys
```

## Quartus build wiring (not yet applied)

`Konami_System_573.qsf` must be wired to this framework the way `Template.qsf` is —
see `docs/DEPENDENCIES.md` for the exact edits. In short: `TOP_LEVEL_ENTITY` must be
**`sys_top`** (not `emu`), then `source sys/sys.tcl` (sets FAMILY/DEVICE + all pin
assignments and pulls in `sys.qip`) and `source files.qip` (the core RTL). The
scaffold `rtl/emu.sv` port list will need expanding to match `sys_top.v`'s `emu`
instantiation before a `.rbf` links.

The RTL under `rtl/` and the unit tests under `sim/` do **not** depend on `sys/` —
they build and pass (`make -C sim`) without it.
