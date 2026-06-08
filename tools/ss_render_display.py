#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# ss_render_display.py -- render the EXACT displayed frame from a savestate.
#
# A .ss freezes VRAM (the framebuffer) AND the GPU display registers, so the
# image that was being scanned out at that instant is fully determined by the
# savestate -- no separate hardware screenshot needed, and no frame-timing
# mismatch. This renders that exact frame.
#
# The displayed region is the GPU "display area start" (GP1 05 -> vramRange) +
# the resolution (GPUSTAT). Saved at (verified vs gpu.vhd):
#   GPUSTAT   = savetype 1 (GPU,      off 2048) index 1  -> file DWORD 2049
#   vramRange = savetype 2 (GPUTiming, off 3072) index 2  -> file DWORD 3074
#       DisplayOffsetX = vramRange[9:0]   (gpu_videoout_sync.vhd:278)
#       DisplayOffsetY = vramRange[18:10] (gpu_videoout_sync.vhd:279)
#   width from GPUSTAT: bit16 (HorRes2)=1 -> 368; else [256,320,512,640][bits18:17]
# The displayed buffer TOGGLES between the two double-buffers each frame, so a
# fixed (0,0) render is wrong half the time -- this reads the live offset.
#
# Usage:
#   ss_render_display.py STATE.ss [--out OUT.png] [--height H] [--info]
# Needs tools/hw_display_frame.py (same dir) for the actual RGB555 render.
# ---------------------------------------------------------------------------
import argparse, os, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
VRAM_OFF = 0x100000   # savetype 15

def dword(buf, i):
    return struct.unpack_from("<I", buf, i * 4)[0]

def decode(ss):
    gpustat = dword(ss, 2049)
    hr2 = (gpustat >> 16) & 1
    hr1 = (gpustat >> 17) & 3
    interlace = (gpustat >> 19) & 1
    width = 368 if hr2 else [256, 320, 512, 640][hr1]
    vramRange = dword(ss, 3074) & 0x7FFFF
    dox = vramRange & 0x3FF
    doy = (vramRange >> 10) & 0x1FF
    # display height from vDisplayRange (savetype2 idx0 -> DWORD 3072): y2-y1
    vdr = dword(ss, 3072) & 0xFFFFF
    y1 = vdr & 0x3FF
    y2 = (vdr >> 10) & 0x3FF
    h = y2 - y1 if 0 < (y2 - y1) <= 512 else 240
    if interlace:
        h *= 2
    return dict(width=width, height=h, dox=dox, doy=doy,
                interlace=interlace, gpustat=gpustat, vramRange=vramRange)

def main(argv):
    ap = argparse.ArgumentParser(description="Render the exact displayed frame from a .ss")
    ap.add_argument("state")
    ap.add_argument("--out")
    ap.add_argument("--height", type=int, help="override display height")
    ap.add_argument("--info", action="store_true", help="print the display rect and exit")
    args = ap.parse_args(argv)

    with open(args.state, "rb") as f:
        ss = f.read()
    info = decode(ss)
    h = args.height or info["height"]
    rect = (info["dox"], info["doy"], info["width"], h)
    print(f"{os.path.basename(args.state)}: displayed = VRAM ({rect[0]},{rect[1]}) "
          f"{rect[2]}x{rect[3]}  (interlace={info['interlace']}, "
          f"GPUSTAT=0x{info['gpustat']:08X})")
    if args.info:
        return 0

    # carve the VRAM slice next to the .ss, then render the displayed window
    vram = args.state + ".vram.bin"
    with open(vram, "wb") as f:
        f.write(ss[VRAM_OFF:VRAM_OFF + 0x100000])
    out = args.out or (os.path.splitext(args.state)[0] + ".display.png")
    cmd = ["python3", os.path.join(HERE, "hw_display_frame.py"), vram,
           "--window", f"{rect[0]},{rect[1]},{rect[2]},{rect[3]}", "--out", out]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr); return r.returncode
    print(f"  -> {out} ({os.path.getsize(out)} bytes)")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
