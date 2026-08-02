# HDMI timing: the core was on Quartus defaults — and now MEETS TIMING for the first time

Date: 2026-07-30 · Branch: `feat-digital-bringup`

## TL;DR

**The core now meets timing at every corner — no negative slack anywhere in the STA report.**
The chronic `pll_hdmi` "requirements not met" flag it has carried since at least 2026-06-04 was
**real** (not a constraint artifact) and was **entirely the project never asking the fitter to
try**: it ran on Quartus defaults. Two build-setting changes closed it, with **no RTL change and
no feature removed**.

| Build | HDMI setup slack | TNS | ALMs |
|---|---|---|---|
| `6cf6e92` baseline (pre-MP3-slices) | -2.216 | -62.76 | — |
| `6422625` all three option-(c) slices | -2.143 | -55.65 | 39,157 (93%) |
| `95ef9cd` + High Performance Effort + phys-synth | -0.322 | -4.90 | 40,367 (96%) |
| `57bc85b` + **seed 3** | **+0.172** | **0.000** | **39,311 (94%)** |

Note the last row also came in *smaller* than the row above it: a different seed makes different
physical-synthesis choices, so closure cost less area than the intermediate step, not more.

## What was wrong, and what wasn't

The HDMI pixel clock is constrained to **148.54 MHz** (6.732 ns), the 1080p rate. A MiSTer core
does not choose its output mode — the user's `MiSTer.ini` does — so this is the bar every core
must meet, and missing it is a real defect regardless of who introduced it.

**It was not caused by the P4b MP3 work.** Measured both ways on identical toolchains:

| Build | ascal HDMI setup slack | TNS |
|---|---|---|
| `6cf6e92` baseline (RTL identical to the pre-session tree) | -2.216 ns | -62.76 |
| `6422625` with all three option-(c) slices | -2.143 ns | -55.65 |

The slices made it *marginally better*. Independently, the `dvd` lane recorded our core at
"worst **-2.5 ns** hdmi" on 2026-06-04 while cross-checking against it — two months before any
of this work.

**It was not a constraint artifact either**, which was my first hypothesis and it was wrong.
The `dvd` lane had found that MiSTer's `sys_top.sdc` declares no `set_clock_groups`, so
unrelated PLL domains get analysed as related and produce false cross-domain violations — for
their core, -101 ns of nonsense. Their diagnostic is logic levels: their genuine artifact was
**1 logic level with a 104 ns arrival**, which is physically impossible.

Running the same triage here (`quartus_sta` on the post-fit database, script adapted from
`NetVOB_MiSTer/tools/build/sta_clk_check.tcl`) said the opposite:

```
slack=-2.216  levels=3  arrival=17.234  required=15.018
    FROM ascal:ascal|o_vacpt[4]
    TO   ascal:ascal|o_adrs_pre[16]
##### INTRA-domain only (hdmi -> hdmi) #####
slack=-2.216  levels=3
```

**Intra-domain** (`hdmi → hdmi`, so clock-groups cannot apply) and **physically plausible**
(3 logic levels, arrival 2.2 ns past required). Every failing path was in `ascal`'s output
address generation. Real, and in framework code.

Note `psx/PSX.sdc` already declares the cross-PLL false paths including `pll_hdmi`, so the gap
the `dvd` lane hit is partly closed here — consistent with our failures being intra-domain.

## The fix

The project had **no** optimization settings at all: `Balanced`, no physical synthesis, seed 1.

```
set_global_assignment -name OPTIMIZATION_MODE "High Performance Effort"
set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON
```

| Build | HDMI slack | TNS | ALMs | Fits? |
|---|---|---|---|---|
| `6422625` default effort | -2.143 | -55.65 | 39,157 (93%) | yes |
| `95ef9cd` effort + phys-synth | **-0.322** | **-4.90** | 40,367 (96%) | yes |

TNS collapsing 91% matters as much as the worst-path number: it means nearly every failing
endpoint closed, not just the headline one. It remains the **only** failing clock.

`High Performance Effort` rather than `Aggressive Performance` on purpose — the die is at 100%
LAB occupancy and the aggressive mode trades area for speed, which here risks not fitting at
all. The +1,210 ALMs are physical synthesis duplicating registers to shorten paths.

## What this corrects

I spent an hour proposing to **delete logic** to buy timing before trying build settings. That
was the wrong order, and two of the three levers I offered were already spent — commit
`8dc9411` took the audio IIR, the PSX joypad+lightgun and memcard2/SNAC back in June
(`psx_patches/0025/0026/0027`). Quoting the June audit without checking what had since been
applied produced two stale recommendations. **Check `psx_patches/` before citing that audit.**

The remaining ALM levers are all the expensive tier — mdec (needs disassembly proof no game
uses it), gte (needs per-game COP2 proof), savestate stub. None of them were needed.

## Verifying the "meets timing" claim

Checked for negative slack across the WHOLE report, not just the setup summary — hold,
recovery, removal and minimum-pulse-width at every model. Beware the obvious grep: `'; *-'`
matches 645 lines that are pin rows reading `3.3-V LVTTL`, where the hyphen is part of the
voltage. The honest pattern needs a minus followed by digits in a slack column:

```
grep -oE '; *-[0-9]+\.[0-9]+ *;' output_files/Konami_System_573.sta.rpt
```

That returns nothing.

## Still open

- Nothing on timing. Worth re-checking after any future RTL of consequence: the fix is a
  fitter outcome, and closure at +0.172 ns is comfortable but not enormous.
- Whether closure changes anything observable. HDMI capture from this core has worked
  throughout (`tools/grab_card.sh de10`); the first ddrsbm gameplay footage was grabbed over
  HDMI. This was about guaranteeing it across silicon and temperature, not fixing a live break.

## Reproducing the triage

Post-fit, on dell, with the compilation database present:

```
docker run --rm -v "$PWD":/work -w /work --entrypoint quartus_sta \
  raetro/quartus:17.0 -t sta_hdmi.tcl
```

The script reports slack, **logic levels**, arrival and required per failing path, and
separates intra-domain from cross-domain. Levels ≈ 1 with an absurd arrival ⇒ constraint
artifact, ignore. Plausible levels and arrival ⇒ real, fix it. Reports are archived on dell in
`~/sta-compare/` for comparison across builds.
