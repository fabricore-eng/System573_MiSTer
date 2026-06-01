#!/usr/bin/env python3
"""
check_boot.py -- milestone gating + cross-run comparison for the System 573
full-system NVC boot sim (sim/system573/run.sh outputs in build/).

Two jobs:

  1. GATE: scan a run's trace logs for known BIOS boot milestones (in order) and
     report which were reached. Exit non-zero if a *required* milestone is missing
     (so a phase can self-gate, e.g. `check_boot.py build --require main_init`).

  2. COMPARE: sanity-check that a change (e.g. a sim-speed accelerator) did not
     regress the boot. It verifies (a) every milestone reached by the BASELINE is
     also reached by this run (no regression), and (b) the PC-based control-flow
     milestones (reset/ram_test/bss_clear/copy_loop/main_init -- all on the
     pc_trace.log timeline) appear in the SAME relative order (catches a reorder a
     pure set test would miss). Cross-trace milestones (watchdog/io/framebuffer
     live in separate logs with no shared timeline) are checked by set membership
     only. For bit-exact control-flow verification, additionally diff the
     pc_trace.log branch-target sequences of the two runs directly.

The milestones are matched against pc_trace.log (CPU PC; the trace shows KSEG1
0xBFC..... which is phys 0x1FC..... -- same physical address), io_trace.log (PSX
internal I/O register accesses), exp1_trace.log (573 EXP1 peripheral accesses),
bios_fetch.log (SDRAM read position), and the .gra framebuffer dumps.

Usage:
  tools/check_boot.py <run_dir>                       # report milestones reached
  tools/check_boot.py <run_dir> --require main_init   # gate (exit 1 if missing)
  tools/check_boot.py <run_dir> --compare <baseline_dir>   # no-regression check
  tools/check_boot.py <run_dir> --json                # machine-readable summary

<run_dir> defaults to sim/system573/build.
"""
from __future__ import annotations
import argparse
import glob
import json
import os
import re
import sys

# --- regexes for the harness trace formats ----------------------------------
PC_RE   = re.compile(r"PC=0x([0-9A-Fa-f]{8})")
PCSNAP  = re.compile(r"pc=0x([0-9A-Fa-f]{8})")
IO_RE   = re.compile(r"IO addr=0x([0-9A-Fa-f]+)")
EXP1_RE = re.compile(r"EXP1 (RE|WE)\s+addr=0x([0-9A-Fa-f]+)")

BIOS = 0x1FC00000  # physical base of the 512 KB BIOS window


def pc_phys(hex8: str) -> int:
    """Normalize a PC to its physical address. The R3000A maps KUSEG (0x0...),
    KSEG0 (0x8...) and KSEG1 (0xA.../0xB...) onto the same physical space by
    masking the top 3 bits, so the BIOS (phys 0x1FC00000) appears as 0x9FC00000
    (KSEG0) or 0xBFC00000 (KSEG1, uncached -- where this boot runs). We compare on
    phys so any segment matches the same milestone. NB: masking the low 24 bits is
    WRONG -- 0xBFC0040C & 0xFFFFFF = 0xC0040C, not the 0x40C offset."""
    return int(hex8, 16) & 0x1FFFFFFF


def pc_milestone(p: int) -> str | None:
    """Classify a physical PC into the PC-based (control-flow) milestone it hits,
    or None. Kept in sync with MILESTONES below; used for the --compare order
    check (which needs first-occurrence order, not just membership)."""
    if p == BIOS + 0x000000:
        return "reset"
    if BIOS + 0x400 <= p <= BIOS + 0x44F:
        return "ram_test"
    if BIOS + 0x460 <= p <= BIOS + 0x47F:
        return "bss_clear"
    if p == BIOS + 0x4D4:
        return "copy_loop"
    if BIOS + 0x5000 <= p <= BIOS + 0x55FF:
        return "main_init"
    return None


def gra_pixels(path: str) -> tuple[int, int]:
    """(pixel_count, nonblack_count) for a .gra ASCII dump, else (0, 0).

    The PSX-core sim writes the framebuffer as TEXT (see tools/gra2png.py):
    line 1 = "W#H#scale", then one "COLOR#x#y" line per pixel. A byte-level
    non-zero test is wrong (every text byte is non-zero, even for a black pixel
    "0#x#y") -- non-black means at least one pixel whose COLOR field != 0."""
    if not os.path.exists(path):
        return (0, 0)
    n = nb = 0
    try:
        with open(path, "r", errors="replace") as fh:
            fh.readline()  # skip "W#H#scale" header
            for line in fh:
                c = line.split("#")
                if len(c) != 3:
                    continue
                n += 1
                try:
                    if int(c[0]) != 0:
                        nb += 1
                except ValueError:
                    pass
    except OSError:
        return (0, 0)
    return (n, nb)


# (key, human label, predicate over parsed run facts). Ordered = expected
# temporal order of the boot. PC predicates use physical addresses (see pc_phys).
MILESTONES = [
    ("reset",         "reset vector @0x1FC00000",            lambda f: BIOS + 0x000000 in f["pc"]),
    ("ram_test",      "4 MB RAM test (~0x1FC0040C)",          lambda f: any(BIOS + 0x400 <= p <= BIOS + 0x44F for p in f["pc"])),
    ("watchdog",      "573 watchdog kick (EXP1 0x5C0000)",    lambda f: 0x5C0000 in f["exp1_we"]),
    ("bss_clear",     "BSS/runtime clear (~0x1FC0046C)",      lambda f: any(BIOS + 0x460 <= p <= BIOS + 0x47F for p in f["pc"])),
    ("copy_loop",     "uncached BIOS->RAM copy (0x1FC004D4)", lambda f: BIOS + 0x4D4 in f["pc"]),
    ("main_init",     "main init (0x1FC05000-0x1FC055FF)",     lambda f: any(BIOS + 0x5000 <= p <= BIOS + 0x55FF for p in f["pc"])),
    ("gpustat_poll",  "GPUSTAT/GPUREAD poll (0x1F801810/14)", lambda f: bool(f["io_addrs"] & {0x1F801810, 0x1F801814})),
    ("gpustat_done",  "GPU poll resolved -> SPU touched (0x1F801C00+)", lambda f: any(0x1F801C00 <= a <= 0x1F801FFF for a in f["io_addrs"])),
    ("draw",          "GPU draw activity (FIFO/VRAM written)", lambda f: f["gpufifo_bytes"] > 0 or f["vram_pixels"] > 0),
    ("framebuffer",   "non-black framebuffer (boot screen)",   lambda f: f["fb_nonblack"]),
]


def parse_run(run_dir: str) -> dict:
    facts = {
        "pc": set(),
        "pc_order": [],        # PC milestone keys in first-occurrence order
        "pc_last": None,
        "io_addrs": set(),
        "io_order": [],
        "exp1_we": set(),
        "exp1_re": set(),
        "gpufifo_bytes": 0,
        "vram_pixels": 0,
        "fb_nonblack": False,
        "bios_reads": 0,
        "ram_reads": 0,
    }

    def path(name):
        return os.path.join(run_dir, name)

    pc = path("pc_trace.log")
    if os.path.exists(pc):
        seen_ms = set()
        with open(pc, errors="replace") as fh:
            for line in fh:
                m = PC_RE.search(line) or PCSNAP.search(line)
                if not m:
                    continue
                p = pc_phys(m.group(1))
                facts["pc"].add(p)
                facts["pc_last"] = m.group(1)
                k = pc_milestone(p)
                if k and k not in seen_ms:   # first-occurrence order
                    seen_ms.add(k)
                    facts["pc_order"].append(k)

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
        last_bios = last_ram = fetch_max = 0
        with open(bf, errors="replace") as fh:
            for line in fh:
                mb = re.search(r"bios_reads=(\d+)", line)
                mr = re.search(r"ram_reads=(\d+)", line)
                mf = re.search(r"BIOS fetch #(\d+)", line)
                if mb:
                    last_bios = int(mb.group(1))
                if mr:
                    last_ram = int(mr.group(1))
                if mf:
                    fetch_max = max(fetch_max, int(mf.group(1)))
        # [snap] lines appear only every 2000 reads; on short runs fall back to the
        # verbatim 'BIOS fetch #N' counter so we don't misreport 0.
        facts["bios_reads"], facts["ram_reads"] = max(last_bios, fetch_max), last_ram

    # 'draw' = GPU activity. The core writes the FIFO-debug file with a literal
    # DOUBLE backslash ("R:\\..." in VHDL has no escaping), so glob rather than
    # hard-code the backslash count.
    for gf in glob.glob(os.path.join(run_dir, "*debug_gpufifo_sim.txt")):
        facts["gpufifo_bytes"] += os.path.getsize(gf)

    # raw VRAM writes are also draw evidence; either framebuffer dump going
    # non-black means something was actually rendered (the boot-screen gate).
    facts["vram_pixels"] = gra_pixels(path("gra_fb_out.gra"))[0]
    for g in ("gra_fb_out_vga.gra", "gra_fb_out.gra"):
        if gra_pixels(path(g))[1] > 0:
            facts["fb_nonblack"] = True

    return facts


def reached(facts: dict):
    return [(k, label, pred(facts)) for (k, label, pred) in MILESTONES]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", nargs="?", default="sim/system573/build")
    ap.add_argument("--require", action="append", default=[], metavar="KEY",
                    help="milestone key that MUST be reached (repeatable); exit 1 if missing")
    ap.add_argument("--compare", metavar="BASELINE_DIR",
                    help="confirm this run reaches every baseline milestone (no regression) "
                         "and preserves PC-milestone order")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    facts = parse_run(args.run_dir)
    ms = reached(facts)
    reached_keys = [k for (k, _, ok) in ms if ok]

    if args.json:
        print(json.dumps({
            "run_dir": args.run_dir,
            "reached": reached_keys,
            "pc_order": facts["pc_order"],
            "pc_last": facts["pc_last"],
            "bios_reads": facts["bios_reads"],
            "exp1_we_pages": sorted(hex(a) for a in facts["exp1_we"]),
            "io_addrs": sorted(hex(a) for a in facts["io_addrs"]),
        }, indent=2))
    else:
        print(f"=== boot milestones for {args.run_dir} ===")
        for (k, label, ok) in ms:
            print(f"  [{'x' if ok else ' '}] {k:14s} {label}")
        last = f"0x{facts['pc_last']}" if facts["pc_last"] else "(none)"
        print(f"  last PC: {last}   bios_reads≈{facts['bios_reads']}")

    rc = 0

    for key in args.require:
        if key not in reached_keys:
            print(f"GATE FAIL: required milestone '{key}' not reached", file=sys.stderr)
            rc = 1

    if args.compare:
        base = parse_run(args.compare)
        base_keys = [k for (k, _, ok) in reached(base) if ok]
        # (a) no regression: every baseline milestone must be reached here.
        missing = [k for k in base_keys if k not in reached_keys]
        if missing:
            print(f"COMPARE FAIL: regressed vs baseline -- lost milestones {missing}", file=sys.stderr)
            print(f"  baseline reached: {base_keys}", file=sys.stderr)
            print(f"  this run reached: {reached_keys}", file=sys.stderr)
            rc = 1
        # (b) PC-milestone control-flow order preserved (catches reordering).
        shared = [k for k in base["pc_order"] if k in facts["pc_order"]]
        new_shared = [k for k in facts["pc_order"] if k in shared]
        if shared != new_shared:
            print(f"COMPARE FAIL: PC-milestone order diverged from baseline", file=sys.stderr)
            print(f"  baseline order: {shared}", file=sys.stderr)
            print(f"  this run order: {new_shared}", file=sys.stderr)
            rc = 1
        if rc == 0:
            extra = [k for k in reached_keys if k not in base_keys]
            print(f"COMPARE OK: preserved all {len(base_keys)} baseline milestones in order"
                  + (f"; advanced further: {extra}" if extra else "; same furthest point"))

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
