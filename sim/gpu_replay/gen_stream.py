#!/usr/bin/env python3
"""GP0/GP1 command-stream generator for the NVC gpu-replay rig (tb_gpu_replay).

Emits the replay text format consumed by tb_gpu_replay.vhd:
    <addr> <time> <data>        (all 8-hex; addr 00000000=GP0, 00000004=GP1)
Lines beginning with '#' are comments (ignored by the tb).

This module is the single source of truth for the byte-exact GP0/GP1 encodings
so both Milestone-1 (trivial fill/rect) and Milestone-2 (the hyperbbc bg-panel
0x2C textured-quad reconstruction) share one builder. Run with a subcommand:

    gen_stream.py demo   > cmd_fill_demo.txt      # M1: fill + flat rect
    gen_stream.py bgpanel > cmd_bgpanel.txt        # M2: textured 0x2C quads

The `time` field paces writes: we advance a generous per-word gap so the GPU's
command FIFO never overruns in sim (it is small; the replay must not push faster
than the GPU drains, or words are dropped). 8 clk1x/word is comfortable.
"""
import sys

GP0 = 0x00000000
GP1 = 0x00000004

# pacing: clk1x ticks between successive words. Generous so the FIFO drains.
STEP = 12


class Stream:
    def __init__(self, start=200):
        self.t = start
        self.lines = []

    def emit(self, addr, data, comment=None):
        if comment:
            self.lines.append(f"# {comment}")
        self.lines.append(f"{addr:08X} {self.t:08X} {data & 0xFFFFFFFF:08X}")
        self.t += STEP

    # ---- GP1 control ----
    def gp1(self, cmd, payload=0, comment=None):
        self.emit(GP1, (cmd << 24) | (payload & 0x00FFFFFF), comment)

    def gp1_reset(self):                       self.gp1(0x00, 0, "GP1 reset")
    def gp1_dispmode(self, word):              self.gp1(0x08, word, "GP1 display mode")
    def gp1_dispenable(self, on=True):         self.gp1(0x03, 0 if on else 1, "GP1 display enable")
    def gp1_dmadir(self, d):                   self.gp1(0x04, d, "GP1 DMA direction")
    def gp1_dispstart(self, x, y):             self.gp1(0x05, (x & 0x3FF) | ((y & 0x1FF) << 10), "GP1 display start VRAM")
    def gp1_hrange(self, x1, x2):              self.gp1(0x06, (x1 & 0xFFF) | ((x2 & 0xFFF) << 12), "GP1 horiz display range")
    def gp1_vrange(self, y1, y2):              self.gp1(0x07, (y1 & 0x3FF) | ((y2 & 0x3FF) << 10), "GP1 vert display range")

    # ---- GP0 ----
    def gp0(self, word, comment=None):         self.emit(GP0, word, comment)

    def draw_mode(self, texpage, comment="GP0 E1 draw mode / texpage"):
        # 0xE1: bits[10:0] = texpage attribute (tpage)
        self.gp0(0xE1000000 | (texpage & 0x7FF), comment)

    def tex_window(self, maskx, masky, offx, offy):
        v = (maskx & 0x1F) | ((masky & 0x1F) << 5) | ((offx & 0x1F) << 10) | ((offy & 0x1F) << 15)
        self.gp0(0xE2000000 | v, "GP0 E2 texture window")

    def draw_area_tl(self, x, y):
        self.gp0(0xE3000000 | (x & 0x3FF) | ((y & 0x1FF) << 10), "GP0 E3 draw area TL")

    def draw_area_br(self, x, y):
        self.gp0(0xE4000000 | (x & 0x3FF) | ((y & 0x1FF) << 10), "GP0 E4 draw area BR")

    def draw_offset(self, x, y):
        self.gp0(0xE5000000 | (x & 0x7FF) | ((y & 0x7FF) << 11), "GP0 E5 draw offset")

    def fill_vram(self, r, g, b, x, y, w, h):
        # 0x02: fill VRAM rectangle (ignores draw area / mask / blend). x,y,w,h
        # are aligned to 16 in HW; we pass as-is.
        self.gp0(0x02000000 | (b << 16) | (g << 8) | r, "GP0 02 fill VRAM")
        self.gp0((y << 16) | (x & 0xFFFF))
        self.gp0((h << 16) | (w & 0xFFFF))

    def flat_rect(self, r, g, b, x, y, w, h):
        # 0x60: monochrome variable-size flat rectangle (opaque)
        self.gp0(0x60000000 | (b << 16) | (g << 8) | r, "GP0 60 flat rect")
        self.gp0(((y & 0xFFFF) << 16) | (x & 0xFFFF))
        self.gp0(((h & 0xFFFF) << 16) | (w & 0xFFFF))

    def quad_tex_4pt(self, color, clut, tpage, verts, raw=False):
        """0x2C/0x2D: 4-point textured opaque quad. raw=True (0x2D, bit24) shows
        the texture UNBLENDED (pure CLUT colors); raw=False (0x2C) blends the
        texture with `color` (use 0x808080 for ~neutral).
        verts = [(x,y,u,v), x4]. clut = clut attr (word1 hi16), tpage = tpage
        attr (word3 hi16). Vertex order per GP0 0x2C:
          word0 = 0x2C<BBGGRR>
          w1 = clut<<16 | yx? -> actually: w1 = (Yvtx<<16|Xvtx) low? no:
        GP0 0x2C layout (4 vertices, textured, opaque, blended):
          0x2C BB GG RR
          YYYY XXXX  (v1)      | UV1 word: CLUT<<16 | (V1<<8|U1)
          CLUT  V1 U1
          YYYY XXXX  (v2)      | TPAGE<<16 | (V2<<8|U2)
          TPAGE V2 U2
          YYYY XXXX  (v3)
          0000  V3 U3
          YYYY XXXX  (v4)
          0000  V4 U4
        """
        op = 0x2D if raw else 0x2C
        self.gp0((op << 24) | (color & 0xFFFFFF),
                 f"GP0 {op:02X} textured quad (raw={raw})")
        for i, (x, y, u, v) in enumerate(verts):
            self.gp0(((y & 0xFFFF) << 16) | (x & 0xFFFF))
            if i == 0:
                self.gp0((clut << 16) | ((v & 0xFF) << 8) | (u & 0xFF))
            elif i == 1:
                self.gp0((tpage << 16) | ((v & 0xFF) << 8) | (u & 0xFF))
            else:
                self.gp0(((v & 0xFF) << 8) | (u & 0xFF))

    def rect_tex(self, color, clut, x, y, w, h, u, v, raw=False):
        """0x64/0x65: variable-size TEXTURED rectangle (sprite). Uses the gpu_rect
        rasterizer (NO divider/multiply -- avoids the poly path). The texpage comes
        from the current GP0 0xE1 draw-mode; the CLUT from word2. raw=True (0x65)
        shows pure CLUT colors; raw=False (0x64) blends with `color`.
          word0 = 0x64 <BBGGRR>   (bit26=tex, bits28:27=00 variable, bit24=raw)
          word1 = YYYY XXXX        (position)
          word2 = CLUT  VV UU      (CLUT<<16 | V<<8 | U)
          word3 = HHHH WWWW        (size)
        """
        op = 0x65 if raw else 0x64
        self.gp0((op << 24) | (color & 0xFFFFFF),
                 f"GP0 {op:02X} textured rect (raw={raw})")
        self.gp0(((y & 0xFFFF) << 16) | (x & 0xFFFF))
        self.gp0((clut << 16) | ((v & 0xFF) << 8) | (u & 0xFF))
        self.gp0(((h & 0xFFFF) << 16) | (w & 0xFFFF))

    def dump(self):
        return "\n".join(self.lines) + "\n"


def tpage_attr(tx, ty, abr=0, colors=0):
    """texpage attribute: tx in units of 64 (0..15), ty in units of 256 (0..1),
    abr (semi-transparency mode 0..3), colors (0=4bpp,1=8bpp,2=15bpp)."""
    return (tx & 0xF) | ((ty & 0x1) << 4) | ((abr & 0x3) << 5) | ((colors & 0x3) << 7)


def clut_attr(cx, cy):
    """CLUT attribute: cx in units of 16 (0..63), cy in lines (0..511)."""
    return ((cx >> 4) & 0x3F) | ((cy & 0x1FF) << 6)


# NTSC 320x240-ish display setup shared by both demos.
def display_setup_320x240(s):
    s.gp1_reset()
    # display mode word: HorRes1=01 (320), VerRes=0 (240), PAL=0, 24bpp=0,
    # interlace=0, HorRes2=0, reverse=0  -> 0x00000001
    s.gp1_dispmode(0x00000001)
    s.gp1_dispenable(True)
    s.gp1_dmadir(0)                  # off (we push via GP0 FIFO)
    s.gp1_dispstart(0, 0)
    # standard NTSC ranges (so the videoout sweeps a frame)
    s.gp1_hrange(0x200, 0x200 + 320 * 8)   # ~608.. (center); 8 cycles/px
    s.gp1_vrange(0x10, 0x10 + 240)
    # draw mode / area / offset
    s.draw_mode(tpage_attr(0, 0, 0, 0))
    s.draw_area_tl(0, 0)
    s.draw_area_br(319, 239)
    s.draw_offset(0, 0)


def build_demo():
    """M1: clear VRAM display region to dark blue, draw a red + green + white
    flat rectangle at known positions. Pure-color, no textures, no preload."""
    s = Stream()
    display_setup_320x240(s)
    # fill the whole 320x240 display region dark blue (R=0,G=0,B=0x40)
    s.fill_vram(0x00, 0x00, 0x40, 0, 0, 320, 240)
    # red 64x64 at (16,16)
    s.flat_rect(0xF8, 0x00, 0x00, 16, 16, 64, 64)
    # green 64x64 at (128,80)
    s.flat_rect(0x00, 0xF8, 0x00, 128, 80, 64, 64)
    # white 48x48 at (240,160)
    s.flat_rect(0xF8, 0xF8, 0xF8, 240, 160, 48, 48)
    return s.dump()


def build_texquad():
    """M2: draw a 4bpp textured quad sampling a real bg texpage through CLUT
    0x7ac0, into a CLEARED display region. Designed to run on a VRAM PRELOADED
    with MAME's correct title VRAM (textures + CLUT all correct). The redrawn
    quad then shows whether OUR GPU's 4bpp->CLUT sampling RTL is faithful.

    Texpage 0E sits at VRAM x=896,y=0 (tx=14 in 64px units, ty=0). 4bpp colors.
    CLUT 0x7ac0 -> attr 0x7ac0 (cx=0 in 16px units, cy=491). We sample a
    256x256 texel block (the whole page) onto a 256x256 screen quad at (32,0)
    so the redrawn texture is directly comparable to the standalone decode
    local/_mame_tp0e_4bpp.png and is NOT overlapped by MAME's pre-rendered
    framebuffer (which we clear first).

    NB: we do NOT clear the texture atlas (x>=768) or the CLUT row (y=491);
    only the display region (x 0..383, y 0..255) is cleared so the source
    texels + palette stay intact.
    """
    s = Stream()
    display_setup_320x240(s)
    tp = tpage_attr(tx=14, ty=0, abr=0, colors=0)   # texpage 0E, 4bpp
    clut = 0x7ac0                                    # title bg CLUT
    # clear the display region to black WITHOUT touching the texture/CLUT bands.
    # fill_vram 16-aligns; clear x0..383, y0..255 (well left of the x>=896 page).
    s.fill_vram(0x00, 0x00, 0x00, 0, 0, 384, 256)
    # set the texpage via E1 too (some GPUs need both the poly tpage word and E1)
    s.draw_mode(tp)
    s.tex_window(0, 0, 0, 0)                         # no UV masking (full page)
    # 256x256 textured quad at screen (32,0). UV (0,0)-(255,255) over texpage 0E.
    verts = [
        (32,   0,   0,   0),     # TL
        (32+255, 0,   255, 0),   # TR
        (32,   255, 0,   255),   # BL
        (32+255, 255, 255, 255), # BR
    ]
    s.quad_tex_4pt(0x808080, clut, tp, verts, raw=True)   # 0x2D raw: pure CLUT colors
    return s.dump()


def build_texrect(tx=14, ty=0, colors=0, clut=0x7ac0, sx=0, sy=0, w=256, h=256,
                  ox=32, oy=0, clearw=384, clearh=256):
    """M2 (rect path): draw a TEXTURED RECTANGLE (0x65 raw) sampling a texpage
    through a CLUT, into a cleared display region. Uses gpu_rect (NOT the poly
    rasterizer that hangs in NVC), so it actually renders. This is the decisive
    CLUT-sampling test: run preloaded with MAME's correct VRAM, once with the
    correct CLUT and once with our wrong CLUT, to split GPU-sampling-RTL from
    CLUT-data. colors: 0=4bpp,1=8bpp,2=15bit. tx in 64px units, ty in 256px.
    """
    s = Stream()
    display_setup_320x240(s)
    tp = tpage_attr(tx=tx, ty=ty, abr=0, colors=colors)
    s.fill_vram(0x00, 0x00, 0x00, 0, 0, clearw, clearh)   # clear display region
    s.draw_mode(tp)                                        # set texpage for the rect
    s.tex_window(0, 0, 0, 0)
    s.rect_tex(0x808080, clut, ox, oy, w, h, sx, sy, raw=True)
    return s.dump()


def build_bgpanel573():
    """Reproduce the hyperbbc GAME-OVER bg-panel garble from the REAL savestate
    display list (extracted from local/ss_ram.bin, OT head ~0x1e0b60). Four 8bpp
    textured rectangles (GP0 0x64, blended with color 0x808080) sample texpage
    X=640/768 (ty=0) through CLUT 0x7800 -> VRAM(0,480), drawn across the top of
    the screen. Designed to run PRELOADED with local/ss_vram.bin (the frozen
    savestate VRAM: textures + CLUT all in place). The EXACT raw GP0 words are
    reproduced verbatim from the display list; only the per-frame setup (display
    mode / draw area / tex window) is reconstructed (those live in GPU regs, not
    main RAM). Draw area = full panel; texture window = none (full 256x256 page),
    matching the contiguous U-runs the rects sample.

    Garble onset on HW is screen x~123, which lands INSIDE node1 (pos x=78,
    w=128) -> node1 LEFT renders clean, node1 RIGHT garbles: an in-sim
    clean-vs-garbled CONTROL on the SAME primitive.
    """
    s = Stream()
    s.gp1_reset()
    s.gp1_dispmode(0x00000001)          # 320x240 NTSC, 15bpp
    s.gp1_dispenable(True)
    s.gp1_dmadir(0)
    s.gp1_dispstart(0, 0)
    s.gp1_hrange(0x200, 0x200 + 320 * 8)
    s.gp1_vrange(0x10, 0x10 + 240)
    # draw area covering the whole panel (x 0..511 to be safe, y 0..255)
    s.draw_area_tl(0, 0)
    s.draw_area_br(511, 255)
    s.draw_offset(0, 0)
    # texture window: none (full page). E2 = 0.
    s.tex_window(0, 0, 0, 0)

    # The four real rects, verbatim. Each node = E1 (texpage) then 0x64 4-word rect.
    # (e1word, w0_color, w1_pos, w2_clut_uv, w3_size)  -- exact savestate words.
    nodes = [
        (0xe100028a, 0x64808080, 0x00000000, 0x78000032, 0x00cc004e),  # X=640 pos(0,0)   78x204 UV(50,0)
        (0xe100028a, 0x64808080, 0x0000004e, 0x78000080, 0x00cc0080),  # X=640 pos(78,0) 128x204 UV(128,0)
        (0xe100028c, 0x64808080, 0x000000ce, 0x78000000, 0x00cc0080),  # X=768 pos(206,0)128x204 UV(0,0)
        (0xe100028a, 0x64808080, 0x0000014e, 0x78000000, 0x00cc0032),  # X=640 pos(334,0) 50x204 UV(0,0)
    ]
    # Each 128x204 8bpp textured rect drains slowly (~4 clk2x/pixel). The replay
    # tb does NOT honor bus_stall, so we must give the GPU TIME to drain a rect
    # before injecting the next: advance the clock by a big gap after each rect's
    # last word. 128*204*2 clk1x (~52k) per rect is comfortable.
    RECT_DRAIN = 60000
    for (e1, w0, w1, w2, w3) in nodes:
        s.gp0(e1, "E1 texpage (8bpp)")
        s.gp0(w0, "GP0 64 textured rect color")
        s.gp0(w1)
        s.gp0(w2)
        s.gp0(w3)
        s.t += RECT_DRAIN     # let this rect drain before the next E1/rect
    return s.dump()


# ---------------------------------------------------------------------------
# FULL-FRAME replay: walk the REAL hyperbbc GAME-OVER ordering table (OT) out
# of local/ss_ram.bin and emit EVERY primitive in draw order, verbatim. This is
# the decisive scene replay the bgpanel573 (4-rect) experiment did NOT do: the
# garbled right-half is painted by a chain of 320 0x2C textured quads (CLUT
# 0x7ac0 -> VRAM(0,491), 4bpp, texpages X=896/960 Y=0/256), NOT by the 4 bg
# rects (CLUT 0x7800 -> VRAM(0,480), 8bpp) the prior replay tested.
#
# OT mechanics (PSX): a node's first word is a TAG = (nwords<<24)|(next24); the
# `nwords` data words that follow are the raw GP0 packet. The list terminates at
# a sentinel `next` that points outside the 2 MiB RAM window (this game uses
# 0x287580). DRAW ORDER = list order (we DO NOT reverse; the game already sorted
# its OT so list-head is drawn first).
#
# ** RIG CAVEAT (2026-06-07): the POLY path does NOT render in this NVC rig. **
# GP0 0x2C/0x28 (textured + flat quads) draw ZERO pixels here: the vendored
# divider's record-port `.done` (gpu.vhd gdividers: div_array(i).done is driven
# by the divider INSTANCE port while sibling record fields are driven by `<=`)
# elaborates in NVC as a 2-source signal with an undriven 'U' source, resolving
# done='U' forever -> gpu_poly stalls (proc_idle low), emits no pixel. So a
# full-frame replay of these 0x2C quads OVER a preloaded VRAM looks like a
# byte-exact reproduction, but that is a PRELOAD-PASSTHROUGH ARTIFACT (the
# garble that was already in the preloaded fb shows through unchanged because
# the quads drew nothing). To exercise the SAME 4bpp/8bpp->CLUT pixel pipeline,
# use the RECT path (build_texrect / rect_tex, GP0 0x64/0x65) -- it renders.
# Verify draw actually happened by preloading a DEST-CLEARED VRAM (display fb
# zeroed, textures+CLUT intact) and checking the band is non-black.
# ---------------------------------------------------------------------------
import os, struct

_SS_RAM = os.path.join(os.path.dirname(__file__), "..", "..", "local", "ss_ram.bin")


def _walk_ot(ram, head, maxn=4000):
    """Walk an OT linked list; return [(addr, nwords, [words...]), ...] in order.
    Stops at a `next` that leaves the RAM window (the game's terminator sentinel),
    at a revisited node (loop guard), or after maxn nodes."""
    mask = len(ram) - 1
    def w(off):
        return struct.unpack_from("<I", ram, off & mask)[0]
    addr = head & 0xFFFFFF
    seen = set(); nodes = []
    while len(nodes) < maxn:
        ma = addr & mask
        if addr != ma:           # next points outside RAM -> terminator sentinel
            break
        if ma in seen:           # loop guard
            break
        seen.add(ma)
        tag = w(ma); nwords = (tag >> 24) & 0xFF; nxt = tag & 0xFFFFFF
        words = [w(ma + 4 + 4 * i) for i in range(nwords)]
        nodes.append((ma, nwords, words))
        addr = nxt
    return nodes


def build_fullframe573(ram_path=None, heads=(0x1e0b60, 0x1e0c00),
                       draw_offx=0, draw_offy=0, quad_drain=30000,
                       only=None):
    """Replay the FULL GAME-OVER display list from the savestate main RAM.

    heads      : OT head addresses to walk + emit IN ORDER (default: the 4 bg
                 rects chain then the 320 0x2C textured-quad chain).
    draw_offx/y: GP0 E5 draw offset (lives in GPU regs, not RAM; default 0,0 —
                 the quad coords already land on the visible region with 0,0).
    only       : if set to 'rects' or 'quads', emit only that chain (bisection).
    quad_drain : clk1x gap after each textured prim so the GPU drains it (the tb
                 does not honor bus_stall, so we must pace textured draws).

    Each primitive's own E1/E2 state travels INSIDE the OT packet (the bg rects
    carry their E1 texpage; the 0x2C quads carry tpage in vertex-2's hi16 and
    CLUT in vertex-1's hi16), so the per-frame GPU state we must reconstruct is
    only: display mode, draw area (clip), draw offset, and the texture window.
    We set a permissive draw area (full VRAM panel), E2=0 (full page), E5=offset.
    """
    if ram_path is None:
        ram_path = _SS_RAM
    with open(ram_path, "rb") as f:
        ram = f.read()

    s = Stream()
    s.gp1_reset()
    s.gp1_dispmode(0x00000001)          # 320x240 NTSC, 15bpp
    s.gp1_dispenable(True)
    s.gp1_dmadir(0)
    s.gp1_dispstart(0, 0)
    s.gp1_hrange(0x200, 0x200 + 320 * 8)
    s.gp1_vrange(0x10, 0x10 + 240)
    s.draw_area_tl(0, 0)
    s.draw_area_br(511, 255)            # permissive clip over the panel
    s.draw_offset(draw_offx, draw_offy)
    s.tex_window(0, 0, 0, 0)            # full page (no UV mask)

    chains = []
    if only in (None, "rects"):
        chains.append(("rects", _walk_ot(ram, heads[0])))
    if only in (None, "quads"):
        chains.append(("quads", _walk_ot(ram, heads[1])))

    for name, nodes in chains:
        s.lines.append(f"# ---- chain {name}: {len(nodes)} primitives (draw order) ----")
        for (addr, nwords, words) in nodes:
            s.lines.append(f"# OT@{addr:06x} n={nwords}")
            for wd in words:
                s.gp0(wd)
            # textured prim: pace the FIFO so the GPU drains before the next packet
            s.t += quad_drain
    return s.dump()


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "demo"
    if which == "demo":
        sys.stdout.write(build_demo())
    elif which in ("texquad", "bgpanel_texquad"):
        sys.stdout.write(build_texquad())
    elif which in ("bgpanel", "bgpanel573"):
        sys.stdout.write(build_bgpanel573())
    elif which in ("fullframe", "fullframe573"):
        # optional arg: 'rects' or 'quads' to emit only one chain (bisection)
        only = sys.argv[2] if len(sys.argv) > 2 else None
        sys.stdout.write(build_fullframe573(only=only))
    elif which == "texrect":
        # optional args: colors(bpp) tx ty  -> e.g. `texrect 0 14 0`
        kw = {}
        if len(sys.argv) > 2: kw["colors"] = int(sys.argv[2])
        if len(sys.argv) > 3: kw["tx"] = int(sys.argv[3])
        if len(sys.argv) > 4: kw["ty"] = int(sys.argv[4])
        sys.stdout.write(build_texrect(**kw))
    else:
        sys.stderr.write(f"unknown stream '{which}'\n")
        sys.exit(2)
