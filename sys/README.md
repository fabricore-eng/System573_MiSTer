# `sys/` — MiSTer framework

This directory is where the **MiSTer framework `sys` files** live. In a real
build it is the `sys` submodule from
[MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer)
and provides `sys_top.v`, `hps_io.v`, the video/scaler pipeline, the PLL
wrappers, the OSD, and the SDRAM/DDR3 controllers. `rtl/emu.sv` is the `emu`
top level that `sys_top.v` instantiates.

It is intentionally **not vendored** into this repository (it is a large,
separately-maintained component with its own license/version). To build the FPGA
core, add it as a submodule:

```sh
git submodule add https://github.com/MiSTer-devel/Template_MiSTer sys_template
cp -r sys_template/sys ./sys     # or wire the submodule's sys/ directly
```

The RTL under `rtl/` and the unit tests under `sim/` do **not** depend on `sys/`
and can be developed and tested without it (see `sim/Makefile`).
