# RETRACTED: "ddrsbm renders nothing" was a CAPTURE artifact, not a regression

Date: 2026-07-30 · Board: de10 · **Status: there is no boot regression. ddrsbm boots.**

## The retraction

This document originally reported a four-week boot regression in ddrsbm. **That was wrong.**
The game boots normally and sits at:

```
GQ894   JAA
DO YOU WANT TO INITIALIZE FLASH-ROM?
Yes:Please press test button
```

waiting for the TEST button. The human looked at the screen and said so; I could not see it
because every frame I captured was blank.

## What actually happened — a single-frame grab that intermittently returns black

`tools/grab_card.sh` pulls ONE frame (`ffmpeg -frames:v 1`) off the RTSP stream. On this core's
video mode that lands on a blank frame a large fraction of the time. Three consecutive grabs,
seconds apart, with the board untouched:

```
grab 1: 3431 bytes  md5 752c4665   <- black
grab 2: 16899 bytes md5 725835d0   <- the real screen
grab 3: 16899 bytes md5 725835d0   <- the real screen
```

Every "black screen" measurement in the original writeup was grab 1.

## The evidence I had, and misread

The black captures were **byte-identical (md5 `752c4665`) across different cores, different
boots, hours apart**. I recorded that as corroboration — "reproducible, therefore real".

It is the opposite. Identical PNG bytes across separate boots of different bitstreams is what a
DEAD OR BLANK SIGNAL looks like. A real screen varies: noise, timing, a cursor, a frame counter.
Byte-identical frames across independent runs should be read as *the instrument is stuck*, and
the correct response is to validate the capture, not to build a conclusion on it.

I also "validated" the capture by grabbing the MiSTer menu successfully. That proved the path
works for the MENU's 1080p output; it proved nothing about this core's video mode, which is
where the intermittency lives. A control has to exercise the same conditions as the measurement.

## The rule for next time

**Never accept a single frame as evidence.** Grab N ≥ 3 with a gap and require agreement; if
they disagree, the larger/richer frame is the real one and the blank is the artifact. A capture
that returns uniform black should be treated as NO MEASUREMENT until proven otherwise —
especially when it is byte-identical to a previous run.

## What survives from the original investigation

Three environment faults were found and fixed on the way. All are real and all were worth
fixing, even though none of them caused the (non-existent) regression:

1. **The launcher loads the core from `_Console`, not `_Arcade`.** A deploy to `_Arcade` left the
   board running a **three-week-old core**. Verify by checksum after every deploy.
2. **`saves/System573/ddrsbm.sav` was missing** — moved to `_bak_proofbench/` on 2026-07-15 and
   never restored while the `.mgl` still pointed at the original path. Restored from the golden
   copy (md5 `82243fe3…`).
3. **Config was wrong**, per `local/tracedig/dio_verify_v5_memcheck.sh` (the recorded working
   recipe, which should be read BEFORE any ddrsbm bring-up): boot device must stay **Flash**
   (`status[93]=0`), the **Solo strap** (`status[100]`) must be set, and Main's remembered slot-4
   mount (`config/System573.s4`) does **not** rebind from the `.mgl` and must be rewritten at
   MENU time.

Also fixed: `tools/mister_load.sh` printed a revert command using `cp -a` over the live binary,
which always fails with "Text file busy" — it now stages and `mv`s, like the install path.

## Where the MP3 bring-up actually stands

Unblocked. The game boots and is waiting at the flash-init prompt. The next move is to get past
that prompt (the TEST button is injectable via `tools/_mister_uinput_inject.py`) and reach
gameplay, then measure audio — the capture stream carries Opus 48 kHz stereo and `astats` gives
an unambiguous silence-vs-music number.

**Caution before pressing TEST:** "INITIALIZE FLASH-ROM" erases and reinstalls. The golden
install (`ddrsbm.sav`, md5 `82243fe3…`) is the thing that makes this game boot without a
20-minute CD install. Work out why the restore did not take BEFORE agreeing to initialize —
most likely the slot-4 rebinding, which is exactly what the v5 recipe exists to fix.

## Process notes worth keeping

- **Keep the old rbf before overwriting it.** Not doing so turned a two-minute A/B into a
  35-minute build.
- **A black frame is not evidence until the capture path is validated.** Capture something
  known-good in the same session.
- I attributed this failure three times before measuring it properly: "not our work", then
  "config", then "our work / the fitter settings". Only the fourth attempt — running an actual
  pre-session core — settled it. The intermediate claims were all consistent with the evidence I
  had and all wrong.
