#!/usr/bin/env python3
# =============================================================================
# hw_display_frame.py -- 573 HW DISPLAY-FRAME producer (A/V eval suite, pillar 2)
#
# Spec: ~/Dev/tools/docs/AV_EVAL_TOOLING_SPEC.md  section 6 (video).
#
# Convert OUR core's raw HW VRAM dump (1024x512 RGB555 LE, stride 2048) into the
# NATIVE-RESOLUTION displayed frame -- the rectangle the GPU actually scans out --
# so it can be diffed against MAME's native display (368x240 for hyperbbc) with
# NO lossy host downscale. This is the producer half of the framebuffer-diff
# pillar: it emits a clean native-res PNG that frame_diff.py / frame_diff_regions.py
# then turn into a NUMBER (SSIM/PSNR/%diff) vs the MAME reference.
#
# WHY THIS EXISTS: the 573 core renders hyperbbc's title-panel BACKGROUNDS
# garbled. We proved (byte-exact) the bg TEXTURE data in VRAM is correct, so it's
# a render-time defect -- but we have never put a clean NUMBER on the on-screen
# garble vs ground truth because our HW capture and MAME's frame were never
# aligned at native resolution. This tool produces the aligned native frame.
#
# Usage:
#   tools/hw_display_frame.py <vram.bin> [--window X,Y,W,H] [--out out.png]
#                             [--json] [--selftest]
#
#   <vram.bin>          raw VRAM dump: 1024 px/row x 512 rows, RGB555 LE,
#                       stride 2048 bytes (== 1,048,576 bytes). This is exactly
#                       what tools/mister_vram_dump.sh pulls off the MiSTer.
#   --window X,Y,W,H    crop EXACTLY this display rectangle (authoritative; use
#                       the GPU DisplayOffsetX/Y + DisplayWidth/Height when known).
#   --out out.png       write the native-res PNG here (no upscale, no padding).
#                       Default: <vram.bin without ext>-display.png .
#   --json              emit a machine-readable sidecar-style JSON to stdout
#                       (native_w/h, window, luma, crop_source) for the bundle.
#   --selftest          run the synthetic self-test (no real file needed) and
#                       print PASS/FAIL. Exits 0 on PASS, 1 on FAIL.
#
# COLOR DECODE: RGB555 little-endian. Per psx VRAM layout each 16-bit halfword is
#   bit 0..4   = R (5 bits)
#   bit 5..9   = G
#   bit 10..14 = B
#   bit 15     = mask/STP (ignored for display luma)
# Expanded to 8bpc with the standard left-shift-by-3 (5->8 bit) replication-free
# widen (<<3); this matches frame_diff.py / emu.sv colorspace handling so a diff
# is apples-to-apples.
#
# AUTO-DETECT HEURISTIC (when --window is NOT given). The displayed framebuffer
# is a "natural image" region: high local color variation AND strong row-to-row
# coherence (adjacent scanlines correlate), distinct from FLAT cleared/back-buffer
# areas (near-zero variance). For hyperbbc the title composite is the top-left
# 368x240 (DisplayOffsetX/Y = 0); empirically (titlehunt_10 vs _11, byte-diff) the
# ONLY frame-varying region of VRAM is x=0..383 -- everything at x>=384 is the
# STATIC texture/CLUT atlas (identical across frames), NOT a display buffer. So
# auto-detect deliberately does NOT roam into the texture band: that would emit
# texture memory as if it were the screen.
# Policy:
#   1. Score the documented default window (x=0,y=0,w=384,h=240 ~= 368x240 native)
#      with a natural-image score = f(row-coherence, variation, non-black frac).
#   2. If that score is strong, USE IT (crop_source="default-topleft").
#   3. If the top-left is WEAK, probe a small set of genuine ALTERNATE DISPLAY
#      origins (other plausible front-buffer column starts WITHIN the display band,
#      x in {0,256,320}; never the texture atlas) for the PSX double-buffer case,
#      ranking by coverage then score (crop_source="autodetect-scan").
#   4. If even the best display-band window is essentially blank (a dump caught
#      mid-clear, like titlehunt_10), STILL emit the documented top-left window --
#      it IS the display window, just captured empty -- and PRINT a LOW-CONFIDENCE
#      / blank-buffer WARNING (crop_source="fallback-blank"). Never silently pass
#      off texture memory as the screen, and never crash.
# The chosen window + its score are always PRINTED, so a weak/odd detection is
# visible, never hidden. A LOW SSIM vs MAME after a CONFIDENT crop is the BUG
# FINDING (the garble), not a detection failure -- do not "fix" detection to
# chase a higher SSIM.
# =============================================================================
import sys
import os
import argparse
import json

import numpy as np

# VRAM geometry (psx displayed VRAM as dumped by mister_vram_dump.sh).
VRAM_W = 1024            # pixels per row
VRAM_H = 512             # rows
VRAM_STRIDE_BYTES = 2048  # 1024 px * 2 bytes
VRAM_BYTES = VRAM_W * VRAM_H * 2  # 1,048,576

# Documented sane default display window (~= hyperbbc 368x240 native; the spec
# endorses x=0,y=0,w=384,h=240 as the fallback).
DEFAULT_WINDOW = (0, 0, 384, 240)

# End of the DISPLAY band. Empirically (titlehunt byte-diff) x>=384 is the STATIC
# texture/CLUT atlas, never a screen -- scan windows are clamped to stay left of
# this so a probe can never bleed into texture memory and false-positive.
DISPLAY_BAND_END_X = 384

# Alternate DISPLAY-band origins to probe when the top-left is blank (plausible
# PSX double-buffer front-buffer column starts), all within the display band.
SCAN_ORIGINS_X = (0, 256, 320)
SCAN_ORIGIN_Y = 0

# A scan candidate must clear this natural-image score to be trusted as a real
# front buffer; below it we treat the dump as a blank/mid-clear display (the
# texture-band seam can leak a weak score, so do not chase it).
SCAN_CONFIDENCE_FLOOR = 0.30

# Natural-image confidence threshold: above this the default top-left window is
# accepted without scanning. Calibrated against the real dumps -- titlehunt_11's
# top-left scores ~0.7+, a blank back-buffer scores ~0.0.
NATURAL_SCORE_ACCEPT = 0.35


def load_vram(path):
    """Read a raw VRAM dump into a (VRAM_H, VRAM_W) uint16 array."""
    raw = np.fromfile(path, dtype="<u2")
    if raw.size < VRAM_W * VRAM_H:
        raise ValueError(
            f"{path}: {raw.size*2} bytes, expected >= {VRAM_BYTES} "
            f"({VRAM_W}x{VRAM_H} RGB555). Not a 573 VRAM dump?"
        )
    # Take exactly the displayed VRAM (rows 0..511); ignore any trailing bytes.
    return raw[:VRAM_W * VRAM_H].reshape(VRAM_H, VRAM_W)


def rgb555_to_rgb8(v16):
    """Decode RGB555 LE uint16 array -> uint8 RGB array (...,3), 5->8 via <<3."""
    r = ((v16 & 0x1F) << 3).astype(np.uint8)
    g = (((v16 >> 5) & 0x1F) << 3).astype(np.uint8)
    b = (((v16 >> 10) & 0x1F) << 3).astype(np.uint8)
    return np.stack([r, g, b], axis=-1)


def luma_of(rgb8):
    """Simple mean-channel luma (float32) for scoring -- matches frame_diff."""
    return rgb8.astype(np.float32).mean(axis=-1)


def natural_image_score(luma):
    """Score 0..1: how much a region looks like a scanned-out natural picture.

    Combines three orthogonal signals so neither a flat field nor a single
    pathological one fools it:
      * row-coherence  : Pearson corr of each scanline vs the next (natural
                         images vary smoothly down columns -> high; noise/flat
                         -> low).
      * variation      : normalized luma std (a real frame has contrast; a
                         cleared buffer is constant -> ~0).
      * coverage       : fraction of non-black pixels (a blank buffer -> ~0).
    The product-ish blend means ALL must be present to score high, which is what
    separates the display framebuffer from a cleared back-buffer.
    """
    if luma.size == 0 or luma.shape[0] < 2:
        return 0.0
    # row-to-row coherence
    a = luma[:-1].ravel()
    b = luma[1:].ravel()
    if a.std() < 1e-3 or b.std() < 1e-3:
        rowcoh = 0.0
    else:
        rowcoh = float(np.corrcoef(a, b)[0, 1])
    rowcoh = max(0.0, rowcoh)            # negative correlation is not "natural"
    variation = min(1.0, float(luma.std()) / 64.0)   # 64 LSB std ~= full credit
    coverage = float((luma > 4.0).mean())
    # geometric-ish blend: every factor must contribute. Coverage is squared so a
    # window that FULLY contains the displayed image strongly out-scores one that
    # only partially overlaps it (a half-on-screen crop is not the display window).
    return rowcoh * variation * (coverage ** 2)


def crop_window(vram16, window):
    """Crop (x,y,w,h) from the uint16 VRAM, clamped to bounds. Returns uint16."""
    x, y, w, h = window
    x = max(0, min(x, VRAM_W))
    y = max(0, min(y, VRAM_H))
    w = max(1, min(w, VRAM_W - x))
    h = max(1, min(h, VRAM_H - y))
    return vram16[y:y + h, x:x + w], (x, y, w, h)


def autodetect_window(vram16):
    """Pick the display window. Returns (window, crop_source, score, candidates)."""
    luma_full = luma_of(rgb555_to_rgb8(vram16))
    dx, dy, dw, dh = DEFAULT_WINDOW
    # Clamp the default to VRAM in case dims are odd.
    dh = min(dh, VRAM_H - dy)
    dw = min(dw, VRAM_W - dx)
    default_score = natural_image_score(luma_full[dy:dy + dh, dx:dx + dw])

    candidates = [("default-topleft", (dx, dy, dw, dh), default_score)]

    if default_score >= NATURAL_SCORE_ACCEPT:
        return (dx, dy, dw, dh), "default-topleft", default_score, candidates

    # Top-left is weak (likely the cleared back-buffer). Scan alternate origins.
    # The displayed buffer holds a COMPLETE frame, so among the busy candidates the
    # right one fully contains its image: rank by (coverage, then natural score) so
    # a window that fully holds the frame beats one that merely clips its bright
    # half. (coverage = fraction of non-black pixels inside the candidate.)
    w, h = DEFAULT_WINDOW[2], DEFAULT_WINDOW[3]
    h = min(h, VRAM_H - SCAN_ORIGIN_Y)
    best = None
    best_rank = (-1.0, -1.0)
    for ox in SCAN_ORIGINS_X:
        # Clamp the window to the display band so a probe can NEVER bleed into the
        # x>=384 texture atlas (which would false-positive on texture memory).
        ww = min(w, DISPLAY_BAND_END_X - ox, VRAM_W - ox)
        if ww < 8:
            continue
        reg = luma_full[SCAN_ORIGIN_Y:SCAN_ORIGIN_Y + h, ox:ox + ww]
        s = natural_image_score(reg)
        cov = float((reg > 4.0).mean())
        cand = ("autodetect-scan", (ox, SCAN_ORIGIN_Y, ww, h), s)
        candidates.append(cand)
        # quantize coverage so near-full windows tie and natural score breaks it.
        rank = (round(cov, 1), s)
        if rank > best_rank:
            best_rank = rank
            best = cand
    # Only trust a scan winner that clears the confidence floor. Otherwise the dump
    # was caught mid-clear (display genuinely blank, like titlehunt_10): keep the
    # documented TOP-LEFT -- it IS the display window, just captured empty -- and
    # flag it. NEVER fall through to texture memory; never crash on an all-black dump.
    if best is None or best_rank[1] < SCAN_CONFIDENCE_FLOOR:
        return (dx, dy, dw, dh), "fallback-blank", default_score, candidates
    return best[1], "autodetect-scan", best_rank[1], candidates


def make_frame(vram16, window=None):
    """Produce the native-res RGB8 frame + metadata dict from a VRAM array."""
    if window is not None:
        cropped16, used = crop_window(vram16, window)
        crop_source = "hw-regs"  # caller supplied an authoritative window
        score = natural_image_score(luma_of(rgb555_to_rgb8(cropped16)))
        candidates = [("user-window", used, score)]
    else:
        used, crop_source, score, candidates = autodetect_window(vram16)
        cropped16, used = crop_window(vram16, used)

    rgb8 = rgb555_to_rgb8(cropped16)
    x, y, w, h = used
    meta = dict(
        window=dict(x=x, y=y, w=w, h=h),
        native_w=int(w), native_h=int(h),
        crop_source=crop_source,
        natural_score=round(float(score), 4),
        mean_luma=round(float(luma_of(rgb8).mean()), 2),
        nonblack_frac=round(float((luma_of(rgb8) > 4.0).mean()), 4),
        candidates=[
            dict(source=c[0], window=list(c[1]), score=round(float(c[2]), 4))
            for c in candidates
        ],
        colorspace="rgb8",
    )
    return rgb8, meta


def parse_window(s):
    parts = s.split(",")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("--window must be X,Y,W,H")
    return tuple(int(p) for p in parts)


def run_file(path, window, out, as_json):
    vram16 = load_vram(path)
    rgb8, meta = make_frame(vram16, window=window)

    if out is None:
        out = os.path.splitext(path)[0] + "-display.png"
    try:
        from PIL import Image
        Image.fromarray(rgb8, "RGB").save(out)
    except ImportError:
        # PPM fallback so the tool still works without Pillow.
        out = os.path.splitext(out)[0] + ".ppm"
        h, w = rgb8.shape[:2]
        with open(out, "wb") as f:
            f.write(f"P6\n{w} {h}\n255\n".encode("ascii"))
            f.write(rgb8.tobytes())
    meta["out"] = out
    meta["vram"] = path

    if as_json:
        print(json.dumps(meta, indent=2))
    else:
        w = meta["window"]
        print(f"vram        : {path}  ({VRAM_W}x{VRAM_H} RGB555 LE)")
        print(f"display win : x={w['x']} y={w['y']} w={w['w']} h={w['h']}  "
              f"(crop_source={meta['crop_source']})")
        print(f"native size : {meta['native_w']}x{meta['native_h']}  (no upscale)")
        print(f"natural score: {meta['natural_score']:.4f}   "
              f"mean luma {meta['mean_luma']:.1f}   "
              f"non-black {meta['nonblack_frac']*100:.0f}%")
        if meta["crop_source"] == "autodetect-scan":
            print("  [i] top-left window was weak; probed alternate display-band "
                  "origins:")
            for c in meta["candidates"]:
                print(f"      {c['source']:16s} {tuple(c['window'])}  "
                      f"score={c['score']:.4f}")
        elif meta["crop_source"] == "fallback-blank":
            print("  [!] LOW CONFIDENCE: the display window is BLANK in this dump "
                  "(captured mid-clear / back-buffer empty).")
            print("      Emitting the documented top-left window anyway; pass an "
                  "explicit --window if the front buffer is elsewhere.")
        print(f"wrote       : {out}")
    return 0


# ----------------------------------------------------------------------------
# SELF-TEST: synthetic VRAM with a known bright rectangle at a known window on a
# dark field; confirm the tool crops EXACTLY that rectangle (both via --window
# and via auto-detect), decodes RGB555 correctly, and never returns a black frame.
# ----------------------------------------------------------------------------
def selftest():
    ok = True

    def check(cond, msg):
        nonlocal ok
        status = "PASS" if cond else "FAIL"
        print(f"  [{status}] {msg}")
        if not cond:
            ok = False

    rng = np.random.default_rng(573)
    # Dark field with faint noise (NOT a natural image: low coherence).
    vram = (rng.integers(0, 2, size=(VRAM_H, VRAM_W), dtype=np.uint16)) & 0x0001

    # Plant a bright NATURAL-LOOKING rectangle at a known window.
    WX, WY, WW, WH = 0, 0, 384, 240
    # Smooth vertical gradient => high row coherence + high variation + full cover.
    grad = np.linspace(2, 31, WH).astype(np.uint16)[:, None]    # 5-bit ramp down rows
    horiz = (np.arange(WW, dtype=np.uint16) % 32)[None, :]      # horizontal texture
    rcomp = ((grad + horiz) % 32) & 0x1F                        # R 0..31
    gcomp = (grad % 32) & 0x1F
    bcomp = ((31 - grad) % 32) & 0x1F
    rect16 = (rcomp | (gcomp << 5) | (bcomp << 10)).astype(np.uint16)
    vram[WY:WY + WH, WX:WX + WW] = rect16

    # --- 1. RGB555 decode correctness on a known pixel ---
    # Pure red = R=31,G=0,B=0 -> 0x001F -> (248,0,0)
    px = rgb555_to_rgb8(np.array([[0x001F]], dtype=np.uint16))[0, 0]
    check(tuple(px) == (248, 0, 0), f"RGB555 0x001F -> {tuple(px)} (expect (248,0,0))")
    pxb = rgb555_to_rgb8(np.array([[0x7C00]], dtype=np.uint16))[0, 0]
    check(tuple(pxb) == (0, 0, 248), f"RGB555 0x7C00 -> {tuple(pxb)} (expect (0,0,248))")

    # --- 2. Explicit --window crops EXACTLY that rectangle ---
    rgb8, meta = make_frame(vram, window=(WX, WY, WW, WH))
    check(rgb8.shape == (WH, WW, 3),
          f"--window output shape {rgb8.shape} == ({WH},{WW},3)")
    # Reconstruct the expected RGB and compare byte-exact.
    expect = rgb555_to_rgb8(rect16)
    check(np.array_equal(rgb8, expect), "--window pixels byte-exact vs planted rect")
    check(meta["native_w"] == WW and meta["native_h"] == WH,
          f"native size {meta['native_w']}x{meta['native_h']} == {WW}x{WH}")

    # --- 3. Auto-detect finds the planted top-left rectangle ---
    rgb8a, metaa = make_frame(vram, window=None)
    win = metaa["window"]
    check((win["x"], win["y"], win["w"], win["h"]) == (WX, WY, WW, WH),
          f"auto-detect window ({win['x']},{win['y']},{win['w']},{win['h']}) "
          f"== planted ({WX},{WY},{WW},{WH})")
    check(metaa["crop_source"] == "default-topleft",
          f"auto-detect crop_source={metaa['crop_source']} (expect default-topleft)")
    check(np.array_equal(rgb8a, expect), "auto-detect pixels byte-exact vs rect")
    check(metaa["mean_luma"] > 10.0, f"auto-detect frame NOT black (luma {metaa['mean_luma']})")

    # --- 4. Double-buffer case: top-left blank, a full natural image sits in the
    #        DISPLAY band at the x=256 origin. The scan must pick a display-band
    #        window (x in SCAN_ORIGINS_X), fully covered + non-black, and NEVER the
    #        x>=384 texture atlas. ---
    vram2 = np.zeros((VRAM_H, VRAM_W), dtype=np.uint16)  # top-left dead black
    bw = DISPLAY_BAND_END_X - 256                          # 128 wide front buffer
    grad2 = np.linspace(2, 31, WH).astype(np.uint16)[:, None]
    horiz2 = (np.arange(bw, dtype=np.uint16) % 32)[None, :]
    rect2 = (((grad2 + horiz2) % 32) & 0x1F).astype(np.uint16)
    vram2[0:WH, 256:256 + bw] = rect2                     # front buffer at x=256
    # Also fill the texture band busy to PROVE the scan won't grab it.
    vram2[0:WH, 384:768] = 0x3DEF
    rgb8b, metab = make_frame(vram2, window=None)
    winb = metab["window"]
    check(metab["crop_source"] == "autodetect-scan",
          f"blank-topleft crop_source={metab['crop_source']} (expect autodetect-scan)")
    check(winb["x"] in SCAN_ORIGINS_X and winb["x"] >= 256,
          f"scan picks a display-band origin x={winb['x']} (expect in {SCAN_ORIGINS_X[1:]})")
    check(winb["x"] + winb["w"] <= DISPLAY_BAND_END_X,
          f"scan window stays in display band (x+w={winb['x']+winb['w']} <= "
          f"{DISPLAY_BAND_END_X}) -- never grabs texture memory")
    check(metab["mean_luma"] > 10.0,
          f"scan result NOT black (luma {metab['mean_luma']})")

    # --- 4b. Mid-clear case: display band genuinely blank, only the texture atlas
    #         busy -> emit top-left with the blank-fallback flag; do NOT roam into
    #         texture memory, do NOT crash. ---
    vram3 = np.zeros((VRAM_H, VRAM_W), dtype=np.uint16)  # display band all black
    vram3[0:WH, 700:1000] = 0x3DEF                        # only texture band busy
    rgb8c, metac = make_frame(vram3, window=None)
    check(metac["crop_source"] == "fallback-blank",
          f"mid-clear crop_source={metac['crop_source']} (expect fallback-blank)")
    check((metac["window"]["x"], metac["window"]["y"]) == (0, 0),
          "mid-clear emits documented top-left window (0,0), not texture memory")

    # --- 5. natural_image_score discriminates image vs flat ---
    flat = np.full((WH, WW), 50.0, dtype=np.float32)
    img = luma_of(rgb555_to_rgb8(rect16))
    check(natural_image_score(img) > natural_image_score(flat),
          f"score(image)={natural_image_score(img):.3f} > "
          f"score(flat)={natural_image_score(flat):.3f}")

    print(f"\nSELFTEST: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def main(argv):
    ap = argparse.ArgumentParser(
        description="Convert raw 573 HW VRAM (1024x512 RGB555 LE) to the "
                    "native-resolution displayed frame PNG.")
    ap.add_argument("vram", nargs="?", help="raw VRAM dump (.bin)")
    ap.add_argument("--window", type=parse_window,
                    help="crop EXACTLY this display rectangle: X,Y,W,H")
    ap.add_argument("--out", help="output PNG path")
    ap.add_argument("--json", action="store_true", help="emit JSON sidecar to stdout")
    ap.add_argument("--selftest", action="store_true", help="run synthetic self-test")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()
    if not a.vram:
        ap.error("vram dump path required (or use --selftest)")
    try:
        return run_file(a.vram, a.window, a.out, a.json)
    except (ValueError, FileNotFoundError, OSError) as e:
        print(f"hw_display_frame: error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
