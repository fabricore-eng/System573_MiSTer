#!/usr/bin/env python3
"""ATAPI completion-IRQ capture analyzer -- objective verdict (a/b/c).

Reuses read_stp_csv.Capture (auto-calibration + --map for the Quartus
trigger-term dropped-column quirk). Decodes the ddrsbm BOOT-CHECK IRQ chain
and prints a NUMBER-backed verdict, never an eyeball read.

Decisive observables (NONE are trigger terms in the default .stp, so their
data columns survive the export quirk):
  atapi  irq_out      device INTRQ level (raised for TEST UNIT READY)
         irq_pending  cleared when the host reads STATUS reg7 (handler ran)
         irq_event    1-clk event strobe (a trigger term -> may be column-dropped)
         state        S_IDLE=0 S_PKT=1 S_DATAIN=2 ...
         r_status     DRDY|DSC=0x50 at completion ; r_ireason CD|IO=0x03
  irq    I_STATUS[10] ATAPI IRQ latched into the PSX controller
         I_MASK[10]   IRQ10 enabled by the game
         irqIn_1[10]  edge-detect prior sample
  psx    ce           clk1x enable (qualifier)
  cpu    exception[4] the R3000 took an interrupt-class exception

Verdict tree:
  irq_out never high                         -> (a-dev)  device never asserted INTRQ
  irq_out high, I_STATUS[10] never high       -> (b)      asserted, NOT latched (timing/ce/wire)
  I_STATUS[10] high, I_MASK[10]==0            -> (c-mask) latched but IRQ10 masked (game/SW)
  I_STATUS[10] high, masked-in, exception[4]  -> (c-cpu)  enabled but CPU never took it
       never pulses
  exception[4] pulses, irq_pending never      -> (c-svc)  CPU took it but never serviced ATAPI
       falls / I_STATUS[10] never clears
  full chain present                          -> WORKS    delivery OK; bug is elsewhere

Usage:
  read_atapi_csv.py FILE [--map "..."] [--shift N] [--window N]
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from read_stp_csv import Capture  # noqa: E402


def col(cap, name):
    """Return a per-row series for a bit, '0'/'1'/None.

    Handles both true scalars (irq_out) and a single bit of a tapped bus
    (I_STATUS[10], exception[4]): a bracketed name is decoded from the bus
    value so we never miss a bus member.
    """
    if name.endswith("]") and "[" in name:
        base, _, idx = name[:-1].rpartition("[")
        b = int(idx)
        bus = busv(cap, base)
        if bus is None:
            # fall back: maybe it was tapped as a standalone scalar channel
            try:
                return cap.bit_series(name)
            except SystemExit:
                return None
        return [None if v is None else ("1" if (v >> b) & 1 else "0") for v in bus]
    try:
        return cap.bit_series(name)
    except SystemExit:
        return None


def busv(cap, name):
    try:
        return cap.bus_series(name)
    except SystemExit:
        return None


def edges(series, frm, to):
    return [i for i in range(1, len(series))
            if series[i] == to and series[i - 1] == frm]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--map", dest="chmap", default=None)
    ap.add_argument("--shift", type=int, default=None)
    ap.add_argument("--window", type=int, default=12,
                    help="rows of context around the trigger to print")
    args = ap.parse_args()

    cap = Capture(args.file, shift=args.shift, chmap=args.chmap, quiet=False)
    print()

    irq_out  = col(cap, "irq_out")
    irq_pend = col(cap, "irq_pending")
    irq_evt  = col(cap, "irq_event")
    ce       = col(cap, "ce")
    istat10  = col(cap, "I_STATUS[10]")
    imask10  = col(cap, "I_MASK[10]")
    irqin1   = col(cap, "irqIn_1[10]")
    exc4     = col(cap, "exception[4]")
    state    = busv(cap, "state")
    rstatus  = busv(cap, "r_status")
    rireason = busv(cap, "r_ireason")
    istat    = busv(cap, "I_STATUS")
    imask    = busv(cap, "I_MASK")

    n = cap.n

    def hi(series):
        return sum(1 for v in (series or []) if v == "1")

    print("=== signal activity (high-sample counts over %d rows) ===" % n)
    for nm, s in [("irq_out", irq_out), ("irq_pending", irq_pend),
                  ("irq_event", irq_evt), ("ce", ce),
                  ("I_STATUS[10]", istat10), ("I_MASK[10]", imask10),
                  ("irqIn_1[10]", irqin1), ("exception[4]", exc4)]:
        if s is None:
            print(f"  {nm:14s}: MISSING (column dropped/not found)")
        else:
            print(f"  {nm:14s}: high={hi(s):5d}  rises={len(edges(s,'0','1'))}"
                  f"  falls={len(edges(s,'1','0'))}")

    # locate an anchor: the trigger row (center pos) is mid-buffer; also find
    # the first irq_out rising edge as the event of interest.
    iout_rises = edges(irq_out, "0", "1") if irq_out else []
    istat_rises = edges(istat10, "0", "1") if istat10 else []
    anchor = iout_rises[0] if iout_rises else (n // 2)

    print(f"\n=== timeline around anchor row {cap.samples[anchor]} "
          f"(first irq_out rise{'' if iout_rises else ' MISSING -> buffer center'}) ===")
    cols = [("st", state), ("stat", rstatus), ("irs", rireason),
            ("iout", irq_out), ("ipnd", irq_pend), ("ievt", irq_evt),
            ("IS10", istat10), ("IM10", imask10), ("ii1", irqin1),
            ("exc4", exc4), ("ce", ce)]
    w = args.window
    hdr = "sample  " + " ".join(f"{nm:>4s}" for nm, _ in cols)
    print(hdr)
    for i in range(max(0, anchor - w), min(n, anchor + w + 1)):
        cells = []
        for nm, s in cols:
            if s is None:
                cells.append("   ?")
            else:
                v = s[i]
                if isinstance(v, int):
                    cells.append(f"{v:>4d}")
                else:
                    cells.append(f"{('X' if v is None else v):>4s}")
        mark = " <== anchor" if i == anchor else ""
        print(f"{cap.samples[i]:>6d}  " + " ".join(cells) + mark)

    # ---- verdict ----
    print("\n=== VERDICT ===")
    iout_hi = hi(irq_out) if irq_out else 0
    is10_hi = hi(istat10) if istat10 else 0
    im10_hi = hi(imask10) if imask10 else 0
    exc4_rise = len(edges(exc4, "0", "1")) if exc4 else 0
    ipend_fall = len(edges(irq_pend, "1", "0")) if irq_pend else 0
    is10_fall = len(edges(istat10, "1", "0")) if istat10 else 0

    if irq_out is None:
        verdict = "INCONCLUSIVE: irq_out column missing -- re-check --map (audit)."
    elif iout_hi == 0:
        verdict = ("(a-dev) DEVICE NEVER ASSERTED INTRQ on silicon. atapi irq_out "
                   "stayed low through the capture -- the device-side IRQ raise "
                   "(atapi.v:319-325 for TEST UNIT READY) did not happen, or nIEN "
                   "(r_devctl[1]) masked it. Check r_devctl + that the gate command ran.")
    elif istat10 is None:
        verdict = "INCONCLUSIVE: I_STATUS[10] column missing -- re-check --map (audit)."
    elif is10_hi == 0:
        verdict = ("(b) ASSERTED BUT NEVER LATCHED. irq_out went high but "
                   "I_STATUS[10] never set -> the rising edge was lost at the "
                   "ce-gated detector (irq.vhd:126) or the exp_irq10->irqIn(10) "
                   "wire is dead on silicon. This is the IRQ-delivery bug.")
    elif im10_hi == 0:
        verdict = ("(c-mask) LATCHED BUT IRQ10 MASKED. I_STATUS[10] set but "
                   "I_MASK[10] never high -> the game/SW never enabled IRQ10, or our "
                   "I_MASK write path drops bit10. Inspect the I_MASK timeline.")
    elif exc4 is not None and exc4_rise == 0:
        verdict = ("(c-cpu) ENABLED BUT CPU NEVER TOOK IT. I_STATUS[10] & I_MASK[10] "
                   "both high yet cpu exception[4] never pulsed -> cop0 SR(IEc)/CAUSE "
                   "mask / blockirq kept the R3000 from servicing -> handler never runs.")
    elif ipend_fall == 0 and is10_fall == 0:
        verdict = ("(c-svc) TOOK IT BUT DID NOT SERVICE ATAPI. exception[4] pulsed but "
                   "irq_pending never fell (no reg7 STATUS read) and I_STATUS[10] never "
                   "cleared (no ack write) -> the handler ran but did not service/ack the "
                   "ATAPI INTRQ, so the counter never advanced.")
    else:
        verdict = ("DELIVERY WORKS: irq_out -> I_STATUS[10] set -> "
                   f"exception[4] ({exc4_rise} pulses) -> irq_pending falls "
                   f"({ipend_fall}) / I_STATUS[10] clears ({is10_fall}). The "
                   "completion IRQ IS delivered + serviced on silicon -> the BOOT "
                   "CHECK wedge is NOT in IRQ delivery; look upstream (the command "
                   "the game actually waits on, the completion-wait SW, or a different "
                   "gate). Re-examine which event the capture actually caught.")
    print(verdict)
    print("\n(quote sample indices/counts above in any status post -- never an eyeball read.)")


if __name__ == "__main__":
    main()
