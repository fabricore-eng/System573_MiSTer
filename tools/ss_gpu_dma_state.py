#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# ss_gpu_dma_state.py -- STAGE-0b clean-resume predictor for the garble hunt.
#
# WHY: the decisive disambiguator for the hyperbbc graphics garble is the
# FULL-SYSTEM savestate replay (sim/system573_ssreplay): load a HW .ss, run the
# real game code forward, and tap the LIVE CLUT / drawMode the garbled 0x2C quads
# use at draw time. But that replay DEADLOCKS if the .ss was frozen mid-GPU/DMA
# (the game-over hyperbbc_garble.ss is frozen mid-DMA-ch2-linked-list: on resume
# the drawer waits forever for FIFO words the half-resumed DMA never delivers).
# A .ss frozen at an IDLE frame boundary resumes cleanly. This tool reads the
# GPU/DMA state straight out of a .ss (board-free, read-only) so we can PICK the
# resumable one out of the 5 captures the human grabbed -- without running the sim.
#
# HOW: a .ss is 1048576 little-endian 32-bit DWORDs (4 MiB) laid out per
# psx/rtl/savestates.vhd `savetypes`. Register savetypes are written 64 bits at a
# time, ss_out(k)/ss_out(k+1) -> file DWORD (savetype.offset + k)/(+k+1) with NO
# shift (verified against the SAVE FSM, savestates.vhd:390-511). So:
#     file DWORD = savetype.offset + ss_index
# Field indices are the module's own ss_out() assignments:
#   GPU       (offset 2048):  ss_gpu_out(1)=GPUSTAT  (gpu.vhd:530)
#                             drawMode = ss_gpu_in/out(3)(13:0)  (gpu.vhd:888)
#   GPUTiming (offset 3072):  ss_timing_out(4)(17)=inVsync, (3)(24:16)=vpos
#                             (gpu.vhd:537-538)
#   DMA       (offset 4096):  ss_out(2)(18:16)=activeChannel, ss_out(4)(8)=isOn,
#                             ss_out(4)(7:0)=0x07 if DMA_GPU_waiting,
#                             ss_out(4)(9)=paused, ss_out(4)(10)=gpupaused,
#                             ss_out(19+i)(8)=request[i], (11)=channelOn[i],
#                             ss_out(28+i)(23:0)=D_MADR[i], ss_out(35+i)=D_BCR[i],
#                             ss_out(42+i)=D_CHCR[i]   (dma.vhd:233-251)
#   D_CHCR(24) = enable/busy: set on start, cleared at completion (dma.vhd:884);
#   the GPU DMA channel (2) is mid-transfer iff D_CHCR(24)=1 or channelOn=1.
#
# CLEAN-RESUME gate (all must hold): D_CHCR[ch2](24)=0 AND channelOn[ch2]=0 AND
# DMA isOn=0 AND DMA_GPU_waiting=0 ; inVsync=1 is a bonus (frozen between frames).
#
# Usage:
#   ss_gpu_dma_state.py STATE.ss [STATE2.ss ...] [--slot N] [--json]
#   ss_gpu_dma_state.py --selftest
#
# Exit: 0 if >=1 input is CLEAN-RESUME (or --selftest passes); 1 otherwise; 2 usage.
# ---------------------------------------------------------------------------
import argparse
import json
import struct
import sys

SLOT_BYTES = 4 * 1024 * 1024
STATESIZE  = 0x000FFFFE          # DWORD[1] slot-valid magic (savestates.vhd:90)

# savetype DWORD bases (savestates.vhd:103-122)
GPU_OFF, GPUTIMING_OFF, DMA_OFF = 2048, 3072, 4096
GPU_DMA_CH = 2                   # PSX DMA channel 2 = GPU (gpu_dmaRequest)

# CHCR uses only these bits; anything outside => the offset model is wrong.
CHCR_VALID_MASK = 0x71770703     # bits 0,1,8-10,16-18,20-22,24,28-30


def _d(buf, base, idx):
    """Little-endian DWORD at file dword (base_slot_bytes + idx)."""
    return struct.unpack_from("<I", buf, base + idx * 4)[0]


def decode(buf, slot=0):
    """Decode GPU/DMA resume-relevant fields from slot `slot` of `buf`.
    Returns a dict (raw values + a verdict + a sanity flag)."""
    base = slot * SLOT_BYTES
    def d(i):
        return _d(buf, base, i)

    magic   = d(1)
    gpustat = d(GPU_OFF + 1)
    drawmode = d(GPU_OFF + 3) & 0x3FFF

    t3 = d(GPUTIMING_OFF + 3)
    t4 = d(GPUTIMING_OFF + 4)
    vpos    = (t3 >> 16) & 0x1FF
    invsync = (t4 >> 17) & 1

    dma2 = d(DMA_OFF + 2)
    dma4 = d(DMA_OFF + 4)
    active_chan = (dma2 >> 16) & 0x7
    isOn        = (dma4 >> 8) & 1
    paused      = (dma4 >> 9) & 1
    gpupaused   = (dma4 >> 10) & 1
    gpu_waiting = 1 if (dma4 & 0xFF) == 0x07 else 0

    ch = GPU_DMA_CH
    flags = d(DMA_OFF + 19 + ch)
    ch_request   = (flags >> 8) & 1
    ch_channelOn = (flags >> 11) & 1
    ch_madr = d(DMA_OFF + 28 + ch) & 0xFFFFFF
    ch_bcr  = d(DMA_OFF + 35 + ch)
    ch_chcr = d(DMA_OFF + 42 + ch)
    ch_busy = (ch_chcr >> 24) & 1

    # ---- offset-model sanity (the plan's "validate before trusting") ----
    sane = []
    if magic != STATESIZE:
        sane.append(f"DWORD[1]=0x{magic:08X}!=STATESIZE 0x{STATESIZE:08X}")
    if gpustat in (0x00000000, 0xFFFFFFFF):
        sane.append(f"GPUSTAT=0x{gpustat:08X} (degenerate -> offsets suspect)")
    if ch_chcr & ~CHCR_VALID_MASK:
        sane.append(f"D_CHCR[2]=0x{ch_chcr:08X} has bits outside CHCR mask "
                    f"0x{CHCR_VALID_MASK:08X} -> offsets suspect")

    # ---- clean-resume gate ----
    blockers = []
    if ch_busy:        blockers.append("D_CHCR[2].busy")
    if ch_channelOn:   blockers.append("ch2.channelOn")
    if isOn:           blockers.append(f"DMA.isOn(active ch{active_chan})")
    if gpu_waiting:    blockers.append("DMA_GPU_waiting")
    clean = (len(blockers) == 0)

    if clean:
        verdict = "CLEAN-RESUME" + ("" if invsync else " (not in vblank)")
    elif ch_busy or ch_channelOn or (isOn and active_chan == GPU_DMA_CH):
        verdict = "MID-DMA(gpu)"
    elif isOn:
        verdict = f"MID-DMA(ch{active_chan})"
    else:
        verdict = "BUSY"

    return {
        "slot": slot, "magic": magic, "sane": (len(sane) == 0), "sanity": sane,
        "gpustat": gpustat, "drawmode": drawmode,
        "drawmode8": (drawmode >> 8) & 1, "drawmode7": (drawmode >> 7) & 1,
        "vpos": vpos, "invsync": invsync,
        "active_chan": active_chan, "isOn": isOn, "paused": paused,
        "gpupaused": gpupaused, "gpu_waiting": gpu_waiting,
        "ch2_request": ch_request, "ch2_channelOn": ch_channelOn,
        "ch2_madr": ch_madr, "ch2_bcr": ch_bcr, "ch2_chcr": ch_chcr,
        "ch2_busy": ch_busy, "blockers": blockers,
        "clean_resume": clean, "verdict": verdict,
    }


def fmt_line(path, r):
    tag = "" if r["sane"] else "  [!!OFFSETS SUSPECT]"
    extra = "" if r["clean_resume"] else "  blockers=" + ",".join(r["blockers"])
    return (f"{r['verdict']:<18} {path}{tag}\n"
            f"    GPUSTAT=0x{r['gpustat']:08X} drawMode=0x{r['drawmode']:04X}"
            f"(b8={r['drawmode8']} b7={r['drawmode7']})"
            f" inVsync={r['invsync']} vpos={r['vpos']}\n"
            f"    DMA isOn={r['isOn']} activeCh={r['active_chan']}"
            f" gpu_waiting={r['gpu_waiting']} | ch2 CHCR=0x{r['ch2_chcr']:08X}"
            f" busy={r['ch2_busy']} channelOn={r['ch2_channelOn']}"
            f" MADR=0x{r['ch2_madr']:06X} BCR=0x{r['ch2_bcr']:08X}{extra}")


# ----------------------------- selftest ------------------------------------
def _synth(busy=0, channel_on=0, ison=0, gpu_waiting=0, invsync=1,
           gpustat=0x1480_2000, drawmode=0x0188):
    buf = bytearray(SLOT_BYTES)
    def put(idx, val):
        struct.pack_into("<I", buf, idx * 4, val & 0xFFFFFFFF)
    put(1, STATESIZE)
    put(GPU_OFF + 1, gpustat)
    put(GPU_OFF + 3, drawmode & 0x3FFF)
    put(GPUTIMING_OFF + 3, (123 & 0x1FF) << 16)            # vpos=123
    put(GPUTIMING_OFF + 4, (invsync & 1) << 17)
    put(DMA_OFF + 2, (GPU_DMA_CH << 16) if ison else 0)    # activeChannel
    put(DMA_OFF + 4, (0x07 if gpu_waiting else 0x00) | (ison << 8))
    put(DMA_OFF + 19 + GPU_DMA_CH, (channel_on & 1) << 11)
    put(DMA_OFF + 28 + GPU_DMA_CH, 0x001234)               # MADR
    put(DMA_OFF + 35 + GPU_DMA_CH, 0x00010001)             # BCR
    put(DMA_OFF + 42 + GPU_DMA_CH, (busy & 1) << 24 | 0x401)  # CHCR (+legal bits)
    return bytes(buf)


def selftest():
    fails = []
    def check(cond, msg):
        print(("  PASS  " if cond else "  FAIL  ") + msg)
        if not cond:
            fails.append(msg)

    idle = decode(_synth(busy=0, channel_on=0, ison=0, gpu_waiting=0, invsync=1))
    check(idle["clean_resume"], "all-idle .ss -> CLEAN-RESUME")
    check(idle["sane"], "all-idle .ss passes offset sanity")
    check(idle["drawmode8"] == 1, "drawMode bit8 decoded (0x188 -> 1)")

    busy = decode(_synth(busy=1, ison=1))
    check(not busy["clean_resume"], "CHCR.busy .ss -> NOT clean")
    check(busy["verdict"] == "MID-DMA(gpu)", "CHCR[2].busy -> MID-DMA(gpu)")
    check("D_CHCR[2].busy" in busy["blockers"], "busy blocker named")

    chon = decode(_synth(channel_on=1))
    check(not chon["clean_resume"], "channelOn .ss -> NOT clean")

    otherdma = decode(_synth(ison=1, busy=0))  # active_chan defaults to 2 here
    check(not otherdma["clean_resume"], "DMA isOn .ss -> NOT clean")

    nowait = decode(_synth(gpu_waiting=1))
    check(not nowait["clean_resume"], "DMA_GPU_waiting .ss -> NOT clean")

    # offset-model guard: a CHCR with junk bits must flip the sanity flag.
    bad = bytearray(_synth())
    struct.pack_into("<I", bad, (DMA_OFF + 42 + GPU_DMA_CH) * 4, 0x0800_0000)
    check(not decode(bytes(bad))["sane"], "out-of-mask CHCR -> sanity flag trips")

    print("-" * 43)
    if fails:
        print(f"ss_gpu_dma_state selftest: {len(fails)} FAIL")
        return 1
    print("ss_gpu_dma_state selftest: ALL PASS")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(
        description="Predict clean-resume (GPU/DMA idle) for a 573 savestate")
    ap.add_argument("states", nargs="*", help="input savestate(s) (.ss)")
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.states:
        ap.error("at least one STATE.ss required (or --selftest)")

    results = []
    for path in args.states:
        try:
            with open(path, "rb") as f:
                buf = f.read()
        except OSError as e:
            print(f"ERROR: {path}: {e}", file=sys.stderr)
            continue
        if len(buf) < (args.slot + 1) * SLOT_BYTES:
            print(f"ERROR: {path}: {len(buf)} bytes, too small for slot {args.slot}",
                  file=sys.stderr)
            continue
        results.append((path, decode(buf, args.slot)))

    if args.json:
        print(json.dumps([{"path": p, **r} for p, r in results], indent=2))
    else:
        for p, r in results:
            print(fmt_line(p, r))
        clean = [p for p, r in results if r["clean_resume"]]
        print("\n=== ranking ===")
        # prefer in-vblank clean, then any clean, then least-busy
        def rank(pr):
            _, r = pr
            return (not r["clean_resume"], not r["invsync"], r["ch2_busy"],
                    r["isOn"])
        for p, r in sorted(results, key=rank):
            print(f"  {r['verdict']:<22} {p}")
        if clean:
            best = sorted(results, key=rank)[0][0]
            print(f"\nRECOMMENDED Stage-1 subject: {best}")
        else:
            print("\nNO clean-resume candidate among inputs -> Fallback A "
                  "(headless idle-frame capture) or Fallback B (cold prefix replay).")

    return 0 if any(r["clean_resume"] for _, r in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
