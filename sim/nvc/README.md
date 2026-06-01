# NVC simulation of the PSX core (VHDL)

The vendored PlayStation core (`psx/`) is **VHDL-2008**, which Verilator cannot consume.
[NVC](https://www.nickg.me.uk/nvc/) is the chosen open-source VHDL simulator: it analyzes
and elaborates the entire unmodified core with zero source edits (GHDL works too but needs
a source patch + an x86_64 link workaround on Apple Silicon). No open-source tool
co-simulates VHDL + Verilog in one kernel, so the real Verilog 573 fabric is verified
separately (Icarus unit suite, `make -C sim`) and, for the full system, via an
NVC↔Verilator FFI bridge or on hardware (see `docs/PHASE1_PSX.md`).

## elaborate.sh — reproducible elaboration gate

```sh
brew install nvc            # one-time
sim/nvc/elaborate.sh        # applies psx_patches/, analyzes the core, elaborates psx_mister
```

Exits non-zero if the patched core fails to analyze/elaborate. This is the checked-in
proof that the System 573 EXP1 widening (`psx_patches/`) is consistent across
`memorymux.vhd` / `psx_top.vhd` / `psx_mister.vhd`. Build artifacts land in
`sim/nvc/build/` (git-ignored).

The full-system boot harness (BIOS load + GPU framebuffer dump + `check_boot.py` milestone
gating) builds on this recipe and is added in the Phase-2 sim-harness work.
