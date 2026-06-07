# GPU-replay NVC rig (`sim/gpu_replay`)

A GPU-**isolated** GP0/GP1 command-replay testbench for NVC. It stands the vendored
`psx.gpu` up standalone (no CPU, no BIOS, no full system), drives it from a text
command stream, and captures the rendered framebuffer to the upstream `.gra` dump
machinery. Purpose: test the hyperbbc bg-panel garble **in simulation** — split an
RTL-logic bug (sim garbles too) from a HW-timing interaction (sim renders clean,
since the sim VRAM model is ideal-timing) via the `SLOWTIMING` knob.

It is the NVC twin of the upstream ModelSim rig `psx/sim/gpu/src/tb/tb.vhd`, but:
- pure **reset** bring-up (no `tb_savestates`/.ss load — with `loading_savestate='0'`
  a plain reset fully soft-resets the GPU, so the stream programs everything);
- **VRAM preload** via the `ddrram_model` `COMMAND_FILE_START_2` path (`TARGET=0`
  loads a raw 1024x512x2 LE image linearly into the model's `data[]` — proven
  byte-exact, see Milestone 1);
- the **full current `gpu.vhd` port map** (this 573 fork has a 28-bit `vram_ADDR`
  and many ports the old upstream tb lacks), copied from `psx_top.vhd`; the DDR
  address mapping `DDRAM_ADDR(24:0) <= vram_ADDR(27:3)` (base `0x3<<25`) is copied
  from `psx_mister.vhd`;
- generic-selectable command file + VRAM file + `SLOWTIMING` (the latency lever).

Nothing in the vendored `psx/` submodule is edited; the tb only INSTANTIATES it.

## Files
- `tb_gpu_replay.vhd` — the harness (original to this repo).
- `gen_stream.py` — GP0/GP1 stream generator (single source of truth for the
  byte-exact encodings). Subcommands: `demo`, `texrect [bpp tx ty]`, `texquad`.
- `run.sh` — analyze + elaborate + run + render `.gra`→PNG.
- `cmd_*.txt` — generated command streams.

## Command-stream format
One event per line, all hex; `#` comments + blank lines skipped:
```
<addr> <time> <data>
```
`addr` = GPU `bus_addr` (`00000000`=GP0 data/cmd FIFO, `00000004`=GP1 control);
`time` = clk1x tick at/after which to issue the write; `data` = the 32-bit word.

## Run it
```
sim/gpu_replay/run.sh [CMD_FILE] [VRAM_FILE] [SLOWTIMING] [DRAIN_MS]
```
- `CMD_FILE`   command stream (default `cmd_fill_demo.txt`). **Use an absolute path.**
- `VRAM_FILE`  raw 1024x512x2 LE VRAM image to preload (default ""=none).
- `SLOWTIMING` `ddrram_model` VRAM read latency in cycles (0=ideal; the timing lever).
- `DRAIN_MS`   drain after the last command, an NVC time literal (default `"4 ms"`).

Outputs land in `build/`:
- `gra_fb_out.gra` / `.png` — raw VRAM-as-drawn, 1024x512 (the **direct render**;
  use this for garble analysis — unaffected by display crop/timing).
- `gra_fb_out_vga.gra` / `.png` — displayed video, 640x480 (post display crop).

### Milestone-1 demo (prove the rig)
```
sim/gpu_replay/run.sh "$PWD/cmd_fill_demo.txt" "" 0 "4 ms"
```
Renders a 320x240 dark-blue VRAM fill with red/green/white flat rectangles at known
positions — confirmed pixel-exact (red=(248,0,0), green=(0,248,0), white=(248,248,248),
fill 100% coverage). The full draw pipeline (fill + rect rasterizer + pixel pipeline +
VRAM writes) works end-to-end in NVC.

## Findings (2026-06-06)

### Milestone 1 — DONE. The NVC GPU-replay rig is up and proven.
Plus a **VRAM-preload round-trip** validation: preloading `local/titlehunt_11.bin`
and dumping VRAM back renders **byte-identical** to the known-good `titlehunt_11.png`
(0 pixels differ) — the preload format + `.gra`→PNG path are trustworthy.

### Milestone 2 — the CLUT experiment, DONE (via the textured-rect path).
The bg garble forensics (memory/573-game-boot-blockers.md) pinned the suspect to
render-time 4bpp/8bpp **CLUT sampling** of byte-correct bg textures. We tested OUR
GPU's actual 4bpp→CLUT sampling RTL by replaying a **raw textured rectangle**
(GP0 0x65, the `gpu_rect` path) over MAME's byte-exact title-VRAM (texpage 0E,
CLUT 0x7ac0), into a cleared display region.

| run | CLUT | SLOWTIMING | vs python 4bpp ground-truth |
|-----|------|-----------|------------------------------|
| A | correct (MAME `mame_clut7ac0.bin`) | 0 (ideal) | **SSIM 1.0000, 0.0% diff, byte-exact** |
| B | wrong (our self-test gradient) | 0 | SSIM 0.1131, 33.2% diff (garbled colors) |
| C | correct | 20 (realistic latency) | **SSIM 1.0000, byte-exact (== run A)** |

Reproduce:
```
python3 gen_stream.py texrect 0 14 0 > cmd_texrect.txt        # generator
# then a 64x64 raw rect sampling UV(0,64) of texpage 0E (see the experiment block)
```
The "SPEED" meter graphic renders RED-on-correct (A/C) vs WHITE/GREEN-on-wrong (B):
same texels, wrong palette — exactly the on-HW symptom signature. See
`local/_exp_montage.png` (A | B | C).

**Verdict (RTL-logic vs HW-timing) for the bg garble:**
- The GPU's 4bpp-indexed-texture **CLUT sampling RTL is CORRECT** — byte-exact vs
  the reference decode when the correct CLUT is present (run A).
- It is **timing-invariant**: SLOWTIMING=0 and SLOWTIMING=20 produce identical output
  (run C == run A). So the bg garble is **NOT** a VRAM-read-latency / HW-timing
  interaction in the GPU sampler.
- A **wrong CLUT reproduces the garble** (run B): structure preserved, colors wrong.
  This is consistent with — and points the remaining hunt at — the **CLUT-data path**
  (the small palette that lands in VRAM at draw time), not the GPU sampler and not
  timing. (Honest caveat below.)

### Honest caveats / limits
- **GP0-stream reconstruction fidelity:** we do NOT have MAME's exact 320-quad
  bg-panel GP0 stream, so we did NOT replay the real scene. We tested the *mechanism*
  (4bpp→CLUT sampling of the real texture+palette), which is the decisive variable the
  forensics isolated, but this is an **isolated-primitive** test, not a scene replay.
- **The CLUT slot is volatile** (memory note 2026-06-06 retraction): a static VRAM
  dump can't prove *which* CLUT is live at the real draw, so run B demonstrates
  "wrong CLUT ⇒ this garble", not "the real garble IS a wrong CLUT". It rules the
  GPU sampler + timing IN/OUT cleanly; it does not by itself close the root cause.
- **Textured primitives are slow in sim and hang if under-drained.** The GPU's
  draw-timing model charges ~4 clk2x per textured/transparent pixel, so a 256x256
  textured prim needs ~262k clk2x (~2 ms drain); under-draining leaves `proc_idle='0'`
  and looks like a hang. Untextured fills/flat-rects are cheap. Size textured draws +
  `DRAIN_MS` accordingly (a 64x64 rect needs ~2 ms).
- **The poly path (GP0 0x2C/0x28) was not used** for the experiment — the rect path
  (`gpu_rect`) reaches the same 4bpp→CLUT pixel pipeline without the heavier poly
  timing, and is the cleaner vehicle here. (Untextured flat quads also obey the same
  per-pixel timing budget; give them enough drain if you use them.)

### Milestone 3 — bg-panel garble REPLAY from the real savestate (2026-06-07).

Drove the EXACT hyperbbc GAME-OVER bg-panel GP0 stream — the four 8bpp textured
rects extracted verbatim from the savestate display list in `local/ss_ram.bin`
(OT head ~0x1e0b60): `E1` texpage X=640/768 (8bpp) + `0x64` rects, CLUT 0x7800 ->
VRAM(0,480) — over the frozen savestate VRAM (`local/ss_vram.bin`). Generator:
`gen_stream.py bgpanel573` -> `cmd_bgpanel573.txt`.

**The sim does NOT reproduce the garble** (the decisive negative result):

| comparison | SSIM | %diff | MAE | verdict |
|------------|------|-------|-----|---------|
| SIM garble-region vs HW frozen garble-region | 0.036 | 98.7% | 80.9 | **MISMATCH** |
| SIM node2 vs Python ground-truth 8bpp decode (texpage768/CLUT(0,480)) | **0.9991** | 0.36% | 0.08 | **MATCH** |

The bg rects, drawn by our GPU over clean VRAM, render a coherent cityscape that
is **byte-identical to the reference 8bpp decode** — NOT the green digital-rain
garble that the frozen HW VRAM shows at those exact screen pixels (display origin
verified (0,0), meanDiff 0.0). Result is **timing-invariant** (SLOWTIMING 0 == 20,
both 1.2% green). So our 8bpp→CLUT pixelpipeline is faithful for THIS primitive;
the garble is NOT a render-time defect in the bg-rect 8bpp path as reconstructed.

**TAP findings** (`DBG_TAP8`): the per-pixel 8bpp resolve trace shows, for every
bg-rect pixel: mode='0''1' (8bpp), `clutAddrB`=the real texel index (0x8c..0xf8 =
140..248, NOT 0..31), `clutDataB`=a proper cityscape color (e.g. 0x158d), and the
CLUT-load handshake reads reqX=0 reqY=0x1E0(480) reqSize=0x100(256) with byte-exact
(0,480) contents. So: index does NOT leak to output, CLUT lookup IS honored, CLUT
contents ARE correct. The frozen-HW green (0x0060/0x00c0/0x0141 = green-only) equals
neither `clutDataB` NOR `index<<5` (0x1180...) — it isn't this rect's resolve at all.

Conclusion: the established "8bpp pixelpipeline render-time defect drawn by these
rects" attribution is NOT confirmed by replay. The green was painted by a DIFFERENT
primitive / draw-state than the reconstructed 4 bg rects (the frozen green is not a
consistent function of texpage-768 indices through any CLUT — each index maps to
20-76 different frozen values). Next: trace the FULL OT (the 0x2c quads + the chain
into bucket 0x287580) to find the primitive that actually writes the green, or
capture the live GPU register/CLUT-cache state at draw time (not in `ss_ram.bin`).

### Milestone 4 — FULL OT trace + the green-painter pinned (forensically), 2026-06-07.

Walked the COMPLETE GAME-OVER display list out of `local/ss_ram.bin`. The 4 bg
rects (OT head 0x1e0b60) are a 4-node chain; the garbled right-half is painted by
a SEPARATE **320-node chain of GP0 0x2C textured QUADS** (OT head 0x1e0c00), all
4bpp, all CLUT **0x7ac0 -> VRAM(0,491)**, texpages X=896/960 Y=0/256, screen bbox
x[-8..391] y[-80..319] (a warped full-panel grid covering the garble band
x123..378 y0..203). Both chains terminate at the game's OT sentinel 0x287580
(outside the 2 MiB RAM window). Generator: `gen_stream.py fullframe [rects|quads]`.

**Two hard, reproduced results:**

1. **The garble is NOT a correct render.** A byte-faithful software 4bpp->CLUT
   decode of the 320 quads (correct GPU semantics, CLUT 0x7ac0) renders a BLUE/CYAN
   cityscape (top colors 0x7ff1/0x7b90/0x7fb0...). The frozen HW band is PURE GREEN
   (only the G channel set). 0/47397 painted px match the correct decode. So HW (and
   our sim, which is byte-exact to the savestate VRAM) genuinely DIVERGES from the
   intended image — the green is a real rendering bug, not an artistic green panel.

2. **The green == raw 4bpp texel INDEX in the green channel.** Every garble value is
   exactly `index<<5`: the band's pure-green set {0x60,0xa0,0xc0,0x100,0x120,0x140,
   0x160} = indices {3,5,6,8,9,10,11} placed in green bits[9:5], and >>5 yields small
   integers (23 514 px in the 4bpp range 0..15 vs 349 px in the 8bpp range). The
   green cycles every ~4 screen px (`...0120 00c0 00a0 0160...`), the signature of a
   4bpp word's four nibbles emitted as raw indices with NO CLUT lookup. CLUT 0x7ac0
   itself contains NO green entry (all blue/cyan), so the green can only be the
   un-looked-up index leaking to output (`texdata_raw` instead of `CLUTDataB`).

**RIG LIMIT — the poly path does not render in NVC (decisive, corrects M3-era hope
of a full-scene replay).** Feeding the 320 0x2C quads to the rig produced a
"100.00% byte-exact, SSIM 1.0000" match vs the HW garble — **a FALSE positive**: a
DEST-CLEARED control (preload the savestate VRAM with the display fb zeroed,
textures+CLUT intact) shows a single 0x2C quad — AND a flat 0x28 quad, AND the
demo's 2nd/3rd flat rects — draw ZERO pixels. The "match" was the preloaded garble
passing through untouched because the poly drawer never emits a pixel. Root cause:
the vendored divider's record-port `.done` (gpu.vhd `gdividers`) elaborates in NVC
as a 2-source signal with an undriven 'U' (the `POLY_DIV(*).DONE ... no driver`
init warnings) -> done='U' forever -> `gpu_poly` stalls (proc_idle low). The RECT
path (0x64/0x65) DOES render and exercises the SAME pixel pipeline.

**Positive control on the shared pipeline:** a 0x65 RAW textured RECT sampling the
SAME texpage 0x1E (VRAM 896,256), 4bpp, CLUT 0x7ac0, over the savestate VRAM,
resolves CORRECTLY: `DBG_TAP8` OUT rows = `pixelColor=7FF1` (= CLUT[1], blue), CLUT
load reqY=0x1EB(491) byte-exact. So the 4bpp->CLUT resolve in the shared
pixelpipeline is FAITHFUL when driven by the rect path — i.e. the index-leak, if it
is an RTL bug, lives in how the **poly path** drives that pipeline (UV/coord/state
or a CLUT-handshake the poly path skips), NOT in the pipeline's CLUT lookup itself.

**Honest status / disambiguator.** Forensically pinned: garbled region = the
320-quad chain (0x1e0c00); the green = 4bpp index<<5 (raw index, no CLUT lookup);
the bug is poly-path-specific (rect path of the same texture+CLUT renders clean
blue). NOT yet pinned to an exact RTL signal, because this NVC rig cannot render
0x2C. The decisive next experiment: render these quads through the poly path — by
fixing the NVC divider `.done` elaboration (a tb-side or elaboration-flag
workaround that drives the record field, NO psx/ edit) OR via the full-system
savestate replay (`sim/system573_ssreplay`) which loads the savestate GPU regs and
can drive gpu_poly from real state — then read the `DBG_TAP8` OUT rows over the
garble band and confirm `pixelColor == texel_index<<5` (index leak) vs
`== CLUT[index]` (correct), and whether the poly path's textPalNew CLUT-load
handshake fires at all for these quads.

## Debug
`tb_gpu_replay.vhd` has a `DBG_TEX` constant (ships **false**) — internal probe
(`proc_idle`/`reqVRAMEnable`/`VRAMIdle`/`pipeline_stall`/`DDRAM_RD`) for textured-
draw timing — and a `DBG_TAP8` constant (ships **false**) — the 8bpp CLUT-resolve
tap (per-pixel `clutAddrB`/`clutDataB`/cache-word + the CLUT-load handshake), written
to `build/tap8.log`. Both via VHDL-2008 external names (no `psx/` edit). `DBG_TAP8`
taps the per-`i` combinational arrays at the dpram INSTANCE PORTS
(`gfiltermemmult(0).iclutram.{address_b,q_b}`, `.icache.q_b`) because NVC folds the
arch-level array signals away; `run.sh` passes `--no-collapse` to keep names live.
