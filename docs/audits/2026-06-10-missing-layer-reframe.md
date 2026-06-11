# The garble verdict: a MISSING LAYER, not a wrong palette (2026-06-10)

**TLDR.** The hyperbbc "graphics garble" — chased for weeks as a render-time
wrong-palette bug — is the game **never submitting** its 320-textured-quad
panel layer to the GPU on our core. The visible "garble" is the menu's font
rects drawing **correctly** (their legitimate CLUT row 480) over the black
void where the missing layer should be. Proven by SignalTap boundary
captures on live silicon; every prior render-path theory is dead by
measurement.

## The capture-proven facts (build #9, dual-boundary probe, garbled menu on screen)
- **No 0x2C-family textured-quad opcode ever crosses dma→gpu** (stream
  trigger, 60 s, a scene that should carry 320/frame).
- **No row-491 CLUT attribute ever crosses** (relaxed trigger, clutX
  don't-care).
- What DOES cross: env preamble, frame clear, and 58 textured 8×8 font
  rects using clut(256,480) — row 480 is the font's REAL palette.
- sdram→dma→gpu passthrough bit-identical (the words are faithful to RAM).

## The wrong turns (preserved deliberately — they are the story)
1. Weeks of wrong-palette/CLUT-race theories (patches 0014–0019 treated a
   healthy render path; each failed on HW).
2. This sprint's own arc of instrument-caught confounds: a hollow build
   (M10K gate caught it), dead trigger inputs (map-report gate), a dead
   capture clock (same), a zero CRC refusing to arm, a FALSE fix-negative
   (patch never built — apply-script gap), and finally an AI-confident
   "low-bit mangling" numerology (480/481/487 as "manglings" of 491) built
   on values that were INNOCENT all along — overturned within hours by the
   relaxed-trigger + stream captures and an adversarial decode pass.
3. The trigger over-constraint (clutX=0) that made two earlier no-fires
   look like "no clut words on DMA" — caught by the any-write liveness
   capture + word-level decode.

## The surviving indictment
The game's own logic skips building/submitting the panel layer on our core.
That requires an INPUT the game reads to differ from real hardware:
573-specific I/O readback territory (EXP1/flash semantics, device/NVRAM
state — the exact ground patches 0009/0010 walk). Consistent with every
stubborn fact: deterministic, bit-identical across boards and builds,
immune to read-timing changes, invisible to GPU-isolated sim, clean in
MAME on the same data.

## Next hunt (bounded, per the manager's decision tree)
CPU trace-diff vs MAME (hub tools/trace_diff.py + tools/trace/) at the
menu's frame-list build/submission decision; walk the live menu OT
(exists-but-unlinked vs never-built). NAME the divergent input, then
assess fix-cost, then ship/background.

Companion docs: 2026-06-10-sdram-capture-audit.md (the falsified physical
theory, with the CL3 spec fix that stays), tools/signaltap_573/RUNBOOK.md
(the five silent-failure gates), read_stp_csv.py (validated decoder).
