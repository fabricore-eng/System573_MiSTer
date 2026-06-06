#!/usr/bin/env python3
# =============================================================================
# sim_pctrace_to_format.py
#
# Post-process the NVC full-system sim's existing pc_trace.log (emitted by the
# pc_tap process in sim/system573/tb_system573.vhd) into the SHARED trace
# format consumed by ~/Dev/mister-dev-hub/tools/trace_diff.py, so our sim's PC
# stream can be diffed against MAME's golden PC log.
#
# SAFE, low-risk: this is a pure post-processor. It does NOT touch the VHDL.
#
# -----------------------------------------------------------------------------
# INPUT (what tb_system573.vhd's pc_tap actually writes, verified 2026-06-06):
#   The pc_tap process (tb_system573.vhd ~line 1090) taps the CPU PC via the
#   NVC external name
#       << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc : unsigned(31 downto 0) >>
#   and writes pc_trace.log with these line shapes:
#
#     PC=0x9FC00000
#         -> a PC *change*. NOTE: the probe deliberately logs ONLY NON-SEQUENTIAL
#            changes (cpu_pc /= prev AND cpu_pc /= prev+4), i.e. branches / jumps /
#            calls / returns -- the +4 straight-line fetches are SKIPPED to keep the
#            control-flow structure under the 400000-line cap. (VHDL lines 1119-1124.)
#     >>> HALT-ENTER 0x9FC20190 from prevPC=0x........ at cnt=NNNN
#         -> diagnostic marker when the boot enters the j-self halt loop. (line 1129)
#     [pcsnap] cnt=NNNN pc=0x9FC04567
#         -> periodic live-PC snapshot every 100000 clk1x. (line 1137)
#
#   Hex is 8 uppercase nibbles, '0x'-prefixed. PC is the *fetch* PC the icpu core
#   exposes (the instruction whose execution moved control flow to it).
#
# OUTPUT (shared format, see trace_diff.README.md):
#     # producer=sim-nvc-573 ...         <- '#' metadata header lines
#     i=0 pc=9fc00000                    <- one record per emitted PC, 8-LOWER-hex
#   PC-only (MVP). No reg columns are available from this probe, so we emit none;
#   trace_diff falls back to PC-only matching (which still finds branch divergence).
#
# -----------------------------------------------------------------------------
# *** IMPORTANT LIMITATION + the VHDL probe change to lift it ***
#
#   The existing pc_trace.log is a CONTROL-FLOW (branch-target) stream, NOT a
#   full retired-instruction stream: it omits every sequential +4 fetch. That is
#   fine for finding the FIRST branch/jump divergence vs MAME (the common case),
#   but it is NOT a 1:1 retired-PC stream, so:
#     - seq numbers (i=) are over BRANCH TARGETS, not retired instructions; and
#     - a same-target/different-straight-line-path bug between two branches is
#       invisible (both sides only show the branch endpoints).
#   To make trace_diff's resync maximally robust you want MAME emitting the SAME
#   shape. trace_diff resyncs by PC value, not by seq, so a sparse-but-aligned
#   branch stream on BOTH sides still diffs correctly; mismatched density (sim
#   sparse vs MAME dense) is tolerated by the window scan but wastes window.
#
#   To emit a TRUE per-retired-instruction PC stream instead, change the pc_tap
#   process in sim/system573/tb_system573.vhd (DO NOT do this blindly -- it
#   removes the +4 filter and will hit the 400000 cap far sooner; raise the cap
#   or gate on a sim-time window):
#
#     FILE:   sim/system573/tb_system573.vhd
#     SIGNAL: the tap is already correct --
#               alias cpu_pc is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc
#                                  : unsigned(31 downto 0) >>;            (line 1091)
#             icpu.pc is the fetch/commit PC; logging it on each change where it
#             differs from `prev` already yields every executed instruction's PC.
#     CHANGE: at line ~1120, replace the non-sequential guard
#               if (cpu_pc /= prev + 4) and (logged < 400000) then
#             with an UNFILTERED per-change log
#               if (logged < 4000000) then         -- every PC change, incl. +4
#             (and bump the cap / add a sim-time gate to bound file size). This
#             turns pc_trace.log into a true retired-PC stream; this converter
#             then needs NO change (it already passes every PC= line through).
#
#     A cleaner true-retire tap would gate on the core's instruction-COMMIT/
#     writeback strobe rather than a PC-change compare (a PC can repeat on a
#     tight self-branch, which a /=prev compare drops). The commit strobe in the
#     vendored core lives in psx/rtl/cpu.vhd (the writeback/"exec done" stage);
#     tapping it + icpu.pc on the same edge gives an exact 1-record-per-retired-
#     instruction stream. That is a larger probe change (new external name into
#     cpu.vhd's commit signal) and is NOT required for branch-divergence diffing,
#     so it is left as the future-work option.
#
#   Either way: NO VHDL EDIT is required for the common task (find the first
#   control-flow divergence vs MAME). This converter works on the log as-is.
# -----------------------------------------------------------------------------
#
# USAGE:
#   tools/trace/sim_pctrace_to_format.py SIM_PCTRACE_LOG [-o OUT] [--rom NAME]
#                                        [--keep-snaps] [--start-i N]
#   # default OUT is stdout; default rom is hyperbbc.
#   # example:
#   tools/trace/sim_pctrace_to_format.py sim/system573/build/pc_trace.log \
#       -o /tmp/sim.trace --rom hyperbbc
#   # then diff vs a MAME golden in the same format:
#   ~/Dev/mister-dev-hub/tools/trace_diff.py /tmp/mame.trace /tmp/sim.trace
# =============================================================================
import argparse
import re
import sys

# Matches the PC in the three line shapes the probe emits.
#   "PC=0x9FC00000"                       -> branch-target change
#   "[pcsnap] cnt=NNNN pc=0x9FC04567"     -> periodic snapshot (skipped by default)
# HALT-ENTER lines carry a prevPC=0x.... we do NOT treat as a stream PC (it is a
# diagnostic about the predecessor, already emitted as its own PC= record).
RE_PC_CHANGE = re.compile(r"^PC=0x([0-9A-Fa-f]{1,8})\b")
RE_PCSNAP = re.compile(r"^\[pcsnap\].*\bpc=0x([0-9A-Fa-f]{1,8})\b")


def iter_pcs(lines, keep_snaps):
    """Yield (pc_int) for each stream PC in the sim pc_trace.log, in order."""
    for raw in lines:
        line = raw.rstrip("\n")
        m = RE_PC_CHANGE.match(line)
        if m:
            yield int(m.group(1), 16)
            continue
        if keep_snaps:
            m = RE_PCSNAP.match(line)
            if m:
                yield int(m.group(1), 16)
                continue
        # HALT-ENTER and any other diagnostic lines are dropped (not stream PCs).


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Convert NVC sim pc_trace.log -> shared trace_diff format "
                    "(i=<seq> pc=<8hex>)."
    )
    ap.add_argument("input", help="path to sim pc_trace.log (or - for stdin)")
    ap.add_argument("-o", "--output", default="-",
                    help="output path (default: - = stdout)")
    ap.add_argument("--rom", default="hyperbbc",
                    help="rom name for the metadata header (default: hyperbbc)")
    ap.add_argument("--start-i", type=int, default=0,
                    help="starting seq number for i= (default: 0)")
    ap.add_argument("--keep-snaps", action="store_true",
                    help="also emit the periodic [pcsnap] PCs as stream records "
                         "(default: drop them -- they duplicate/coarsen the stream)")
    args = ap.parse_args(argv)

    if args.input == "-":
        lines = sys.stdin.readlines()
        src = "<stdin>"
    else:
        with open(args.input, "r", errors="replace") as f:
            lines = f.readlines()
        src = args.input

    out = sys.stdout if args.output == "-" else open(args.output, "w")
    try:
        # '#' metadata header (trace_diff treats '#' lines as comments).
        out.write("# producer=sim-nvc-573 source=pc_trace.log\n")
        out.write(f"# rom={args.rom}\n")
        out.write(f"# input={src}\n")
        out.write("# columns=pc-only "
                  "(branch-target stream: NON-sequential PC changes only; "
                  "no reg columns available from this probe)\n")
        i = args.start_i
        for pc in iter_pcs(lines, args.keep_snaps):
            out.write(f"i={i} pc={pc:08x}\n")
            i += 1
        emitted = i - args.start_i
        # trailing comment so a human eyeballing the file sees the count; '#'
        # lines are ignored by trace_diff.
        out.write(f"# records={emitted}\n")
    finally:
        if out is not sys.stdout:
            out.close()

    sys.stderr.write(f"sim_pctrace_to_format: wrote {emitted} PC records "
                     f"from {src}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
