# SignalTap CLUT-race capture — end-to-end runbook

Goal: catch, in one JTAG capture, WHY the pixelpipeline's resident CLUT row
(`textPalY`) is a neighbor row (480–509) instead of the requested 491 (0x1EB)
while the menu's 320 4bpp quads draw — and specifically CONFIRM or REFUTE
that display scanout (`gpu_videoout`) reads on the shared VRAM port are the
synchronized competing master. The arbiter OR-merges request addresses
(psx/rtl/gpu.vhd:1620-1623), so a same-cycle pixelpipeline+videoout request
pair corrupts the issued address — the watch list shows both sides.

The garble is deterministic and frame-synchronized (SSIM 0.93 across two
boards, 0.9985 across attract loops) and ALREADY reproduces on the DE10 on
dell's USB-Blaster II — no repro-confirmation step needed.

JTAG reality (proven live): the blaster is on `dell`; dell has no native
Quartus; ALL JTAG tooling runs via docker `raetro/quartus:17.0` (the same
image that builds the core — version-matched for SignalTap).

---

## 0. Generate + validate the .stp (Mac, seconds, no build)

```sh
cd tools/signaltap_573
tclsh clut_race_stp.tcl clut_race.stp
scp clut_race.stp dell:/tmp/clut_race_validate.stp
ssh dell 'printf "package require ::quartus::stp\nif {[catch {open_session -name /tmp/clut_race_validate.stp} e]} {puts \"OPEN-FAIL: \$e\"; exit 1}\nputs OPEN-OK\n" > /tmp/validate_stp.tcl && docker run --rm -v /tmp:/tmp raetro/quartus:17.0 quartus_stp -t /tmp/validate_stp.tcl 2>&1 | grep -E "OPEN|Error"'
```

Expect `OPEN-OK` (verified passing 2026-06-09). KNOW WHAT THIS PROVES:
open_session validates XML SHAPE only — a deliberately garbaged condition
text also passes (tested). The trigger-condition grammar is only truly
checked at the instrumented synthesis (step 2's map-report check) — that is
the authoritative gate.

## 1. Make the instrumented build branch

```sh
git checkout -b dbg-signaltap-clut feat-flash-load
tclsh tools/signaltap_573/clut_race_stp.tcl tools/signaltap_573/clut_race.stp
cat tools/signaltap_573/signaltap.qsf.snippet >> Konami_System_573.qsf
# if FIT.md's lever is needed (expected — see FIT.md): add the audio-IIR
# passthrough psx_patch on this branch too, BEFORE building
git add -A && git commit -m "dbg: SignalTap CLUT-race probe (debug branch only)"
git push -u origin dbg-signaltap-clut
```

The snippet becomes active because it is committed INTO Konami_System_573.qsf
on the ref that dell builds. Never merge this branch.

## 1b. REQUIRED: expand the .stp into SLD assignments (the actual insertion step)

**Learned the hard way (2026-06-10, one hollow 31-min build):** the compiler
does NOT read the .stp. `ENABLE_SIGNALTAP` + `USE_SIGNALTAP_FILE` are
GUI-side pointers; insertion is driven by the `SLD_*` QSF expansion (node
params + per-signal `CONNECT_TO_SLD_NODE_ENTITY_PORT` + `SLD_FILE` pointing
at a stripped stp in `db/`). Generate it headlessly ON DELL (the build box,
so `db/` lands where the compile runs), then commit the expanded QSF:

```sh
ssh dell 'docker run --rm -v $HOME/System573_MiSTer:/work -w /work raetro/quartus:17.0 \
  quartus_stp Konami_System_573 --stp_file tools/signaltap_573/clut_race.stp --enable'
scp dell:System573_MiSTer/Konami_System_573.qsf Konami_System_573.qsf
git add Konami_System_573.qsf && git commit -m "dbg: SLD expansion" && git push
```

Sanity before building: `grep -c CONNECT_TO_SLD Konami_System_573.qsf` ≈ 175
(87 data + 87 trigger + acq_clk) and `SLD_SAMPLE_DEPTH=4096` present.
A hollow build is detectable WITHOUT deploying: fit.rpt has no
`auto_signaltap`/`sld_hub` and M10K stays at the ~350 baseline (probe ≈ +42).

## 2. Build via the hub launcher (ONLY this way)

```sh
DELL_PROJECT=573 DELL_TARGET=Konami_System_573 DELL_REPO=System573_MiSTer \
  ~/Dev/mister-dev-hub/tools/dell_build.sh dbg-signaltap-clut
```

(`DELL_REPO` is a BARE dir name — never `~/...`.) Expect a slower fit
(SignalTap + 99% LABs ⇒ +30–60 min). When done, BEFORE deploying check on
dell (`~/System573_MiSTer/output_files/`):

```sh
# (a) every watched node resolved? unresolved nodes are silently dropped:
grep -i -A3 "signal tap" Konami_System_573.map.rpt | grep -i -E "warn|cannot|not found|ignored"
# (b) preserve/keep assignments that matched nothing:
grep -i -B2 -A6 "ignored assignment" Konami_System_573.fit.rpt | head -50
# (c) the SignalTap instance summary (node count should be 87, depth 4096):
grep -i -B2 -A10 "auto_signaltap_0" Konami_System_573.fit.rpt | head -40
```

If a node didn't resolve: usual causes are a `~reg0`-suffixed synthesized
name or a swept net — fix the name in clut_race_stp.tcl's tables (the map
report shows the real names) or add the missing KEEP/PRESERVE line, rebuild.
If the Fitter dies with Error 170011/11802 (comb-node overflow — likely at
our ceiling): apply the FIT.md lever and rebuild.

## 3. Deploy + de-confounded boot (NON-NEGOTIABLE protocol)

```sh
scp <the .rbf> mister:/media/fat/_Arcade/cores/Konami_System_573.rbf
ssh mister reboot                  # warm reboot — load_core inherits a stale
ssh mister cat /proc/uptime        # f2sdram bridge otherwise; require < ~60 s
# then EXACTLY ONE load_core (tools/mister_load.sh / the usual flow)
```

Boot hyperbbc, get to the capture scene of record: the operator MAIN MENU
(one R/Test press while the game runs — headless press injector if landed,
else coordinate with tools/the human). The menu redraws every frame, so the
trigger has fresh quads continuously.

## 4. HEISENBUG GATE — no capture is trusted before this number

The instrumented build MUST still exhibit the garble (SignalTap perturbs
placement at our near-full fit; if the bug moved/vanished, captures describe
a different machine):

```sh
tools/mister_shot.sh                       # grab the menu frame
python3 ~/Dev/mister-dev-hub/tools/frame_diff.py \
    <new_shot.png> local/de10_menu_watch/20260610_000842-screen.png
```

PASS = high similarity to the GARBLED reference (same corrupted panel
columns; SSIM in the ~0.9+ range like the cross-board match). FAIL (clean
menu, or different corruption) ⇒ STOP: record the result (itself a strong
placement-sensitivity datum), do not interpret captures from this build.

## 5. Capture (one command from the Mac)

```sh
tools/signaltap_573/capture.sh 300
```

It: checks the JTAG chain, stages a scratch copy of the .stp on dell, runs
`quartus_stp -t capture_headless.tcl` in docker (PASSIVE attach — the MiSTer
configured the FPGA; nothing is programmed), arms `trig_clut_race`, waits up
to 300 s, exports CSV, and copies `local/signaltap/<ts>/` back here.

- rc=0: triggered, CSV ready.
- rc=2: no trigger — is the garbled menu on screen? If yes, the wrong-row
  cube may not match: do the RECON pass (below).
- "Trigger not compatible with device": the running .rbf is not this
  instrumented build, or the .stp node list/depth changed since the build.

RECON pass (also the row-identification capture): in clut_race_stp.tcl set
the `textPalY[3] low` term to dont_care (delete the line), regenerate, rerun
— it then triggers on ANY stage1 pixel needing row 491. Read the actual
resident `textPalY` from the CSV, set an exact per-bit pattern for that row,
regenerate, capture again. NO REBUILD needed for any trigger retune (all
nodes are compiled as trigger inputs); rebuilds are only needed if the node
LIST, depth, qualifier setup, or clock change.

## 6. Reading the CSV

Columns = the 87 watched bits (named with full hierarchy paths); rows =
stored clk2x samples (storage-qualified: only `pipeline_busy=1` cycles, gaps
marked — `record_data_gap`). Trigger position "post" ⇒ ~7/8 of rows PRECEDE
the trigger row. Reconstruct multi-bit values from bits [n] LSB→MSB:
`stage1_palReqY`, `textPalY`, `textPalReqY` (9b, the CLUT rows);
`PP reqVRAMX/YPos` (what the pixelpipeline's fetch FSM issued);
`GP reqVRAMYPos` (the OR-MERGED address actually presented to the VRAM port).

Walk BACKWARD from the trigger row and find the last CLUT fetch episode
(`state.REQUESTPALETTE` → `state.WAITPALETTE` + the burst of `CLUTwrenA`
beats). Decision table:

| Observation in the pre-trigger window | Verdict |
|---|---|
| `videoout_reqVRAMEnable=1` overlapping `pipeline_reqVRAMEnable=1`, and `GP reqVRAMYPos` ≠ what `PP reqVRAMYPos` issued (OR-corrupt) | CONFIRM scanout — address corruption at the merge (gpu.vhd:1620-23) |
| Pipeline holds `state.REQUESTPALETTE` but `reqVRAMIdle=0` because `videoout_reqVRAMEnable=1` streak; by the time it wins, `textPalReqY` has been overwritten to a neighbor row | CONFIRM scanout — fetch starvation + stale shared latch |
| CLUT fetch for 491 runs clean (GP reqVRAMYPos=491, full CLUTwrenA burst, videoout quiet) yet trigger still fires with `textPalY`≠491 | REFUTE scanout — loss is in the request/latch ordering upstream (the patch-0018 "shared textPalReqY overwritten" mechanism) or CLUT-write vs pixel-read ordering |
| `textPalReqY` never equals 491 anywhere in the window while `stage1_palReqY`=491 | latch drop BEFORE the fetch — look at the textPalInNew→textPalReqY handoff |

Whatever the verdict: the capture is the NUMBER for this hypothesis — quote
sample indices/values, not vibes, in any status post.

## 7. Cleanup

The debug branch stays unmerged. Production ships without ENABLE_SIGNALTAP;
no RTL was touched (node preservation was QSF-only), so there is nothing to
revert in psx/.

## Post-build gate additions (learned 2026-06-10, build #3 fired never)
After EVERY instrumented build, before deploying, on dell:
1. `grep -c 136017 output_files/Konami_System_573.fit.rpt` must be **0**
   (any hit = a preserve assignment was silently ignored -> tag registers
   swept -> probe trigger inputs tied to GND -> trigger can never fire).
2. `grep -c "stage1_palReqY" output_files/Konami_System_573.fit.rpt` must be
   well above 2 (placed cells, not just warning echoes).
3. M10K ~= baseline+42 and auto_signaltap present (hollow-build check, step 1b).

## CRC gate (learned 2026-06-10, builds #3-#5 could never ARM)
Error 261009 "not compatible... expected 0x0, read 0x0" = the .stp carried
CRC="0" (hand-authored XML), --enable tied all 32 crc[] pins to gnd, and the
runtime REFUSES a zero checksum even when it matches. The CRC is a
self-consistency token copied verbatim from the .stp attribute into the
crc[] vcc/gnd tie pattern at --enable time (verified: popcount + bit
positions follow the attribute). Fix: any NONZERO CRC in the generator
(ours: 573C1EB1), re-enable, rebuild. Gate: grep crc Konami_System_573.qsf
must show a MIXED vcc/gnd pattern, never all-gnd.
ALSO: capture.sh's "TRIGGERED"/"NO TRIGGER" verdicts are UNRELIABLE when
arming fails -- on any anomaly read the FULL quartus_stp output (Error
261009 appears there, followed by a bogus TRIGGERED + an Internal Error in
sdr_data_log.cpp during the doomed export).

## Boot-window captures (learned 2026-06-10, the write-side verdict runs)
NEVER arm before load_core: the FPGA reconfig KILLS an armed analyzer
(2x Error 12852 JTAG-chain integrity, PRE->IDLE disarm, then a dead poll to
timeout). Any no-fire from an arm-before-load flow is a DEAD-ARM artifact,
not evidence. Working flow: load_core, then capture.sh at T0+5s -- ROM
streaming delays the game's first uploads to ~T0+30-40s, so the race is
easily won, no input injection needed.
Always verify the boot actually reached the game before grading a boot
capture (screenshot >15KB at T0+~115s; the garbled menu compresses to ~2KB
so size-gates apply to ATTRACT frames only).
Board reset: OSD/keyboard injection is currently dead on de10 (alt+f1, F12,
LCtrl+LAlt+RAlt all inert; one press froze the game) -- reset via
`dell_coord.sh devlock de10 reboot 573` only.
Heisenbug watch: 0/3 armed-through-boot halts after the protocol above; the
one HARDWARE ERROR remains n=1 (correlated with armed-through-boot + a
killed agent).
.stp variants for the word-boundary probe: clut_race_word_u2anchor.stp
(U2-anchored) and clut_race_word_u1alt.stp (U1 alternate trigger).
