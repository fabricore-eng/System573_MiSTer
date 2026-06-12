#!/usr/bin/env python3
"""Build the 2MB-VRAM red/green proof stream for tb_gpu_replay (psx_patches/0021).

Replays, against a COLD (all-zero) VRAM, the exact boot-time upload set that
corrupts the hyperbbc font atlas on real HW when the GPU truncates Y to 9 bits:

    A0 (384,  0) 32x40    font upload 1   (lower half -- always lands)
    A0 (384, 64) 32x64    font upload 2
    A0 (384,128) 32x128   font upload 3
    A0 (320,512) 92x240   comic panel A   (UPPER half -- wraps onto y-512 on 1MB)
    A0 (416,512) 92x240   comic panel B   (UPPER half)
  then reads three regions back through the GPU's own vram2cpu path:
    C0 (384,  0) 32x256   R1 = the atlas column   (the red/green discriminator)
    C0 (320,512) 92x240   R2 = panel A home
    C0 (416,512) 92x240   R3 = panel B home

Payloads are MAME ground truth, extracted from the 2MB VRAM dump
local/mame_gate_hunt/gh_vram_comic.bin (verified stable: the gate17 atlas
snapshots f00220/f02400/f05400 are 100% identical to it in this region).
tb_gpu_replay logs every vram2cpu word to build/vram2cpu_out.log; the
companion check_vram2mb.py asserts the red (stock 0020) wrap signature and
the green (0021) correct placement against the same dump.

Usage: gen_vram2mb.py <gh_vram_comic.bin> <out_cmd.txt>
"""
import sys
import numpy as np

GP0 = 0
GP1 = 4
STEP = 3          # clk1x ticks per word: cpu2vram consumes ~1 word/clk1x, so no FIFO overrun


def main():
    comic_path, out_path = sys.argv[1], sys.argv[2]
    vram = np.fromfile(comic_path, dtype="<u2")
    assert vram.size == 1024 * 1024, f"expected 2MB VRAM dump, got {vram.size*2} bytes"
    vram = vram.reshape(1024, 1024)

    lines = []
    t = [200]

    def emit(addr, data, comment=None):
        if comment:
            lines.append(f"# {comment}")
        lines.append(f"{addr:08X} {t[0]:08X} {data & 0xFFFFFFFF:08X}")
        t[0] += STEP

    def a0(x, y, w, h, comment):
        region = vram[y:y + h, x:x + w]
        px = region.flatten()
        assert px.size == w * h and px.size % 2 == 0
        emit(GP0, 0xA0000000, f"A0 ({x},{y}) {w}x{h} -- {comment}")
        emit(GP0, ((y & 0xFFFF) << 16) | (x & 0xFFFF))
        emit(GP0, ((h & 0xFFFF) << 16) | (w & 0xFFFF))
        for i in range(0, px.size, 2):
            emit(GP0, (int(px[i + 1]) << 16) | int(px[i]))

    def c0(x, y, w, h, comment):
        emit(GP0, 0xC0000000, f"C0 ({x},{y}) {w}x{h} -- {comment}")
        emit(GP0, ((y & 0xFFFF) << 16) | (x & 0xFFFF))
        emit(GP0, ((h & 0xFFFF) << 16) | (w & 0xFFFF))

    emit(GP1, 0x00000000, "GP1 reset")
    t[0] += 200

    # the three boot font uploads (payload = the comic-time atlas content; the
    # gate17 ledger shows the same bytes are re-uploaded every attract loop)
    a0(384, 0, 32, 40, "font upload 1")
    a0(384, 64, 32, 64, "font upload 2")
    a0(384, 128, 32, 128, "font upload 3")
    # the two upper-half comic panel uploads from the corrected ledger
    a0(320, 512, 92, 240, "comic panel A (upper half)")
    a0(416, 512, 92, 240, "comic panel B (upper half)")

    t[0] += 200
    c0(384, 0, 32, 256, "R1 readback: atlas column")
    t[0] += 6000     # let R1 (4096 words) drain before queueing more headers
    c0(320, 512, 92, 240, "R2 readback: panel A home")
    t[0] += 14000    # let R2 (11040 words) drain
    c0(416, 512, 92, 240, "R3 readback: panel B home")

    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    nwords = sum(1 for l in lines if not l.startswith("#"))
    print(f"wrote {out_path}: {nwords} bus words, last tick 0x{t[0]:X} "
          f"({t[0]*30/1e6:.2f} ms of clk1x)")


if __name__ == "__main__":
    main()
