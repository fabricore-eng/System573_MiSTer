# hyperbbc operator-menu glyph upload — MAME characterization (2026-06-10)

**Goal:** the 573 core renders the operator MAIN MENU draw list word-identically to MAME, but
the glyph atlas at texpage 0x206 (4bpp, VRAM x384..447, y0..255) is mostly empty on our core.
Characterize in MAME (the working reference) exactly WHEN and HOW that atlas gets its content,
so the core's failing upload path can be instrumented precisely.

**Method:** `local/mame_gate_hunt/gate16_glyph_upload.lua` (full-session GP0/GP1 port tap +
DMA-register tap with a proper GP0 stream parser fed in FIFO arrival order, plus dense VRAM
atlas sampling with hash-change bin dumps) and `gate16b_midstate.lua` (mid-upload atlas grabs).
Artifacts: `local/mame_gate_hunt/gh16_events.txt`, `gh16_samples.txt`, `gh16*_atlas_f*.bin`.
All numbers below are measured, deterministic across 3 independent runs (gate8/gate14 dumps +
gate16 + gate16b; e.g. gate16's f180 atlas bin is md5-identical to gate16b's f179 bin).

## Verdict in one line

**There is NO menu-era glyph upload.** The atlas reaches its final, byte-stable state at boot
frame ~205 (~3.4 s after power-on) and never changes again — through attract, the comic, the
service press (f4000) and the menu (f5400). The menu just draws from boot-era VRAM content.
Our core's "menu-era upload never lands" framing was wrong: the upload our core is missing
happened ~3 seconds after boot.

## 1. WHEN — atlas content vs frame (60 fps)

| frames        | atlas state (x384..447, y0..255, 32 KB)            | md5 (bin in local/mame_gate_hunt/) |
|---------------|-----------------------------------------------------|------------------------------------|
| 0 .. ~82      | all zero (nz=0)                                      | —                                  |
| ~83 .. 172    | boot-splash content from two whole-VRAM A0 writes    | `45a9d601` f100 (nz 32621)         |
| 173 .. ~202   | font sheet landed (3 small uploads, f173–174)        | `0aa44536` f180 (nz 25370)         |
| ~205 .. 5400+ | **FINAL** (right column rewritten f203/205)          | `a222bbea` f220 (nz 17727)         |

- `a222bbea` is byte-identical at f220, f600, f2400, f5400 (gate16) and in the gate8 (f2400,
  attract-only run, no service press) and gate14 (f5400, menu) full-VRAM dumps.
- The same upload sequence re-runs once per attract-loop restart (observed f1295–1327),
  rewriting **identical** content (hash never changes). Zero atlas-targeting packets after
  f1327 — in particular, **nothing** at/after the service press.
- **All 257 menu glyph rects are render-final by f176**: the gate16b f176 bin (after the three
  small f173/174 uploads, before anything else) renders all 257/257 rect cells identical to
  final. The f203/205 rewrites don't affect any cell the menu samples.

## 2. HOW — the upload mechanism (pc-exact)

Classic PsyQ-style LoadImage, **split across the CPU port and DMA ch2**. Per upload, from
`gh16_events.txt` (game routine ≈ 0x80132274..0x80132458):

1. `GP1(04h)=0` — port write 0x1F801814, pc=`0x80132390` (DMA direction off)
2. **A0 header + YX + WH: THREE CPU-direct GP0 port writes** (0x1F801810), pc=`0x801323b8`
3. `GP1(04h)=2` — pc=`0x80132424` (DMA direction = CPU→GPU)
4. **pixel data: DMA ch2, request mode** — MADR/BCR/CHCR written at pc=`0x80132458`
   (ra=`0x80132274`): MADR = RAM staging buffer (0x8019xxxx area),
   BCR = `0xNNNN0010` (16-word blocks × NNNN), **CHCR = `0x01000201`**
5. word counts not a multiple of 16: remainder goes via GP0 **port** writes (seen only in the
   boot-loader variant, e.g. f43: 40 words = 32 DMA + 8 port; the font batch is all
   multiples of 16 → 100 % of font pixel data rides DMA)

The boot loader (pc=`0x803c64b0`, BIOS-side Konami loader) uses the same pattern for the two
whole-VRAM writes, including a full VRAM **readback** first (GP0 `C0` 1024x512 → DMA ch2
to-RAM, CHCR=`0x01000200`, RAM 0x110000) at f83/f109.

### The atlas-relevant A0 packets (all CPU-port headers + DMA-ch2 data)

| frame | dest (x,y) | w×h (hw) | data words | BCR        | role |
|-------|-----------|----------|------------|------------|------|
| 83, 109 | (0,0)   | 1024×512 | 262144     | 0x40000010 | whole-VRAM splash (boot loader, pc 803c64b0) |
| **173** | **(384,0)**   | **32×40**  | **640**  | 0x00280010 | font, left col top |
| **174** | **(384,64)**  | **32×64**  | **1024** | 0x00400010 | font, left col mid |
| **174** | **(384,128)** | **32×128** | **2048** | 0x00800010 | font, left col bottom |
| 180  | (320,0)   | 92×240   | 11040      | 0x02B20010 | comic tile; bytes in x384..411 identical to f173/174 content (atlas md5 unchanged) |
| 181  | (416,0)   | 92×240   | 11040      | 0x02B20010 | comic tile; atlas bytes unchanged |
| 203  | (416,0)   | 32×208   | 3328       | 0x00D00010 | right col rewrite → final state |
| 205  | (416,208) | 32×36    | 576        | 0x00240010 | right col tail → final state |

(identical batch repeats at f1295/1295/1295/1301/1302/1324/1327)

Exact header words for the three decisive font uploads (port writes, pc 0x801323b8):
`A0000000, 00000180, 00280020` / `A0000000, 00400180, 00400020` / `A0000000, 00800180, 00800020`.

Whole-session totals (5405 frames): 308 A0 packets (16 atlas-flagged), 0 GP0-80, 0 GP0-02
fills, 2 C0 readbacks, 260 ch2 block-mode (upload) DMAs, 11940 ch2 linked-list (draw) DMAs,
2179 GP0 port words, 33439 GP1 writes.

## 3. The draw-list trailing 0x80 packet

The menu list ends `80000000 00000000 00000000 00000002` = vram2vram copy, src=(0,0),
dst=(0,0), w=2, h=0. **MAME 0.288 `psxgpu::MoveImage` loops `while(n_h > 0)` with no 0→max
promotion → h=0 copies NOTHING — a literal no-op.** (On real HW / nocash semantics h=0 would
be 512, but src==dst=(0,0) makes it an identity self-copy — still no visible effect.) It is a
harmless list terminator/sync packet, **not** a glyph source, and the unified port+DMA stream
contained zero other 0x80s all session. Our core may treat h=0 as 512; either way no pixel
changes. Not a suspect.

## 4. Does boot-era font content explain our 64 clean rects? — NO

Measured against the menu draw list (257 GP0-65 raw textured rects, texpage 0x206, CLUTs
0x7810 @(256,480) = [idx0=0x0000 transparent, idx1..13=0x7FFF white, 0x0421, 0x3B6D] and
0x7850 @(256,481); 32 unique 16×16 cells, u=0..120, v=0..239 → VRAM x384..417, y0..239):

| our-core atlas hypothesis                  | predicted clean rects |
|--------------------------------------------|----------------------|
| fully EMPTY (all zero) + correct CLUT       | **29** (28× the space cell (0,0) + 1× blank cell (0,128)) |
| boot-splash only (f83/109 landed, font not) | **0** |
| f173/174 small uploads landed               | **257** |

No coarse "which transfer landed" state predicts 64. If the measured clean count is 64, our
atlas is NOT uniformly empty — ~35 rects sit on cells holding correct content, i.e. the font
uploads **partially** landed (truncated transfer / addressing corruption), or the 29-vs-64
discrepancy is in the clean-rect classifier. Next step is byte-level, board-free: dump our
core's VRAM during attract (≥5 s after boot) and nibble-diff the region (byte offsets
`y*2048+768 .. +895` for y 0..255) against the staged references
`gh16b_atlas_f00172.bin` (pre-font splash) / `gh16_atlas_f00180.bin` (post-font) /
`gh16_atlas_f00220.bin` (final). Whichever bytes match localizes exactly which transfer(s)
(and how much of each) landed.

## 5. Instrumentation recommendation for our core

**The existing DMA taps are blind to the A0 header — it NEVER rides DMA.** A SignalTap
trigger `word==0xA0xxxxxx` on the ch2 data stream will never fire for the upload (and would
false-fire on pixel words). What works:

1. **DMA-side trigger that DOES work (uses existing taps): ch2 `CHCR == 0x01000201`.**
   Request-mode RAM→GPU is used by NOTHING except VRAM uploads (draw lists are `0x01000401`,
   OTC is `0x11000002`). Trigger there, capture MADR/BCR + the data burst. Expected signature
   ~3 s after boot: three back-to-back starts with BCR `0x00280010`, `0x00400010`,
   `0x00800010` (640/1024/2048 words) within ~2 frames. Count the words actually delivered to
   the GPU per start — a shortfall is the bug, measured.
2. **Bus-side probe for the header:** CPU write strobe to GPU GP0 (addr 0x1F801810) with
   `data[31:24]==0xA0`; the three headers + params are the exact words listed in §2. Pair
   with (1) to see header-accepted vs data-delivered.
3. **Prime suspect to check while instrumenting:** the delta between the working path (draw
   lists, sync-mode 2 linked) and the failing path (uploads, sync-mode 1 request/DREQ) is the
   DMA sync mode + the GP1(04h) 0→2 direction toggle around each upload. If our DMA ch2
   request-mode handshake (GPU DREQ generation while GPUSTAT direction=2, FIFO-ready gating)
   is broken or the GP1(04h)=0 step wedges it, exactly this symptom appears: draw lists
   word-perfect, atlas empty. Note the boot loader also uses request mode **to-RAM**
   (`0x01000200`, the C0 readback) — worth checking both directions.
4. **Board-free first:** the §4 VRAM nibble-diff via the headless savestate+mmap flow — no
   build needed, quantifies exactly which upload bytes are missing before any SignalTap run.

## Reproduction

```
mame hyperbbc -rompath "dumps/mame573;dumps" -skip_gameinfo \
  -video none -sound none -nothrottle -seconds_to_run 110 \
  -autoboot_script local/mame_gate_hunt/gate16_glyph_upload.lua
# outputs /tmp/gh16_events.txt /tmp/gh16_samples.txt /tmp/gh16_atlas_f*.bin
```
