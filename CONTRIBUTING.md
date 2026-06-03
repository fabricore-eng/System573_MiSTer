# Contributing

Thanks for your interest in the Konami System 573 MiSTer core. This is a
work-in-progress FPGA core; contributions to the RTL, simulation harnesses, and
documentation are welcome.

## License

The RTL in this repository is **GPL-2.0** (see [`LICENSE`](LICENSE)), to match the
MiSTer framework and the vendored PlayStation core (`psx/`) it builds on. By
contributing you agree your contributions are released under the same license. Keep
upstream license headers intact, and keep any edits inside `psx/` as isolated,
offer-back-able diffs (see the patch workflow below).

## Getting the source

```sh
git clone --recurse-submodules <repo-url>
# or, after a plain clone:
git submodule update --init --recursive    # pulls psx/ at its pinned SHA
```

The PlayStation core lives in `psx/` as a pinned git submodule; the MiSTer `sys/`
framework is a committed snapshot. See [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md)
for the exact pins and toolchain.

## Running the unit tests

The 573-specific RTL is plain Verilog-2005 and is verified with
[Icarus Verilog](https://steveicarus.github.io/iverilog/):

```sh
make -C sim            # run every testbench, report PASS/FAIL
make -C sim ds2401     # run a single module's testbench
```

Keep this suite green. New RTL should come with a testbench.

## Full-system boot simulation (NVC)

The PlayStation core is VHDL-2008, which Verilator cannot consume, so the
full-system boot runs under [NVC](https://www.nickg.me.uk/nvc/):

```sh
tools/apply_psx_patches.sh                  # apply the psx/ patches first (see below)
sim/system573/run.sh [STOP_TIME] [RAM8MB]   # e.g. sim/system573/run.sh 5ms 1
tools/check_boot.py sim/system573/build     # report which boot milestones were reached
```

See [`sim/system573/README.md`](sim/system573/README.md) for the harness details.

## The `psx/` submodule + `psx_patches/` workflow

`psx/` is pinned to an upstream SHA and the submodule pointer never moves. The 573
integration must edit the PlayStation core (EXP1 routing, IRQ10, etc.), so those
edits are kept as isolated patch files under `psx_patches/` and (re)applied to the
submodule working tree by:

```sh
tools/apply_psx_patches.sh            # apply (idempotent); --check / --revert also supported
```

Run it after any fresh `git submodule update`, and before the flows that read `psx/`
(the NVC sim and the Quartus `.rbf` build). The Icarus unit suite does not read
`psx/`. If you change the PlayStation core, add or update a patch in `psx_patches/`
rather than committing into the submodule.

## Building the FPGA bitstream

The `.rbf` needs x86-64 **Quartus Prime Lite 17.0.x** (Cyclone V `5CSEBA6U23I7`):

```sh
tools/apply_psx_patches.sh
quartus_sh --flow compile Konami_System_573   # -> output_files/Konami_System_573.rbf
```

If Quartus isn't installed natively, the `raetro/quartus:17.0` Docker image works.
See [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md) and
[`docs/PHASE4_HARDWARE.md`](docs/PHASE4_HARDWARE.md) for full build details and the
build-host RAM requirement.

## Hardware testing

Testing on real hardware needs a MiSTer board (DE10-Nano-class, Cyclone V) plus the
copyrighted BIOS, CD, security-cart, and flash dumps, **which are not distributed
with this repository**. See [`dumps/README.md`](dumps/README.md) for the expected
layout and where each dump is sourced; the binaries are git-ignored.

To deploy to a board, copy `local/mister.env.example` to `local/mister.env`
(git-ignored) and fill in the connection details; the `tools/mister_*.sh` scripts use
it.

## Submitting changes

- Branch off `main` and open a pull request.
- Keep the unit suite (`make -C sim`) green.
- Keep PRs focused; describe what you changed and how you verified it.
- For changes that touch the PlayStation core, include the corresponding
  `psx_patches/` patch rather than a submodule commit.
