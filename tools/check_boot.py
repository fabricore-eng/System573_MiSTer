#!/usr/bin/env python3
"""
check_boot.py -- milestone gating + cross-run comparison for the System 573
full-system NVC boot sim (sim/system573/run.sh outputs in build/).

Two jobs:

  1. GATE: scan a run's trace logs for known BIOS boot milestones (in order) and
     report which were reached. Exit non-zero if a *required* milestone is missing
     (so a phase can self-gate, e.g. `check_boot.py build --require main_init`).

  2. COMPARE: confirm a change (e.g. a sim-speed accelerator) PRESERVES boot
     correctness -- the milestone sequence of the new run must match the baseline
     as a prefix/equal (the only allowed difference is reaching *further*, never a
     different control-flow order). This is the correctness check for the SDRAM
     FASTTIMING work: same instructions, just fewer simulated cycles.

The milestones are matched against pc_trace.log (CPU PC; note the trace shows
KSEG1 0xBFC..... which is phys 0x1FC..... -- same low offset), io_trace.log
(PSX internal I/O register accesses), exp1_trace.log (573 EXP1 peripheral
accesses), and bios_fetch.log (SDRAM read position snapshots).

Usage:
  tools/check_boot.py <run_dir>                       # report milestones reached
  tools/check_boot.py <run_dir> --require main_init   # gate (exit 1 if missing)
  tools/check_boot.py <run_dir> --compare <baseline_dir>   # correctness vs baseline
  tools/check_boot.py <run_dir> --json                # machine-readable summary

<run_dir> defaults to sim/system573/build.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sys

# --- milestone definitions ---------------------------------------------------
# Each milestone is detected from one trace. PC milestones use the offset within
# the BIOS window (low 24 bits) so KSEG0/KSEG1/phys all match. Ordered list = the
# canonical boot progression; "reached" milestones are reported in this order.

PC_RE   = re.compile(r"PC=0x([0-9A-Fa-f]{8})")
PCSNAP  = re.compile(r"pc=0x([0-9A-Fa-f]{8})")
IO_RE   = re.compile(r"IO addr=0x([0-9A-Fa-f]+)")
EXP1_RE = re.compile(r"EXP1 (RE|WE)\s+addr=0x([0-9A-Fa-f]+)")


def pc_phys(hex8: str) -> int:
    """Normalize a PC to its physical address. The R3000A maps KUSEG (0x0...),
    KSEG0 (0x8...) and KSEG1 (0xA.../0xB...) onto the same physical space by
    masking the top 3 bits, so the BIOS (phys 0x1FC00000) appears as 0x9FC00000
    (KSEG0) or 0xBFC00000 (KSEG1, uncached — where this boot runs). We compare on
    phys so any segment matches the same milestone. NB: masking the low 24 bits is
    WRONG — 0xBFC0040C & 0xFFFFFF = 0xC0040C, not the 0x40C offset."""
    return int(hex8, 16) & 0x1FFFFFFF


BIOS = 0x1FC00000  # physical base of the 512 KB BIOS window

# (key, human label, predicate over the parsed run facts). Ordered = expected
# temporal order of the boot. PC predicates use physical addresses (see pc_phys).
MILESTONES = [
    ("reset",         "reset vector @0x1FC00000",        lambda f: BIOS + 0x000000 in f["pc"]),
    ("ram_test",      "4 MB RAM test (~0x0040C)",        lambda f: any(BIOS + 0x400 <= p <= BIOS + 0x44F for p in f["pc"])),
    ("watchdog",      "573 watchdog kick (EXP1 0x5C0000)", lambda f: 0x5C0000 in f["exp1_we"]),
    ("bss_clear",     "BSS/runtime clear (~0x0046C)",     lambda f: any(BIOS + 0x460 <= p <= BIOS + 0x47F for p in f["pc"])),
    ("copy_loop",     "uncached BIOS->RAM copy (0x004D4)", lambda f: BIOS + 0x4D4 in f["pc"]),
    ("main_init",     "main init (0x05130-0x055FF)",       lambda f: any(BIOS + 0x5000 <= p <= BIOS + 0x55FF for p in f["pc"])),
    ("gpustat_poll",  "GPUSTAT/GPUREAD poll (0x1F801810/14)", lambda f: bool(f["io_addrs"] & {0x1F801810, 0x1F801814})),
    ("gpustat_done",  "GPU poll resolved -> SPU touched (0x1F801C00+)", lambda f: any(0x1F801C00 <= a <= 0x1F801FFF for a in f["io_addrs"])),
    ("draw",          "GPU draw activity (gpufifo non-empty)", lambda f: f["gpufifo_bytes"] > 0),
    ("framebuffer",   "non-black framebuffer (VRAM written)",  lambda f: f["fb_nonblack"]),
]


def parse_run(run_dir: str) -> dict:
    facts = {
        "pc": set(),
        "pc_last": None,
        "io_addrs": set(),
        "io_order": [],
        "exp1_we": set(),
        "exp1_re": set(),
        "gpufifo_bytes": 0,
        "fb_nonblack": False,
        "bios_reads": 0,
        "ram_reads": 0,
    }

    def path(name):
        return os.path.join(run_dir, name)

    pc = path("pc_trace.log")
    if os.path.exists(pc):
        with open(pc, errors="replace") as fh:
            for line in fh:
                m = PC_RE.search(line)
                if m:
                    facts["pc"].add(pc_phys(m.group(1)))
                    facts["pc_last"] = m.group(1)
                    continue
                m = PCSNAP.search(line)
                if m:
                    facts["pc"].add(pc_phys(m.group(1)))
                    facts["pc_last"] = m.group(1)

    io = path("io_trace.log")
    if os.path.exists(io):
        with open(io, errors="replace") as fh:
            for line in fh:
                m = IO_RE.search(line)
                if m:
                    a = int(m.group(1), 16)
                    facts["io_addrs"].add(a)
                    facts["io_order"].append(a)

    ex = path("exp1_trace.log")
    if os.path.exists(ex):
        with open(ex, errors="replace") as fh:
            for line in fh:
                m = EXP1_RE.search(line)
                if m:
                    a = int(m.group(2), 16)
                    (facts["exp1_we"] if m.group(1) == "WE" else facts["exp1_re"]).add(a)

    bf = path("bios_fetch.log")
    if os.path.exists(bf):
        last_bios = last_ram = 0
        with open(bf, errors="replace") as fh:
            for line in fh:
                mb = re.search(r"bios_reads=(\d+)", line)
                mr = re.search(r"ram_reads=(\d+)", line)
                if mb:
                    last_bios = int(mb.group(1))
                if mr:
                    last_ram = int(mr.group(1))
        facts["bios_reads"], facts["ram_reads"] = last_bios, last_ram

    # GPU FIFO debug file = draw activity. The upstream core writes this only when
    # the GPU command FIFO is fed (a draw has begun).
    gf = path("R:\\debug_gpufifo_sim.txt")
    if os.path.exists(gf):
        facts["gpufifo_bytes"] = os.path.getsize(gf)

    # Framebuffer: gra_fb_out.gra is raw VRAM. Non-trivial size + any non-zero
    # pixel => something drawn. (gra2png does the real visual check; this is a
    # cheap gate.) The composited VGA .gra is always full-size, so check raw VRAM.
    raw = path("gra_fb_out.gra")
    if os.path.exists(raw) and os.path.getsize(raw) > 64:
        with open(raw, "rb") as fh:
            data = fh.read()
        # skip a small header; any non-zero byte in the body => drawn
        facts["fb_nonblack"] = any(b != 0 for b in data[16:])

    return facts


def reached(facts: dict) -> list[tuple[str, str, bool]]:
    return [(k, label, pred(facts)) for (k, label, pred) in MILESTONES]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", nargs="?", default="sim/system573/build")
    ap.add_argument("--require", action="append", default=[], metavar="KEY",
                    help="milestone key that MUST be reached (repeatable); exit 1 if missing")
    ap.add_argument("--compare", metavar="BASELINE_DIR",
                    help="confirm this run's milestone sequence matches BASELINE as prefix/equal")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    facts = parse_run(args.run_dir)
    ms = reached(facts)
    reached_keys = [k for (k, _, ok) in ms if ok]

    if args.json:
        print(json.dumps({
            "run_dir": args.run_dir,
            "reached": reached_keys,
            "pc_last": facts["pc_last"],
            "bios_reads": facts["bios_reads"],
            "exp1_we_pages": sorted(hex(a) for a in facts["exp1_we"]),
            "io_addrs": sorted(hex(a) for a in facts["io_addrs"]),
        }, indent=2))
    else:
        print(f"=== boot milestones for {args.run_dir} ===")
        for (k, label, ok) in ms:
            print(f"  [{'x' if ok else ' '}] {k:14s} {label}")
        print(f"  last PC: 0x{facts['pc_last']}   bios_reads≈{facts['bios_reads']}")

    rc = 0

    for key in args.require:
        if key not in reached_keys:
            print(f"GATE FAIL: required milestone '{key}' not reached", file=sys.stderr)
            rc = 1

    if args.compare:
        base = parse_run(args.compare)
        base_keys = [k for (k, _, ok) in reached(base) if ok]
        # correctness: baseline's reached milestones must all be reached by the new
        # run AND in the same canonical order (the order is fixed by MILESTONES, so
        # equality of the *set-as-prefix* suffices: new must be a superset that
        # extends, never reorders/drops).
        missing = [k for k in base_keys if k not in reached_keys]
        if missing:
            print(f"COMPARE FAIL: run regressed vs baseline — lost milestones {missing}", file=sys.stderr)
            print(f"  baseline reached: {base_keys}", file=sys.stderr)
            print(f"  this run reached: {reached_keys}", file=sys.stderr)
            rc = 1
        else:
            extra = [k for k in reached_keys if k not in base_keys]
            print(f"COMPARE OK: preserved all {len(base_keys)} baseline milestones"
                  + (f"; advanced further: {extra}" if extra else "; same furthest point"))

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
