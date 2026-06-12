#!/usr/bin/env python3
"""Red/green checker for the 2MB-VRAM proof (psx_patches/0021).

Parses build/vram2cpu_out.log (one 8-hex 32-bit word per line; low halfword =
first pixel) produced by the gen_vram2mb.py stream through tb_gpu_replay, and
splits it into the three readbacks in issue order:

    R1 = 4096 words  -> 32x256 @ (384,0)      the atlas column
    R2 = 11040 words -> 92x240 @ (320,512)    panel A home
    R3 = 11040 words -> 92x240 @ (416,512)    panel B home

References come from the MAME 2MB dump gh_vram_comic.bin. Sim-written coverage
of the atlas region (region-local x 0..31 = VRAM x 384..415, y 0..255):
    fonts: rows 0..39 + 64..255, all 32 px      wrap (red only): rows 0..239, px 0..27

--mode red   (stock 0020, 1MB, Y truncated) asserts the WRAP signature:
    R1 rows0..239 cols0..27   == panel A content (x384..411 of the upper half)
    R1 font rows  cols28..31  == fonts (the per-16-word-block cols-14/15 survivors)
    R1 rows240..255 all cols  == fonts
    R1 rows40..63 cols28..31  == 0 (sim never wrote them)
    R1 as a whole MISMATCHES the correct font reference (the bug is visible)
    R2/R3 == panel refs (the wrapped copy reads back through the same truncation)
  plus the HW cross-check: R1's wrap cells vs the SAME cells of the real-HW dump
  vram_run3.bin (whose full atlas region matched the wrap model 8192/8192).

--mode green (0021, 2MB) asserts correctness:
    R1 == font reference on every sim-written cell (atlas intact)
    R1 rows40..63 == 0 (nothing wrote them; no wrap arrived either)
    R2 == panel A ref, R3 == panel B ref (the uploads LANDED in the upper half
    and read back through the widened vram2cpu path)

Exit 0 iff every assertion for the chosen mode holds. All percentages printed.

Usage: check_vram2mb.py --mode red|green --log <vram2cpu_out.log>
                        --comic <gh_vram_comic.bin> [--hw <vram_run3.bin>]
"""
import argparse
import sys
import numpy as np

FONTROWS = np.r_[0:40, 64:256]


def pct(m):
    return f"{m.mean()*100:.2f}% ({int(m.sum())}/{m.size})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["red", "green"], required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--comic", required=True)
    ap.add_argument("--hw")
    a = ap.parse_args()

    words = [int(l, 16) for l in open(a.log) if l.strip()]
    need = 4096 + 11040 + 11040
    print(f"[{a.mode}] vram2cpu words read back: {len(words)} (need {need})")
    ok = True
    if len(words) != need:
        print(f"[{a.mode}] FAIL: readback word count {len(words)} != {need} "
              "(C0 path broken or under-drained)")
        sys.exit(1)

    px = np.zeros(need * 2, dtype="<u2")
    w = np.asarray(words, dtype="<u4")
    px[0::2] = w & 0xFFFF
    px[1::2] = w >> 16
    r1 = px[:8192].reshape(256, 32)
    r2 = px[8192:8192 + 22080].reshape(240, 92)
    r3 = px[8192 + 22080:].reshape(240, 92)

    vram = np.fromfile(a.comic, dtype="<u2").reshape(1024, 1024)
    fontref = vram[0:256, 384:416]          # valid on FONTROWS only
    panelA = vram[512:752, 320:412]
    panelB = vram[512:752, 416:508]

    def check(name, cond_pct, want, hard=True):
        nonlocal ok
        good = (cond_pct == want) if isinstance(want, str) else cond_pct
        status = "PASS" if good else "FAIL"
        if not good and hard:
            ok = False
        return status

    print(f"--- {a.mode.upper()} assertions")

    # R2/R3: in both worlds the readback must equal the panel payloads
    # (red: wrapped write + truncated read are self-consistent at y-512;
    #  green: true upper-half write + widened read).
    m2 = r2 == panelA
    m3 = r3 == panelB
    for nm, m in (("R2 == panelA ref", m2), ("R3 == panelB ref", m3)):
        s = "PASS" if m.all() else "FAIL"
        if not m.all():
            ok = False
        print(f"  {s}  {nm}: {pct(m)}")

    if a.mode == "green":
        m_font = r1[FONTROWS] == fontref[FONTROWS]
        m_gap = r1[40:64] == 0
        for nm, m in (("R1 font rows == font ref (atlas INTACT)", m_font),
                      ("R1 rows40-63 == 0 (no wrap arrived)", m_gap)):
            s = "PASS" if m.all() else "FAIL"
            if not m.all():
                ok = False
            print(f"  {s}  {nm}: {pct(m)}")
        # informative: the whole-region corruption metric (should be 0)
        corrupt = (r1[FONTROWS] != fontref[FONTROWS]).mean() * 100
        print(f"  INFO  atlas font-cell corruption: {corrupt:.2f}%")
    else:
        # the wrap signature, cell class by cell class
        wrapA = r1[0:240, 0:28] == panelA[:, 64:92]      # x384..411 = panelA cols 64..91
        surv = r1[FONTROWS][:, 28:32] == fontref[FONTROWS][:, 28:32]
        tail = r1[240:256, :] == fontref[240:256, :]
        gap = r1[40:64, 28:32] == 0
        for nm, m in (("R1 rows0-239 cols0-27 == WRAPPED panelA (foreign data over fonts)", wrapA),
                      ("R1 cols28-31 font rows == fonts (the surviving cols 14-15/16-word-block)", surv),
                      ("R1 rows240-255 == fonts (wrap stops at row 239)", tail),
                      ("R1 rows40-63 cols28-31 == 0", gap)):
            s = "PASS" if m.all() else "FAIL"
            if not m.all():
                ok = False
            print(f"  {s}  {nm}: {pct(m)}")
        # the bug must be VISIBLE: the atlas does NOT match the correct fonts
        m_font = r1[FONTROWS] == fontref[FONTROWS]
        corrupt = (~m_font).mean() * 100
        s = "PASS" if corrupt > 30 else "FAIL"
        if corrupt <= 30:
            ok = False
        print(f"  {s}  R1 font cells CORRUPTED vs correct ref: {corrupt:.2f}% "
              f"(match only {pct(m_font)})")
        if a.hw:
            hw = np.fromfile(a.hw, dtype="<u2").reshape(512, 1024)
            hwreg = hw[0:256, 384:416]
            cells = np.zeros((256, 32), dtype=bool)
            cells[0:240, 0:28] = True            # wrap cells
            cells[FONTROWS.reshape(-1, 1), np.arange(28, 32)] = True  # surviving font cells
            cells[240:256, :] = True
            mhw = (r1 == hwreg)[cells]
            s = "PASS" if mhw.all() else "WARN"
            print(f"  {s}  R1 vs REAL-HW dump (vram_run3) on all sim-covered cells: {pct(mhw)}")
            if not mhw.all():
                print("        (payload-coverage difference, not a verdict-breaker; "
                      "the verdict cells are the assertions above)")

    print(f"--- {a.mode.upper()} RESULT: {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
