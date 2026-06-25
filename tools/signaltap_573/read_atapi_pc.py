#!/usr/bin/env python3
"""v2 ATAPI PC-trace analyzer -- WHERE does the CPU sit during the 96us stall?

Reads an atapi_irq2 capture (PC[31:0] + ridx + r_status/r_ireason/r_bclo/r_bchi
+ irq_out/irq_pending/I_STATUS[10]/I_MASK[10] + ce). Finds the IRQ latch
(I_STATUS[10] rise), then over the aftermath:
  - histograms the CPU PC, bucketed by region, to reveal where the CPU is
    stuck (BIOS/kernel IRQ dispatcher 0x80000xxx, game ATAPI driver/handler
    0x803cbxxx, the ch5 DMA routine ~0x803cddb8, a bounded wait loop, etc.);
  - reports whether the data-in index ridx ADVANCES (data draining) or is
    stuck, and whether DRQ (r_status bit3) ever clears (phase completes).
Emits a region verdict pointing at suspect (a) dispatcher vs (c) ch5 DMA.

Usage: read_atapi_pc.py FILE [--map "..."] [--shift N]
"""
import argparse, os, sys
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from read_stp_csv import Capture  # noqa: E402

# named code landmarks (program addrs, base 0x803c0000 game + BIOS region)
LANDMARKS = {
    0x80000080: "BIOS general-exception vector",
    0x803cb2dc: "ATAPI IRQ10 handler entry",
    0x803cb304: "  handler: read reg7 status (INTRQ ack)",
    0x803cb4b8: "drive-check completion-wait (spins on counter)",
    0x803cba40: "drive-check driver (issues PACKET+CDB)",
    0x803cb010: "status-wait helper (bounded, mask 0x88)",
    0x803cb104: "post-cmd BSY/DRQ wait (bounded)",
    0x803cddb8: "ch5 DMA arm routine",
    0x803cb284: "PIO drain loop (reg0 lhu)",
}


def region(pc):
    if pc is None:
        return "X"
    if pc == 0x80000080 or (0x80000000 <= pc <= 0x80000fff):
        return "BIOS exc-vector/dispatcher (0x80000xxx)"
    if 0x80001000 <= pc <= 0x8000ffff:
        return "BIOS/kernel low (0x8000xxxx)"
    if 0xbfc00000 <= pc <= 0xbfc7ffff:
        return "BIOS ROM (0xbfc.....)"
    if 0x803cb000 <= pc <= 0x803cbfff:
        return "game ATAPI driver/ISR (0x803cbxxx)"
    if 0x803cc000 <= pc <= 0x803cefff:
        return "game ATAPI/DMA helpers (0x803cc-e)"
    if 0x803c0000 <= pc <= 0x803cffff:
        return "game code (0x803cxxxx)"
    if 0x80010000 <= pc <= 0x803bffff:
        return "kernel/heap (0x800x-0x803b)"
    return f"other (0x{pc:08x} hi)"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--map", dest="chmap", default=None)
    ap.add_argument("--shift", type=int, default=None)
    ap.add_argument("--top", type=int, default=14)
    args = ap.parse_args()

    c = Capture(args.file, shift=args.shift, chmap=args.chmap, quiet=False)
    print()
    pc = c.bus_series("PC")
    ridx = c.bus_series("ridx")
    rstat = c.bus_series("r_status")
    bclo = c.bus_series("r_bclo"); bchi = c.bus_series("r_bchi")
    istat = c.bus_series("I_STATUS") if c.has_bus("I_STATUS") else None
    is10 = None
    if c.has_bus("I_STATUS"):
        is10 = [None if v is None else ((v >> 10) & 1) for v in c.bus_series("I_STATUS")]
    else:
        try: is10 = [1 if x == "1" else (0 if x == "0" else None) for x in c.bit_series("I_STATUS[10]")]
        except SystemExit: is10 = None
    ipend = c.bit_series("irq_pending") if c.has_bit("irq_pending") else None
    iout = c.bit_series("irq_out") if c.has_bit("irq_out") else None
    n = c.n

    # locate the latch (I_STATUS[10] 0->1) as the stall start
    latch = None
    if is10:
        for i in range(1, n):
            if is10[i] == 1 and is10[i-1] == 0:
                latch = i; break
    start = latch if latch is not None else 0
    print(f"=== latch (I_STATUS[10] rise) at row {c.samples[start] if latch is not None else 'NOT FOUND -> using row 0'} ===")

    # byte count at the event (transfer size: 0x0800 sector vs small cmd)
    def at(series, i):
        return series[i] if (series and 0 <= i < len(series)) else None
    bc = None
    for i in range(start, min(n, start+40)):
        if at(bchi,i) is not None and at(bclo,i) is not None and (bchi[i] or bclo[i]):
            bc = (bchi[i] << 8) | bclo[i]; break
    print(f"byte count near event: {('0x%04x (%d)' % (bc, bc)) if bc else 'n/a'}"
          f"  -> {'SECTOR read (2048)' if bc==0x800 else ('small drive-check cmd' if bc else '?')}")

    # PC histogram over the stall window (latch -> ack or buffer end)
    end = n
    if ipend:  # stall ends when irq_pending falls (handler finally acked)
        for i in range(start+1, n):
            if ipend[i] == "0" and ipend[i-1] == "1":
                end = i; break
    win = list(range(start, end))
    span_us = (end-start)/67.7  # clk2x ~67.7MHz
    print(f"stall window rows {start}..{end} ({end-start} samples ~= {span_us:.1f} us @clk2x)\n")

    pcw = [pc[i] for i in win if pc[i] is not None]
    cnt = Counter(pcw)
    print(f"=== top {args.top} PC values during the stall ===")
    for v, k in cnt.most_common(args.top):
        lm = LANDMARKS.get(v, "")
        print(f"  0x{v:08x}  x{k:5d}  {region(v)}{('  <-- '+lm) if lm else ''}")

    print("\n=== PC time by region ===")
    regc = Counter(region(v) for v in pcw)
    tot = sum(regc.values()) or 1
    for r, k in regc.most_common():
        print(f"  {k*100//tot:3d}%  ({k:5d})  {r}")

    # drain check: does ridx advance? does DRQ ever clear?
    ridxw = [ridx[i] for i in win if ridx[i] is not None]
    rmin, rmax = (min(ridxw), max(ridxw)) if ridxw else (None, None)
    drq = [(rstat[i] >> 3) & 1 for i in win if rstat[i] is not None]
    drq_clears = (0 in drq) and (1 in drq)
    print("\n=== drain ===")
    print(f"  ridx range in window: {rmin}..{rmax}  -> {'ADVANCING (data draining)' if (rmax or 0) > (rmin or 0) else 'STUCK at %s (NO drain)'%rmin}")
    print(f"  DRQ (r_status bit3): {'clears at some point (phase progresses)' if drq_clears else 'STAYS SET (phase never completes)'}")

    # verdict
    print("\n=== VERDICT ===")
    topreg = regc.most_common(1)[0][0] if regc else "?"
    draining = (rmax or 0) > (rmin or 0)
    if "BIOS exc-vector/dispatcher" in topreg or "BIOS/kernel low" in topreg:
        print(f"(a) STALL IS IN THE KERNEL/BIOS IRQ DISPATCHER: the CPU spends the stall in {topreg}, "
              f"NOT in the game's ATAPI handler -> the dispatcher takes the IRQ10 exception but stalls/loops "
              f"before calling the registered handler (0x803cb2dc). Look at what 0x80000xxx is waiting on "
              f"(a memory read that stalls? the f2sdram bridge? a cop0/IRQ-controller readback our core gets wrong).")
    elif not draining and ("0x803cddb8" in [hex(v) for v in cnt] or any(0x803cdd00<=v<=0x803cdf00 for v in pcw)):
        print(f"(c) STALL IS THE ch5 DMA: the CPU reaches the DMA arm routine but ridx never advances -> "
              f"ch5 DMA is armed (CHCR 0x11000100) but never consumes (DMA_ATA_readEna never fires) -> data never drains.")
    elif "game ATAPI driver/ISR" in topreg and not draining:
        print(f"stall is in the game ATAPI driver/ISR ({topreg}) with NO drain -> inspect the top PC values above "
              f"against the landmarks: a bounded wait loop (0x803cb010/0x803cb104) means the driver thread is "
              f"polling a status bit our atapi.v never produces; the handler entry without a reg7 read means a "
              f"register read-back mismatch.")
    else:
        print(f"dominant region: {topreg}; draining={draining}. Inspect the top PC list + landmarks above.")
    print("\n(quote PC values + region percentages -- never an eyeball read.)")


if __name__ == "__main__":
    main()
