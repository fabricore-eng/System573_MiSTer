# 2 MB VRAM red/green proof — psx_patches/0021-gpu-2mb-vram-10bit-y (2026-06-10)

The decisive pre-build evidence for the missing-layer fix: the System 573's
CXD8561Q GPU has **2 MB of VRAM (1024 rows)**; the vendored consumer-PSX core
implements 1 MB (512 rows) and truncates Y to 9 bits everywhere. Boot-time
uploads to y>=512 (the comic panels, the BIOS 2MB self-test) therefore WRAP
onto y-512 and overwrite the visible half — the write-side verdict's
"font uploads bit-exact into the GPU yet 73% never land; cols 14-15 of every
16-word block survive" signature. All numbers below are deterministic
local-sim / forensic measurements (no vision, no HW claims).

## 0. The forensic pre-check (no RTL involved)

Model: take the MAME 2 MB dump `gh_vram_comic.bin`, apply the gate17 upload
ledger under a "Y mod 512" wrap, and predict our core's HW VRAM dump
(`local/glyph_dma/vram_run3.bin`) in the atlas region x384-415, y0-255:

| model                                | match vs the real-HW dump |
|--------------------------------------|---------------------------|
| wrap hypothesis (1MB truncation)     | **8192/8192 px = 100.00%** |
| no-bug model (fonts land correctly)  | 3583/8192 px = 43.74%     |

Every single pixel of the HW atlas region — the wrapped panel columns, the
surviving cols-14/15 font stripes, the post-row-239 font tail, even the 96 px
of f109 background bleed-through at rows 40-63 — is exactly predicted by the
wrap model. The diagnosis is closed before the RTL even runs.

## 1. RED — stock 0001-0020 tree (1 MB, 9-bit Y) must REPRODUCE the bug

Rig: `sim/gpu_replay/run_vram2mb.sh` (gen_vram2mb.py stream → tb_gpu_replay →
check_vram2mb.py). Stream = the 3 boot font uploads A0 (384,0) 32x40 /
(384,64) 32x64 / (384,128) 32x128 + the 2 upper-half panel uploads A0
(320,512) 92x240 and (416,512) 92x240 (payloads = MAME ground truth from
gh_vram_comic.bin, verified stable vs the gate17 f00220/f02400/f05400 atlas
snapshots at 100.00%), then GP0 C0 readbacks of the atlas column (R1, 32x256 @
384,0) and both panel homes (R2/R3, 92x240 @ 320,512 / 416,512) through the
GPU's own vram2cpu path (logged by the new tb `rb_tap`).

```
[red] vram2cpu words read back: 26176 (need 26176)
PASS  R2 == panelA ref: 100.00% (22080/22080)
PASS  R3 == panelB ref: 100.00% (22080/22080)
PASS  R1 rows0-239 cols0-27 == WRAPPED panelA (foreign data over fonts): 100.00% (6720/6720)
PASS  R1 cols28-31 font rows == fonts (the surviving cols-14/15 stripes): 100.00% (928/928)
PASS  R1 rows240-255 == fonts (wrap stops at row 239): 100.00% (512/512)
PASS  R1 rows40-63 cols28-31 == 0: 100.00% (96/96)
PASS  R1 font cells CORRUPTED vs correct ref: 60.79% (match only 39.21%, 2911/7424)
PASS  R1 vs REAL-HW dump (vram_run3) on all sim-covered cells: 100.00% (8096/8096)
RED RESULT: PASS  (the stock RTL reproduces the HW corruption signature exactly)
```

The strongest line: the stock GPU, fed only the 5 boot uploads, recreates the
real hardware's corrupted atlas **pixel-for-pixel on all 8096 sim-covered
cells** (the remaining 96/8192 cells are f109-background bleed the 5-upload
replay deliberately does not cover; the standalone wrap model above covers
them at 100% too).

## 2. GREEN — 0001-0021 tree (2 MB, 10-bit Y) must FIX it

Same stream, same testbench, same checker thresholds:

```
[green] vram2cpu words read back: 26176 (need 26176)
PASS  R2 == panelA ref: 100.00% (22080/22080)   <- panels LAND at (320,512)
PASS  R3 == panelB ref: 100.00% (22080/22080)   <- and read back from y>=512
PASS  R1 font rows == font ref (atlas INTACT): 100.00% (7424/7424)
PASS  R1 rows40-63 == 0 (no wrap arrived): 100.00% (768/768)
INFO  atlas font-cell corruption: 0.00%   (red: 60.79%)
GREEN RESULT: PASS
```

R1 is the discriminator (60.79% corrupted → 0.00%). R2/R3 passing in green
additionally proves the cpu2vram WRITE and the vram2cpu READ apply the same
upper-half mapping (a one-sided mapping would have failed them: the lower half
holds fonts there in green, not panels).

## 3. Do-no-harm — y<512 behavior must be BIT-IDENTICAL across the patch

```
PASS  cmd_fill_demo (fill + flat rects)      gra_fb_out.gra byte-identical 0020 vs 0021
PASS  cmd_texrect (4bpp CLUT over ss_vram)   gra_fb_out.gra byte-identical 0020 vs 0021
```

The .gra is the ordered log of every VRAM pixel write, so byte-identity means
identical pixels in identical order — the fill, flat-rect, textured-rect,
texture-fetch and CLUT-fetch paths for y<512 are untouched.

## 4. Regression gates

- `make -C sim` (the 27-test iverilog 573 suite): **ALL TESTS PASSED** on the
  0021 tree (these don't compile psx/, included for completeness).
- `sim/system573/run.sh` (full-system NVC: the ENTIRE psx core — cpu, dma,
  spu, mdec, memorymux, psx_top, psx_mister + the patched GPU): analyzes,
  elaborates and boots the Konami BIOS (PC walks 0xBFC00000 →
  0xBFC00188/194/46C…) with **zero analysis/elaboration errors** — the
  9→10-bit width ripple is contained.
- Patch hygiene: `tools/apply_psx_patches.sh --check` = 0001..0021 all
  "applies cleanly" from the pristine pin; full `--revert` → 0 dirty files →
  re-apply round trip verified. 0021 IS registered in the hardcoded PATCHES
  array (the historical false-verdict trap).

## 5. What 0021 changes (1189-line patch, 9 files)

Per MAME psxgpu gputype-2 conventions (verified in source): A0/C0/80 dst/src Y
= word bits 25:16 (mod 1024), sizes 0x400-defaulting; E3/E4 scissor Y =
bits 19:10 (10-bit); texpage Y-base bit 11 = +512; CLUT attr bit 31 = CLUT row
bit 9. Upper-half rows map to `vram_ADDR(27:20) = x"08"` (+8 MB, clear of
memcard pages 1-2, SPU page 3, framebuffer pages 4-7) at the single
composition site in gpu.vhd; the engine-write path carries the new bit through
a +1-bit fifoOut (86→87 wide). The texture-cache TAG gains the new address bit
(no aliasing between Y halves). Scanout/videoout is bit-identical (9-bit
request Y zero-padded into the OR-mux); GP1(05) display base stays 9-bit
(upper-half display bases are not displayable — documented limit, unused by
the 573 boot path).

Savestate note: drawingArea Top/Bottom move from ss-word bits (24:16) to
(25:16) in GPU words 4/5; bit 25 was unused in both, so OLD savestates load
unchanged. No other field moves.

## 6. Open items / honest limits

- This is a SIM proof on the GPU-isolated rig driven via the bus port; DMA
  ch2 request-mode pacing is not replayed (the wrap is address arithmetic, not
  timing — and the write-side verdict already proved dma→gpu words bit-exact).
- The 96 f109-bleed cells are covered by the forensic model, not the RTL
  replay (would need the full 1024x512 f83/f109 uploads in-stream; nothing in
  the verdict depends on them).
- Scissored RENDERS to y>=512 (drawer path) are widened and compile/elaborate
  clean, but no boot content exercises them in this replay; the e2e arbiter is
  the next HW build.
- GP1(05) display-base bit 19 (display FROM the upper half) intentionally not
  plumbed into scanout.
- HW verdict still pending a dell build + de-confounded board test (warm
  reboot, uptime < 60 s, exactly one load_core) — this document is the
  pre-build proof, not a "works on HW" claim.
