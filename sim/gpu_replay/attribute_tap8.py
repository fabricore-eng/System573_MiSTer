#!/usr/bin/env python3
"""attribute_tap8.py -- ATTRIBUTION join for the hyperbbc all-491 menu replay.

The forensic discipline (hard-won, see memory/garble-fix-plan): NEVER judge the
garble by "wrong colors exist in a bbox". Instead, JOIN each final OUT pixel to
the PIX event that produced it (same coord, most-recent-prior), read that PIX's
s1tag (the pixel's INTENDED CLUT row = stage1_palReqY) and palY (the RESIDENT
CLUT row at sample time), and decode which CLUT row the OUT color actually came
from. A pixel is "garbled" iff its OUT color decodes to a row != its OWN s1tag.

tap8.log line grammar (from tb_gpu_replay.vhd dbg_tap8):
  IN  tag=<hex9> in480=<d> in491=<d> intex=<d>
  PIX x=<hex10> y=<hex9> tex=<'0'|'1'> dm=<hex14> mode=<2ch> cacheWord=<hex64>
      clutAddrB=<hex8> clutDataB=<hex16> palY=<hex9> s1tag=<hex9>
      palReqY=<hex9> palReq=<'0'|'1'> pstall=<'0'|'1'>
  OUT x=<hex10> y=<hex9> pixelColor=<hex16>

Usage: attribute_tap8.py <tap8.log> <vram.bin> [rows...]
  rows default = 480..509 (the candidate neighbor band) + 491.
"""
import sys, re, struct
from collections import Counter, defaultdict

logpath = sys.argv[1]
vrampath = sys.argv[2]
rows = [int(x) for x in sys.argv[3:]] or list(range(480, 510))
PANEL_ROW = 491

W = 1024
vram = open(vrampath, "rb").read()
def clut_row(y):
    return [struct.unpack_from("<H", vram, (y * W + x) * 2)[0] for x in range(16)]
palettes = {r: clut_row(r) for r in rows}
# RGB555 value -> set of rows whose 16-entry palette contains it (any index)
val2rows = defaultdict(set)
for r, pal in palettes.items():
    for v in pal:
        val2rows[v].add(r)

def hx(s):
    return int(s, 16)

def s1_to_decimal(h):
    # s1tag/palY are 9-bit hex; value is the CLUT row (decimal)
    return int(h, 16)

# Parse. Maintain a per-coord stack of recent PIX records so each OUT joins to
# the most-recent-prior PIX at the SAME (x,y). (Pipeline is in-order per coord.)
pix_at = defaultdict(list)   # (x,y) -> list of dicts in emission order
n_pix = 0
n_out = 0
n_in = 0

re_pix = re.compile(
    r"PIX x=([0-9a-fA-F]+) y=([0-9a-fA-F]+) tex=('?\w'?) .*?"
    r"clutAddrB=([0-9a-fA-F]+) clutDataB=([0-9a-fA-F]+) palY=([0-9a-fA-F]+) "
    r"s1tag=([0-9a-fA-F]+) palReqY=([0-9a-fA-F]+) palReq=('?\w'?) pstall=('?\w'?)")
re_out = re.compile(r"OUT x=([0-9a-fA-F]+) y=([0-9a-fA-F]+) pixelColor=([0-9a-fA-F]+)")

# Attribution tallies (keyed by the pixel's OWN s1tag)
joined = 0
own_row_hits = 0          # OUT color decodes to s1tag's palette
wrong_row_hits = 0        # OUT color decodes to some OTHER candidate row, NOT s1tag
black = 0                 # OUT color == 0 (index0 / clear)
ambig = 0                 # OUT color in multiple candidate rows (incl s1tag) -> count as own
unattrib = 0              # OUT color not in any candidate row's palette
wrong_breakdown = Counter()   # which wrong row did garbled pixels resolve to
# Race witnesses: PIX where palY != s1tag (resident row != intended) while palReq pending
race_pix = 0
race_pix_palY = Counter()
tex_pix = 0

with open(logpath) as f:
    for line in f:
        if line.startswith("IN "):
            n_in += 1
            continue
        m = re_pix.search(line)
        if m:
            n_pix += 1
            x = hx(m.group(1)); y = hx(m.group(2))
            tex = '1' in m.group(3)
            s1tag = s1_to_decimal(m.group(7))
            palY = s1_to_decimal(m.group(6))
            palReq = '1' in m.group(9)
            rec = dict(x=x, y=y, tex=tex, s1tag=s1tag, palY=palY, palReq=palReq)
            pix_at[(x, y)].append(rec)
            if tex:
                tex_pix += 1
                # RACE WITNESS: resident row differs from this pixel's intended row
                if palY != s1tag:
                    race_pix += 1
                    race_pix_palY[palY] += 1
            continue
        m = re_out.search(line)
        if m:
            n_out += 1
            x = hx(m.group(1)); y = hx(m.group(2))
            color = hx(m.group(3)) & 0x7FFF   # RGB555 (drop mask bit)
            stack = pix_at.get((x, y))
            if not stack:
                continue
            rec = stack.pop(0)   # FIFO: oldest unconsumed PIX at this coord
            if not rec["tex"]:
                continue
            joined += 1
            own = rec["s1tag"]
            if color == 0:
                black += 1
                continue
            hitrows = val2rows.get(color)
            if hitrows is None:
                unattrib += 1
            elif own in hitrows:
                # color is consistent with the pixel's OWN intended row
                if len(hitrows) == 1:
                    own_row_hits += 1
                else:
                    ambig += 1
            else:
                # color matches a candidate row that is NOT this pixel's intended row
                wrong_row_hits += 1
                for r in hitrows:
                    wrong_breakdown[r] += 1

print(f"tap8.log: IN={n_in} PIX={n_pix} OUT={n_out}  (tex PIX={tex_pix})")
print(f"JOINED textured OUT pixels (s1tag<-coord<-OUT): {joined}")
print(f"  own-row hits (OUT color == this pixel's OWN s1tag palette, unambiguous): {own_row_hits}")
print(f"  ambiguous (color in multiple rows incl own)                            : {ambig}")
print(f"  black (idx0/clear)                                                     : {black}")
print(f"  unattributed (color not in any candidate row palette)                  : {unattrib}")
print(f"  *** WRONG-ROW hits (OUT decodes to a row != own s1tag) ***             : {wrong_row_hits}")
if wrong_breakdown:
    print("      wrong-row breakdown:", dict(wrong_breakdown))
print()
print(f"RACE WITNESS (PIX where resident palY != intended s1tag): {race_pix} of {tex_pix} tex PIX")
if race_pix_palY:
    print("   resident palY seen during a mismatch:", dict(race_pix_palY))
print()
# Verdict
if joined == 0:
    print("VERDICT: NO textured pixels joined -- poly path drew nothing (preload passthrough). INCONCLUSIVE.")
elif wrong_row_hits == 0 and race_pix == 0:
    print(f"VERDICT: CLEAN. All {own_row_hits+ambig} attributable textured pixels resolved their OWN intended CLUT row; "
          f"resident palY never diverged from s1tag. Sim did NOT reproduce the garble.")
else:
    print(f"VERDICT: GARBLE PRESENT. {wrong_row_hits} pixels resolved a wrong CLUT row; {race_pix} race-witness PIX.")
