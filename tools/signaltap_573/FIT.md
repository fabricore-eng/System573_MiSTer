# FIT.md — will the SignalTap probe fit? (honest arithmetic)

Baseline (memory `fpga-resource-budget`, post-cd_top-removal milestone build):
ALM 37,632/41,910 = **90%** post-pack, **LAB 99%**, DSP 112/112 = 100%,
**block RAM 63%** (~348/553 M10K). BUT the post-pack ALM% is NOT the binding
number: the 2026-06-07 NVRAM-SD datapoint (b689557) showed the design is
**pre-pack comb-ALUT-bound at the 83,820 hard cap** — a ~600-ALM feature
produced "85,009 blocks of type combinational node; device has only 83,820"
(Fitter Error 170011, over by 1,189). Working assumption: **comb-node
headroom ≈ zero** on the unmodified branch.

## What the probe costs

**M10K (data buffer):** stored width ≈ 87 data bits + ~2-3 SignalTap
overhead (gap/qualifier marking) ≈ 90. M10K in 512×20 mode ⇒ lanes =
ceil(90/20) = 5; depth 4096 ⇒ 4096/512 = 8 blocks/lane ⇒ **40 M10K** + ~2
for hub/control ≈ **42 M10K**. 348+42 = 390/553 ≈ **71% — comfortably safe**
(RAM is our one roomy resource). Fallback depth 2048 ⇒ ~21 M10K, 67%.

**Logic:** 87 channels × (input pipeline FF + runtime basic-trigger
comparator ≈ 2 ALUT-ish/channel) ≈ 175–350, storage-qualifier compare ≈
trivial (1 node), capture FSM + address counters + JTAG/SLD hub ≈ 150–300
ALM. Plus the QSF-preserved patch-0018 tag chain (stageS/0/1_palReqY, 27 FFs
+ feed cones, otherwise swept) ≈ 50–150 ALUTs. **Estimate: ~350–600 ALMs,
of which ~400–900 pre-pack comb nodes.** Zero DSP.

## Verdict

- M10K: **no risk** at depth 4096.
- ALM post-pack: fits (90% + ~1.5%).
- **Pre-pack comb nodes: HIGH RISK** — ~400–900 added against ≈0 headroom ⇒
  expect Fitter Error 170011/11802 on the unmodified branch. Do not burn a
  3 h fit to find out: **pair the lever with the FIRST instrumented build.**
- LAB 99%: placement pressure ⇒ slower fit and real Heisenbug potential —
  hence the mandatory frame_diff garble-still-present gate (RUNBOOK §4).

## The lever (cheapest, from the ranked recovery plan)

**Audio IIR → passthrough** — frees **~433 ALM + 8 DSP**, LOW risk, ZERO
boot exposure (HPS-configured framework path; the BIOS can't address it).
EXACT change: in **`psx/sys/audio_out.sv` line ~201** replace the
`IIR_filter #(.use_params(0)) ...` instantiation with direct passthrough of
its outputs (`wire [15:0] acl = cl; wire [15:0] acr = cr;`), keeping the
DC_blocker + mixer downstream untouched. NOTE: the build uses **psx/sys**
(repo QSF pulls psx/sys/sys.qip, not the repo's sys/), i.e. this lives in
the VENDORED tree ⇒ it must land as a **numbered psx_patches/ patch applied
on the DEBUG branch only** (vendored-pristine rule), not a direct edit.
Debug build loses the audio low-pass — irrelevant for a graphics capture.

If 170011 STILL fires: add lever #2 — **ascal bicubic off** via
`.MASK(8'h03)` on the ascal instance in `psx/sys/sys_top.v` (~line 715
upstream-equivalent): orphans the bicubic MAC chain, ~10-14 DSP + a few
hundred comb-heavy ALMs, but pruning is SPECULATIVE (runtime `IF MASK(...)`
inside a process, not a generate — verify the orphaned bic_* regs actually
pruned in the fit report). HDMI keeps nearest/bilinear scaling; CRT/VGA path
unaffected. Same vendored-tree/patch rule.

Last resorts (MEDIUM risk, only if both above fail): joypad_pad+lightgun
strip (~700 ALM) or savestate partial (~300-600 ALM) per the ranked plan —
but at that point reconsider depth 2048 + trimming the watch list (drop
`textPalReqY` 9b + `vram_pause` + `reqVRAMDone` ⇒ −11 channels) first.

## Build-time expectation

98%-era builds took 2.5–3 h routes when timing-driven routing fought the
placement; at 90% ALM the milestone builds are ~45 min. SignalTap + preserve
+ 99% LABs lands in between: **budget ~1–2 h**, and treat a >3 h grind as a
fit-failure signal (kill, apply lever #2, relaunch — per the dd76ade
precedent where a doomed fit ground 119 min before being killed).
