# 2026-06-10 — SDRAM read-capture audit (physical-timing lens on the CLUT low-bit mangle)

**Question.** GP0 words arrive at the GPU with the CLUT halfword's low clutY bits dropped
(true `0x7AC0` → `0x7800`/`0x7840`; clutY 491 → 480/481), deterministically, same .rbf on two
boards. All RTL is exonerated (patched `sdram.sv` simulated bit-exact under exact DMA pacing +
ch4 flash pressure; GPU DMA-port ingest bit-exact; render path capture-proven). Which of the
573's SDRAM-side changes could shift the *physical* relationship between the chip's data-valid
window and our capture edge while staying RTL-correct?

**Diff surface.** The ONLY sdram.sv delta vs the pristine submodule (`git -C psx show
HEAD:rtl/sdram.sv`) is `psx_patches/0007-sdram-ch4-flash.patch` (verified: working-tree diff =
patch, 133 lines). 0009 (`memorymux.vhd` EXP1 byte-lane replication) and 0010 (EXP1 reqsize,
`memorymux/psx_top/psx_mister`) are clk1x bus-side EXP1 changes with **no SDRAM-pad
interaction** — out of scope for capture timing.

---

## 1. Fixed points (verified, not assumed)

These pin down what CANNOT have moved relative to upstream PSX:

1. **The DQ capture register is in the IOE.** `sys_pins.tcl` carries
   `FAST_INPUT_REGISTER ON -to SDRAM_DQ[*]` and the fit report confirms all 16 bits of
   `emu:emu|sdram:sdram|dq_reg[15:0]` are *Packed Register / Fast Input Register assignment*
   into `SDRAM_DQ[n]~input` (fit.rpt lines 4458–4473). Pad→FF data delay is therefore an IOE
   constant per pin — **immune to fanout/placement churn**.
2. **All SDRAM pad assignments are bit-identical to upstream.**
   `diff <(grep ^set_ psx/sys/sys.tcl | grep SDRAM | sort) <(grep ^set_ sys_pins.tcl | grep SDRAM | sort)`
   → empty. Same pins, same `FAST_OUTPUT_REGISTER ON -to SDRAM_*`,
   `FAST_OUTPUT_ENABLE_REGISTER ON -to SDRAM_DQ[*]`, `FAST_INPUT_REGISTER`, IO standard, max
   current. Command/address/BA/DQM/DQ-out all launch from IOE FFs, as upstream.
3. **Every intra-FPGA path is STA-covered and MET.** Multicorner summary
   (`output_files/Konami_System_573.sta.rpt` on dell): clk1x +1.448, clk2x +0.348,
   clk3x +0.899 worst setup slack; hold ≥ +0.070 on all psx domains. The only violating
   domain is `pll_hdmi` (−2.359, TNS −80.2) — the MiSTer framework HDMI/scaler domain, which
   cannot produce *pre-render, CLUT-field-specific* word corruption (it would mangle the
   scaled output picture globally). So the dq_reg→ch1_dout fanout paths, the widened arbiter
   mux into `cas_addr`/`SDRAM_A` (IOE FFs are normal in-domain endpoints), and the
   clk3x→clk1x `ch1_dout→dma_data` crossing are all *verified-met*, not just RTL-correct.
4. **SDRAM_DQ input / SDRAM_* output pad timing is UNconstrained** (no `set_input_delay`/
   `set_output_delay` anywhere: `psx/PSX.sdc` is pristine video-PLL-only;
   `psx/sys/sys_top.sdc` has no SDRAM lines; `Konami_System_573.sdc` is a placeholder).
   Normal for MiSTer — but it means STA says NOTHING about the pad↔chip eye. That eye is the
   only place left for a physical fault, which is consistent with the evidence chain.
5. **Clocks:** clk3x = 101.6064 MHz (9.8425 ns), SDRAM_CLK = `altddio_out` of clk3x with
   `datain_h=0, datain_l=1` → inverted clk3x (chip clocks on our falling edge, ~180°).
   Unchanged by any patch.

**Corollary:** the 0007 deltas can only matter through (a) the *traffic sequence* they put on
the unconstrained pad interface, or (b) second-order fit effects on the *clock network*
(IOE capture-edge arrival). Everything else is provably equivalent or STA-met.

## 2. Candidate-by-candidate (the requested checklist)

| 0007 change | Physical failure mode it could cause | Verdict vs signature |
|---|---|---|
| **dq_reg / SDRAM_DQ sampling path** — fanout grows 12→20 halfword sinks/bit (`ch4_dout` adds 8×16 FFs) | Fanout could pull a fabric dq_reg toward loads, lengthening pad→FF | **Exonerated as a capture-edge shifter**: dq_reg is IOE-packed (fixed pad→FF); the grown fanout is post-capture, clk3x-internal, STA-met (+0.899). Residual effect: more fit pressure → see R3. |
| **data_ready_delay4 vs upstream chain** | A length/width change would move which clk3x edge latches each beat | **Exonerated by inspection**: all four regs are `[CAS_LATENCY+BURST_LENGTH:0]` = [10:0], identical start bit (set at STATE_RW1) and identical taps [7]..[0]. delay4 is a clone, not a modification. |
| **READA cadence** | A cadence change would alter beat spacing/ISI | **Not changed**: STATE_IDLE_9..IDLE_4 (READ every 2 clk3x, 4×burst-of-2, A10 auto-precharge) is untouched; ch4 *reuses* the ch1 `saved_128read` sequence verbatim. The cadence is the victim window, not a delta. |
| **CAS-latency assumption** | CL2 at 101.6 MHz is OUT of standard SDR spec (CL2 is rated to ~100 MHz; tAC(CL2) ≈ 6 ns max on -7 parts). The capture eye at the IOE exists only thanks to uncharacterized clock-network insertion delay | **Inherited upstream marginality — the enabling condition.** Not a 0007 delta, but the reason a traffic-only delta can tip specific DQ pins. Feeds R1/R2; also the lever for the FIX. |
| **ch arbiter widening (2→3 bits) + ch4 grant arm** | `ch` is a routing tag, not arbitration; priority order for ch1/2/3 unchanged; ch4 added last. Mux-cone growth into `cas_addr`/`SDRAM_A`/`SDRAM_BA`/`chip` is in-domain, STA-met. Real effect: an in-flight ch4 burst defers a ch1 grant by up to ~13 clk3x | **Not a capture-edge shifter; it is a SEQUENCE shifter** — ch1 GPU bursts now start at new phases relative to writes/refresh/ch4 tails. Feeds R1. |
| **SDRAM_CLK generation** | Phase/edge change would move the chip's launch edge | **Exonerated**: altddio_out block byte-identical to upstream (same inversion, same oe). |
| **dqm timing** | DQM high ≤2 cycles before a beat masks/tri-states it → that beat reads stale bus state (low-bit-droppy!) | **Exonerated with a cycle walk**: ch4 drives `cas_addr[12:11]=00` exactly like ch1; DQM stays 00 from the first READ until past the last beat-minus-2; a back-to-back next grant re-drives row bits onto A[12:11] at IDLE+1, which affects data at IDLE+3 — the old burst's last beat is already captured at IDLE. No window where DQM ≠ 00 inside the read-latency-2 horizon, even ch4→ch1 back-to-back. |
| (checked) **chip-select alternation** | Two physical chips handing off the DQ bus between bursts | **Dead**: `FLASH_START = 27'h0100_0000` → `ch4_addr[26]=0`; flash backing and PSX RAM are both chip 0 (different *bank*, addr[24]). No CS alternation exists. |

## 3. Ranked mechanism candidates

### R1 (top) — ch4-interleaved traffic sequence erodes an already-out-of-spec pad eye (ISI / SSO / write→read turnaround)
0007 adds a *continuous* new consumer of full-rate 8-beat bursts: hyperbbc executes from
flash, so ch4 line fills interleave with everything, permanently. Two sequence classes that
upstream PSX essentially never produces now dominate the bus:
* `dmafifo` chained write-bursts (the CPU/DMA writing the GP0 list to RAM) immediately
  followed by the ch1 GPU-DMA read of the same data (write→read DQ turnaround with the bus
  pre-charged to the last written word's levels), and
* ch4-burst ↔ ch1-burst back-to-back rounds (different bank, same chip, zero idle DQ cycles
  between data tails and next commands).

Under sustained toggling, inter-symbol interference and simultaneous-switching noise on the
unterminated DQ stubs delay the 0→1 transitions of *specific board-skewed lines* past the
fixed IOE capture point; those lines capture the previous bus state (a 0) instead. With CL2
@ 101.6 MHz the eye has near-zero margin to begin with (Section 1.5), so a few-hundred-ps
pattern-dependent push is enough.

**Signature match:** low-bit-only ✓ (failing lines = DQ6/7/9 of the high lane, 0x2C0 — fixed
board skew picks the victims); per-word deterministic ✓ (ISI is a function of the exact data
pattern + fixed routes → same words always fail the same way, same .rbf, both boards);
GPU-DMA-cadence-only ✓ (GP0 list reads are precisely the bursts that sit in the
write-chain→read turnaround and ch4-adjacent slots; ch4 code-fetch reads are proven clean by
execution — they're read-after-read steady-state, the gentlest sequence). RTL-correct against
an idealized memory model ✓ (an ideal model has no ISI/turnaround analog behavior).

### R2 — CL2 @ 101.6064 MHz spec violation as a standalone mechanism
Even without R1's aggravation: tAC(CL2) on common MiSTer modules (-7/-75 parts) is specified
at ≤100 MHz; at 101.6 MHz the data-valid window relative to our IOE capture edge is outside
the datasheet and survives on the accident of Cyclone-V global-clock insertion delay.
0007's only "contribution" is more heat/current and more bursts. Predicts the same signature
(per-pin marginality, pattern-determinism); differs from R1 only in *how little* aggravation
is needed. The fix is the same lever, which is why R1/R2 share the proposed patch.

### R3 — clock-network (GCLK) insertion-delay delta vs the upstream PSX fit
Our fit put clk3x on GCLK4/CLKCTRL_G4 (fit.rpt 10733/13433); upstream PSX's official fit may
use a different mux/spine, shifting every SDRAM IOE capture edge by O(100 ps) relative to the
upstream-proven eye position. Fixed per .rbf → deterministic ✓, both boards ✓. **Weakness:**
if the mangle is byte-identical across *different* .rbf fits (reported), a fit-specific delta
is implausible as the primary cause — different fits would move the marginal bits. Ranked
third; kept because it compounds R1/R2 (the eye position is uncharacterized, so each fit
re-rolls a few hundred ps).

**Explicitly demoted/killed:** dq_reg fanout placement (IOE-pinned), delay-chain length
(identical), READA cadence delta (none), DQM (cycle-walked clean), SDRAM_CLK (untouched),
chip alternation (single chip), arbiter mux depth (STA-met), pll_hdmi STA violation (wrong
domain for this signature).

## 4. PLL finding (`rtl/pll.qip not found`)

* **Origin:** `psx/sys/pll_q17.qip` line 1 — `set_global_assignment -name QIP_FILE rtl/pll.qip`
  (no `$::quartus(qip_path)` join) resolves against the *573 project root*, where
  `rtl/pll.qip` does not exist (it lives at `psx/rtl/pll.qip`). In the upstream PSX repo the
  project root makes that same line resolve correctly. Our `Konami_System_573.qsf` pulls
  `psx/sys/sys.qip` → `pll_q17.qip`, hence Warning 125092 in map/fit/asm.
* **No fallback PLL is substituted.** `files.qip` already includes `psx/rtl/pll.qip` and
  `psx/rtl/pll2.qip` explicitly (with correct qip_path), so the very IP the broken line was
  trying to add is compiled anyway. The warning is a duplicate-include attempt failing, i.e.
  cosmetic.
* **Compiled configuration == upstream, verified in the fit:** fit.rpt PLL Usage Summary shows
  `emu|pll` outputs 33.868799 / 67.737599 / 101.606399 MHz, operation mode **Direct**, phase
  shift **0.000000°** on all three counters — exactly the parameters in the pristine
  `psx/rtl/pll/pll_0002.v` (`"33.868800 MHz" / "67.737600 MHz" / "101.606400 MHz"`, all
  `"0 ps"`, `operation_mode("direct")`). `emu|pll2` (53.693175 MHz, /5 → clk_vid) likewise.
  **The fallback changes NO clock phase or frequency vs upstream PSX builds.**
* Optional hygiene (not required): a comment-only stub `rtl/pll.qip` at the project root
  would silence the warning; do NOT remove the `files.qip` includes (they are the real ones).

## 5. Latent, non-causal findings (for the record)

* `ram_idleNext` (sdram.sv:172) tests `!ch1_rq && !ch2_rq && !ch3_rq` but not `ch4_rq` — a
  stale "write accepted instantly" hint during ch4 activity. **Inert in the 573 build:**
  `rtl/emu.sv:1986` leaves `.ram_idle()` unconnected.
* `ch4_ready_ramclock` is set on the same clk3x edge as the last `ch4_dout` halfword capture
  (both on `data_ready_delay4[0]`), tighter than ch2/ch3's tap-[2] style but the clk1x
  resample (`ch4_ready <= ch4_ready_ramclock`) gives ≥1 clk1x of settle — matches the ch1
  `dma_done` idiom; benign.

## 6. Proposed fix — `psx_patches/0020-sdram-cas-latency-3.patch` (DESIGN ONLY, do not create yet)

**Target:** restore real, in-spec margin to the pad eye instead of re-rolling fit luck.
Addresses R1 and R2 simultaneously; also swamps any R3 contribution.

**Edit (exact):** `psx/rtl/sdram.sv` line 104:

```
-localparam CAS_LATENCY         = 3'd2;     // 2 for < 100MHz, 3 for >100MHz
+localparam CAS_LATENCY         = 3'd3;     // 3: clk3x is 101.6064MHz -- CL2 is only
+                                           // rated to 100MHz; CL3 puts every MiSTer
+                                           // module (-6/-7/-75) in spec with ~4ns of
+                                           // recovered data-valid margin at the IOE.
```

That single line is self-propagating by construction — verified against the source:
* `MODE` (line 107) embeds `CAS_LATENCY` → the chip is programmed CL3 at init.
* All four `data_ready_delay*` regs are declared `[CAS_LATENCY+BURST_LENGTH:0]` → widen
  [10:0]→[11:0] automatically.
* STATE_RW1 sets bit `CAS_LATENCY+BURST_LENGTH` (= 11) → every capture tap [7]..[0] fires
  exactly one clk3x later, which is precisely CL3's data arrival. No tap edits.
* FSM state count is UNCHANGED (the extra latency hides inside the existing IDLE_9..IDLE
  tail) → refresh budget, READA cadence, write paths, tRC spacing all untouched.

**Side-effect audit (walked, no code needed):**
1. *Read tail vs next write (DQ contention):* at CL3 the chip's last beat tri-states ~1.5
   clk3x after STATE_IDLE; the earliest next write drives DQ at pins at IDLE+3 → ≥1-cycle
   gap remains. No turnaround guard needed.
2. *Back-to-back bursts:* old delay-reg tail bits [1:0] coexist with a new start bit 11 in
   the same shift register — disjoint, shifts cleanly.
3. *Handshake latency:* every `*_ready`/`dma_done` tap fires 1 clk3x (~9.8 ns) later. All
   consumers are handshake-driven (no fixed-latency assumptions found in psx_mister/emu).
4. DQM read-latency-2 window: unchanged relative to the READ commands.

**Verification path (board-free first):** re-run the existing bit-exact sdram sim harness
(same DMA pacing + ch4 pressure) — expect identical data, +1 clk3x per access; then one HW
A/B with `frame_diff` numbers vs the current garble baseline.

**Cost: CHEAP.** One localparam (+comment), zero fabric/bandwidth cost, ~10 ns added access
latency, existing sim harness re-used. Fallback if it regresses: revert is one line;
escalation path = explicit `set_input_delay/set_output_delay` SDC for SDRAM_DQ vs a
`create_generated_clock` on SDRAM_CLK (structural, the engineering-grade endgame) or a
1-cycle inter-burst bubble after ch4 grants (moderate, costs bandwidth).

---

Part B (build #9 SignalTap channel plan) is in `tools/signaltap_573/BUILD9_PLAN.md`.
