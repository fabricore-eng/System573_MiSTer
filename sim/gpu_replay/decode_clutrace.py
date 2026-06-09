#!/usr/bin/env python3
"""Decode the clutrace direct-render .gra and classify each panel-quad pixel by
which CLUT palette row it sampled. Pure-numeric repro check (no vision).

The panel quad is drawn raw (0x2D) at screen (ox,oy)-(ox+qw,oy+qh) sampling
texpage 0x1F through CLUT 0x7ac0 (row 491). Each rendered pixel == CLUT[idx]
for some texel index idx. We reverse this: read the rendered RGB555, find which
candidate CLUT row's 16-entry palette contains that exact value, and tally the
votes. If the pixels match row 491 -> clean; row 480 -> the stale-neighbor race.

Usage: decode_clutrace.py <gra> <vram.bin> <ox> <oy> <qw> <qh> [rows...]
"""
import sys, struct
from collections import Counter

gra, vrampath = sys.argv[1], sys.argv[2]
ox, oy, qw, qh = (int(x) for x in sys.argv[3:7])
rows = [int(x) for x in sys.argv[7:]] or [480, 482, 485, 491, 500, 509]

W = 1024
vram = open(vrampath, "rb").read()
def clut(y):
    return [struct.unpack_from("<H", vram, (y * W + x) * 2)[0] for x in range(16)]
palettes = {r: clut(r) for r in rows}
# map RGB555 value -> set of rows whose palette contains it (any index)
val2rows = {}
for r, pal in palettes.items():
    for v in pal:
        val2rows.setdefault(v, set()).add(r)

# parse the .gra direct render (1024x512, RGB888 = RGB555<<3)
pix = {}
with open(gra) as f:
    f.readline()
    for line in f:
        line = line.strip()
        if not line:
            continue
        c = line.split("#")
        if len(c) != 3:
            continue
        color, x, y = int(c[0]), int(c[1]), int(c[2])
        pix[(x, y)] = color

def rgb888_to_555(c):
    r = (c >> 16) & 0xFF; g = (c >> 8) & 0xFF; b = c & 0xFF
    return (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)

# classify each pixel in the panel quad bbox
votes = Counter()       # exact-row attribution (unambiguous only)
ambig = 0
nonpanel = 0
black = 0
total = 0
sample_vals = Counter()
for y in range(oy, oy + qh):
    for x in range(ox, ox + qw):
        c = pix.get((x, y))
        if c is None:
            continue
        total += 1
        v = rgb888_to_555(c)
        sample_vals[v] += 1
        if v == 0:
            black += 1
            continue
        hit = val2rows.get(v)
        if hit is None:
            nonpanel += 1
        elif len(hit) == 1:
            votes[next(iter(hit))] += 1
        else:
            ambig += 1

print(f"panel bbox ({ox},{oy})-({ox+qw},{oy+qh})  pixels rendered={total}")
print(f"  black(idx0/clear)={black}  not-in-any-candidate-row={nonpanel}  ambiguous(shared val)={ambig}")
print(f"  UNAMBIGUOUS palette-row votes: {dict(votes)}")
# Decisive verdict on the candidate rows of interest
if votes:
    winner = votes.most_common(1)[0]
    print(f"  -> dominant row = {winner[0]} ({winner[1]} px)")
# Show the top rendered RGB555 values for manual cross-check
print("  top rendered RGB555 vals:",
      [f"{v:04x}x{n}" for v, n in sample_vals.most_common(8)])
# per-row exact-color membership of the top vals (disambiguates)
print("  --- top-val -> matching rows (idx) ---")
for v, n in sample_vals.most_common(8):
    if v == 0:
        continue
    matches = []
    for r, pal in palettes.items():
        for i, pv in enumerate(pal):
            if pv == v:
                matches.append(f"row{r}[{i}]")
    print(f"    {v:04x} (x{n}): {matches}")
