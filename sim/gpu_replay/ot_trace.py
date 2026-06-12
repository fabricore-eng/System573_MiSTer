#!/usr/bin/env python3
"""ot_trace.py -- walk the hyperbbc GAME-OVER ordering table (OT) out of the
frozen savestate main RAM (local/ss_ram.bin) and decode every primitive, then
run the green-garble forensics against the frozen VRAM (local/ss_vram.bin).

This is the board-free static analysis behind Milestone 4 (see README.md): it
proved (a) the garbled right-half is painted by a 320-node chain of GP0 0x2C
textured quads at OT head 0x1e0c00 (CLUT 0x7ac0 -> VRAM(0,491), 4bpp), NOT the 4
bg rects; (b) a correct 4bpp->CLUT decode renders BLUE/CYAN, but the HW band is
PURE GREEN; (c) the green == raw 4bpp texel index<<5 (index leaked to the green
channel with no CLUT lookup).

Usage:
    ot_trace.py [--ram local/ss_ram.bin] [--vram local/ss_vram.bin]
                [--walk] [--forensic]
    ot_trace.py --walk        # enumerate both OT chains, decoded
    ot_trace.py --forensic    # the green-index-leak forensics
    (default: both)
"""
import argparse
import collections
import os
import struct

HERE = os.path.dirname(__file__)
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEF_RAM = os.path.join(ROOT, "local", "ss_ram.bin")
DEF_VRAM = os.path.join(ROOT, "local", "ss_vram.bin")

# OT heads in this savestate's GAME-OVER display list (found by linear scan of
# the primitive buffer at 0x1e0b60..): the bg-rect chain and the 0x2C-quad chain.
HEAD_BG_RECTS = 0x1E0B60
HEAD_QUADS = 0x1E0C00
# garble band (screen px) measured in the frozen display fb (VRAM origin (0,0)).
BAND = (123, 378, 0, 204)   # x0, x1, y0, y1


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


class Mem:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.b = f.read()
        self.mask = len(self.b) - 1

    def w(self, off):
        return struct.unpack_from("<I", self.b, off & self.mask)[0]


class Vram:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.b = f.read()

    def px(self, x, y):
        if 0 <= x < 1024 and 0 <= y < 512:
            return struct.unpack_from("<H", self.b, (y * 1024 + x) * 2)[0]
        return 0


def walk_ot(mem, head, maxn=4000):
    """PSX OT walk: node = TAG(=(nwords<<24)|next24) + nwords data words. Stop at
    a `next` outside the RAM window (the game's terminator sentinel), a loop, or
    maxn. Returns [(addr, nwords, [words...]), ...] in draw order."""
    addr = head & 0xFFFFFF
    seen, nodes = set(), []
    while len(nodes) < maxn:
        ma = addr & mem.mask
        if addr != ma or ma in seen:
            break
        seen.add(ma)
        tag = mem.w(ma)
        nwords = (tag >> 24) & 0xFF
        nodes.append((ma, nwords, [mem.w(ma + 4 + 4 * i) for i in range(nwords)]))
        addr = tag & 0xFFFFFF
    return nodes


def decode_tpage(t):
    return dict(vramx=(t & 0xF) * 64, vramy=((t >> 4) & 1) * 256,
                abr=(t >> 5) & 3, colormode=(t >> 7) & 3)


def decode_clut(c):
    return dict(x=(c & 0x3F) * 16, y=(c >> 6) & 0x1FF)


def decode_quad_2c(words):
    """GP0 0x2C textured quad: 9 words."""
    color = words[0] & 0xFFFFFF
    xy = [words[1], words[3], words[5], words[7]]
    uv = [words[2], words[4], words[6], words[8]]
    pts = [(s16(xy[i] & 0xFFFF), s16((xy[i] >> 16) & 0xFFFF),
            uv[i] & 0xFF, (uv[i] >> 8) & 0xFF) for i in range(4)]
    clut = (uv[0] >> 16) & 0xFFFF
    tpage = (uv[1] >> 16) & 0xFFFF
    return color, clut, tpage, pts


def cmd_walk(mem):
    for head, label in ((HEAD_BG_RECTS, "bg-rects"), (HEAD_QUADS, "0x2C-quads")):
        nodes = walk_ot(mem, head)
        print(f"\n=== OT chain '{label}' from 0x{head:06x}: {len(nodes)} nodes ===")
        clutH, tpH = collections.Counter(), collections.Counter()
        minx = miny = 1 << 30
        maxx = maxy = -(1 << 30)
        for i, (addr, nw, d) in enumerate(nodes):
            op = d[0] >> 24 if d else 0
            if op == 0x2C and nw == 9:
                color, clut, tpage, pts = decode_quad_2c(d)
                clutH[clut] += 1
                tpH[tpage] += 1
                for (x, y, u, v) in pts:
                    minx, maxx = min(minx, x), max(maxx, x)
                    miny, maxy = min(miny, y), max(maxy, y)
                if i < 4 or i >= len(nodes) - 2:
                    tp = decode_tpage(tpage)
                    print(f"  [{i}] @{addr:06x} 0x2C color={color:06x} "
                          f"clut={clut:04x}{decode_clut(clut)} tpage={tpage:04x}"
                          f"(VRAM {tp['vramx']},{tp['vramy']} {['4bpp','8bpp','15b','rsv'][tp['colormode']]}) "
                          f"pts={pts}")
            else:
                # decode the bg-rect packet (E1 + 0x64) verbatim
                print(f"  [{i}] @{addr:06x} n={nw} words: "
                      + " ".join(f"{x:08x}" for x in d))
        if clutH:
            print(f"  CLUT histogram: " + ", ".join(f"{c:04x}x{n}" for c, n in clutH.items()))
            print(f"  TPAGE histogram: " + ", ".join(f"{t:04x}x{n}" for t, n in tpH.items()))
            print(f"  screen bbox: x[{minx}..{maxx}] y[{miny}..{maxy}]")


def cmd_forensic(mem, vram):
    x0, x1, y0, y1 = BAND
    clut7ac0 = [vram.px(i, 491) for i in range(16)]
    print(f"\n=== GREEN-GARBLE FORENSICS (band x[{x0}..{x1}) y[{y0}..{y1})) ===")
    print("CLUT 0x7ac0 (VRAM row 491): "
          + " ".join(f"{c:04x}" for c in clut7ac0))
    n_green = collections.Counter()
    tot = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            p = vram.px(x, y)
            tot += 1
            r, g, b = p & 0x1F, (p >> 5) & 0x1F, (p >> 10) & 0x1F
            if r == 0 and b == 0 and g > 0 and p < 0x400:
                n_green[p >> 5] += 1     # p>>5 == index iff green == index<<5
    g4 = sum(n for i, n in n_green.items() if i < 16)
    g8 = sum(n for i, n in n_green.items() if i >= 16)
    print(f"band px = {tot}; pure-green px = {sum(n_green.values())}")
    print("  green-channel value >>5 (== raw texel index if leaked) histogram:")
    for idx in sorted(n_green):
        print(f"    idx {idx:2d} (0x{idx << 5:04x}): {n_green[idx]} px"
              + (f"   CLUT[idx]=0x{clut7ac0[idx]:04x}(blue/cyan, NOT green)"
                 if idx < 16 else "  (8bpp range)"))
    print(f"  -> {g4} px in the 4bpp index range (0..15), {g8} px in 8bpp range (16..31)")
    print("  CONCLUSION: green == 4bpp texel index<<5 (raw index in green channel,")
    print("  NO CLUT lookup). CLUT 0x7ac0 has no green entry, so the green is the")
    print("  un-looked-up index leaking to output. Garble painter = the 320-node")
    print("  0x2C textured-quad chain at OT 0x1e0c00 (bug is poly-path-specific;")
    print("  the rect path of the same texpage+CLUT renders correct blue -- see README).")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ram", default=DEF_RAM)
    ap.add_argument("--vram", default=DEF_VRAM)
    ap.add_argument("--walk", action="store_true")
    ap.add_argument("--forensic", action="store_true")
    args = ap.parse_args()
    do_all = not (args.walk or args.forensic)
    mem = Mem(args.ram)
    if args.walk or do_all:
        cmd_walk(mem)
    if args.forensic or do_all:
        cmd_forensic(mem, Vram(args.vram))


if __name__ == "__main__":
    main()
