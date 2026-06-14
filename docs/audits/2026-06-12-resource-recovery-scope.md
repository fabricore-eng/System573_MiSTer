# Resource-recovery feasibility scope (System 573 core)

**Date:** 2026-06-12 · **Branch:** `feat-flash-load` · **Scope:** BOARD-FREE, read-only.
No RTL edits, no build performed.

**Question:** the core is at the Cyclone V (5CSEBA6U23I7, DE10-Nano) density ceiling. Two
features now fail to FIT (Error 11802 / routing congestion): the SignalTap cassette probe,
and the 16 MB onboard-flash persistence feature (commit `af32f6a`). Resource recovery
therefore gates BOTH persistence (small) AND the DIO/MP3 stack for DDR (big). What can we
free, how much, at what regression risk, and is it ENOUGH?

---

## 1. The numbers (from the af32f6a fit, on `dell`)

Source of truth: `~/System573_MiSTer/output_files/Konami_System_573.{map,fit}.rpt` on
[[dell-build-box]] (synth 08:09Z, fit FAILED 08:29:54Z). All per-module figures below are
the **placed** values from the *Fitter* Resource Utilization by Entity table (line ~5966+),
i.e. real post-pack ALMs, not synthesis estimates.

### Device totals (this failed build)
| Resource | Used | Device | % | Note |
|---|---|---|---|---|
| Logic (ALMs needed) | 40,643 | 41,910 | **97 %** | post-pack |
| — ALMs in final placement | 39,633 | 41,910 | 95 % | placement SUCCEEDED |
| — recoverable by dense packing | 1 | — | <1 % | packing already maxed |
| — unavailable (LAB conflicts/input limits) | 1,011 | — | 2 % | the packing tax |
| **Total LABs used (partial/full)** | **4,168** | **4,191** | **99 %** | the real wall |
| Difficulty packing design | **High** | — | — | fitter's own verdict |
| Registers | 43,178 | 83,820 | 52 % | not binding |
| Combinational ALUTs for logic | 56,975 | — | — | (cap ≈ 83,820 comb nodes) |
| **DSP blocks** | **112** | **112** | **100 %** | hard ceiling, zero headroom |
| Block memory bits | 2,229,143 | 5,662,720 | 39 % | roomy |
| M10K RAM blocks | 360 | 553 | 65 % | roomy |
| PLLs | 4 | 6 | 67 % | room for 2 |

Synthesis estimated **124 DSP**; the fitter packed it down to exactly **112/112** by merging
multipliers (9×9 went 17→7). There is **no DSP headroom whatsoever.**

### The failure mode — congestion, NOT global resource exhaustion
The fit terminated on **routing congestion** (`Warning 16618`: "routing phase terminated due
to routing congestion"), then `Error 11802`. But the routing-usage summary shows global
interconnect is **lightly used**:

- Router estimated **average interconnect usage = 47 %**; **peak = 71 %** in ONE localized
  region (X45_Y35 → X55_Y45). (`fit.rpt` info 170196)
- Every interconnect class is 13–30 % used (Block 24 %, C2 25 %, C4 30 %, R3 23 %, R6 19 %).

So the congestion is **a localized hotspot driven by 99 % LAB occupancy + "High" packing
difficulty**, not a global wire shortage. The placer crammed cells so densely (1,011 ALMs lost
to LAB-input/signal conflicts) that one neighborhood can't route. The fit ran only **5 min of
routing** before giving up (total 20 min) — this is a *quick* congestion failure, not the
2.5–3 h timing-driven grind seen at the old 98 %-ALM era.

---

## 2. Where the resources go (per-module, placed ALMs / DSP)

Ranked by ALMs needed (placed). DSP column is the binding scarce resource.

### PSX core (`psx_top`, vendored) — the bulk
| Module | ALMs | comb ALUT | regs | M10K-bits | **DSP** | 573 need? |
|---|---:|---:|---:|---:|---:|---|
| gpu (igpu) | 7,314 | 11,038 | 7,836 | 253,884 | **35** | YES (real silicon) |
| gte (igte) | 4,663 | 6,280 | 3,104 | 80 | **15** | YES* (3D math; see §3) |
| spu (ispu) | 4,754 | 6,555 | 3,573 | 603,264 | **13** | YES (audio) |
| cpu (icpu) | 3,871 | 4,249 | 3,377 | 663,552 | **6** | YES |
| dma (idma) | ~1,640 | 2,643 | 1,308 | 5,440 | 0 | YES |
| joypad (ijoypad) | 1,020 | 1,721 | 1,042 | 2,048 | 0 | mostly NO (§3) |
| — joypad_pad (PSX pad SM) | 534 | 1,012 | 328 | 0 | 0 | **NO** (JVS, not PSX pads) |
| mdec (imdec) | 714 | 1,223 | 764 | 59,328 | **9** | **likely NO** (§3) |
| savestates (isavestates) | 647 | 892 | 718 | 0 | 0 | optional (menu only) |
| memorymux | ~840 | 1,206 | 519 | 0 | 0 | YES |
| memctrl | ~270 | 310 | 400 | 0 | 0 | YES |
| sio (isio) | 84 | 98 | 136 | 0 | 0 | YES (SIO1 = cassette/security DSR) |
| memcard1 / memcard2 | 64 / 64 | 87 / 87 | 133 / 133 | 8,192 ea | 0 | card1 YES (DDR edit-data); card2 NO |
| justifier_sensor ×2 (lightgun) | 20 + 21 | 68 | 18 | 0 | 0 | **NO** |
| irq / timer / exp2 | small | — | — | — | 0 | YES |
| **cd_top** | — | — | — | — | — | **already removed** (patch 0011; 0 refs in report) |
| **cheats** | — | — | — | — | — | **already removed** (patch 0008; 0 refs) |

\* gte is the single largest remaining DSP prize (15) but HIGH risk — see §3.

### MiSTer framework (`sys_top` direct children, vendored `psx/sys`)
| Module | ALMs | regs | M10K-bits | **DSP** | recoverable? |
|---|---:|---:|---:|---:|---|
| **ascal** (HDMI scaler) | 2,256 | 3,879 | 315,488 | **25** | partial — bicubic-off (§3) |
| audio_out (total) | 952 | 1,007 | 0 | **8** | yes via IIR passthrough |
| — IIR_filter (low-pass) | 436 | 353 | 0 | **8** | **yes** (§3, lowest-risk DSP win) |
| hps_io | ~1,600 | 1,401 | 0 | 0 | NO (Main interface) |
| pll_cfg / video_calc / alsa / gamma / osd | small each | — | — | 0 | NO |

ascal + IIR together = **33 DSP (29 % of the whole budget)** in pure framework code — the DSP
ceiling is a *MiSTer-framework* wall, not 573 silicon (the 573-specific stuff uses 0 DSP).

### 573-specific (`system573_top`) — LEAN, ~4,400 ALM / 0 DSP total
| Module | ALMs | comb ALUT | M10K-bits | DSP | note |
|---|---:|---:|---:|---:|---|
| s573_seccart (x76f041 536 + x76f100 247 + zs01 + ds2401) | 898 | 1,231 | 4,992 | 0 | security carts (Feature A) |
| atapi | 495 | 922 | 0 | 0 | CD/ATAPI (Feature B) |
| s573_flash | 275 | 214 | 0 | 0 | NOR flash array |
| m48t58 (NVRAM RTC) | 180 | 311 | 130,944 | 0 | high-score persistence |
| k573dio (DIO board) | 170 | 307 | 65,536 | 0 | **DDR — stub, see §4** |
| — k573_mp3stream | 31 | 70 | 0 | 0 | **DDR — stub, see §4** |
| — k573_mp3dec (descrambler) | (≈0, folded) | — | — | 0 | **DDR — stub, see §4** |
| s573_cdimg / s573_io / adc / bus | small | — | — | 0 | YES |

### The persistence feature (what overflowed)
| Module | ALMs | comb ALUT | regs | M10K-bits | DSP |
|---|---:|---:|---:|---:|---:|
| **s573_flash_saver** | **155.8** | 194 | 281 | 16,384 | 0 |
| s573_nvram_saver | 21 | 14 | 54 | 0 | 0 |

Persistence costs only **~156 ALMs / 0 DSP**, but it tipped LAB occupancy to 99 % and broke
routing in the X45–X55 hotspot. It placed fine — it failed to *route*.

---

## 3. Recovery candidates — ranked, with regression risk

Ground rules (from prior project doctrine, [[fpga-resource-budget]]):
- Every vendored-`psx/` removal is a numbered `psx_patches/NNNN-*.patch` + its own
  apply-clean + NVC elaboration + `make -C sim` pass + a boot A/B test before commit.
- `psx/sys/` levers (ascal, IIR) are also vendored ⇒ patches, not direct edits.
- LogicLock/Design-Partition floorplanning is **NOT available** (subscription feature; Web
  Edition silently strips it — Critical Warning 140003). So the only license-free levers are
  free ALM/LAB headroom, RTL pipelining, per-cell `set_location`, and fitter seed.

| # | Candidate | Frees ALM | Frees DSP | M10K | Risk | What verifies it's safe |
|---|---|---:|---:|---|---|---|
| 1 | **Audio IIR → passthrough** (`psx/sys/audio_out.sv` ~L201: replace `IIR_filter` inst with `wire [15:0] acl=cl, acr=cr;`, keep DC_blocker+mixer) | ~436 | **8** | 0 | **LOW** | HPS-configured framework path; BIOS can't address it ⇒ zero boot exposure. Debug builds lose only the audio low-pass. |
| 2 | **ascal bicubic off** (`.MASK(8'h03)` = nearest+bilinear on the ascal instance) | few-hundred | **~10–14** (SPECULATIVE) | small | LOW–MED | HDMI keeps nearest/bilinear scaling; CRT/VGA path untouched. **Pruning is speculative** — ascal gates bicubic with a runtime `IF MASK(...)` inside a process (not `IF…GENERATE`), so the orphaned `bic_*` MAC regs only free DSP if Quartus dead-code-eliminates them. **Verify in the fit report that bic_* pruned.** |
| 3 | **joypad_pad + lightgun strip** (patch joypad.vhd: drop `ijoypad_pad` + `justifier_sensor` ×2 + gpu_crosshair; tie receiveValidPad/BufferPad/ackPad/isActivePad idle, irq_PAD=0) | ~575 (534+41) | 0 | 0 | **MED** | 573 uses **JVS**, not PSX pads (MAME `ksys573.cpp`: inputs are JAMMA/JVS, no PSX controller port). **KEEP joypad_mem + memcard1** (DDR/Dancing Stage edit-data save to PS1 card). Touches a shared OR-bus (joypad.vhd:349/382-3) ⇒ sim + HW A/B before commit. |
| 4 | **memcard2 + SNAC pad paths** (second card unused; trim) | ~64 + misc | 0 | 8,192 | MED | Only card1 is a real 573 use (edit-data). Confirm no game mounts a 2nd card. |
| 5 | **savestate partial stub** (stub `isavestates`/`istatemanager` FSM+DDR3 only; drive load_done/ss_reset/loading_savestate/savestate_busy benign, SS_wren/SS_rden=0) | ~300–647 | 0 | 0 | **MED–HIGH** | **KEEP the per-module `ss_in` array** — it is LOAD-BEARING for reset (`reg<=ss_in(...)` on reset, e.g. irq.vhd:91). Deleting `ss_in` is the change class that broke boot before. Loses only the savestate menu + the garble-capture workaround. |
| 6 | **mdec removal** (FMV/MJPEG decoder) | ~714 | **9** | 59,328 | **MED–HIGH** | 573 arcade games are flash/CD program-ROM driven; MDEC is the consumer-PSX *FMV* path. **Likely unused** (no 573 game in our library is a streaming-FMV title; hyperbbc/hypbbc2p/DDR/GuitarFreaks are sprite/3D, not Sony FMV). BUT prior audit left this DEFERRED because CD-game MMIO scan was inconclusive (execs use SDK wrappers, not direct 0x1F801820 MDEC MMIO). **Verify:** disasm the actual game binaries for MDEC reg access (0x1F801820/24) before removing; the 9 DSP makes it the 2nd-best DSP prize after gte. |
| 7 | **gte removal/shrink** (COP2 3D math) | ~4,663 | **15** | 80 | **HIGH** | Largest DSP prize, but DDR/GuitarFreaks/3D titles **may use COP2**. BIOS doesn't; games can. **Do NOT remove without per-game disasm proof of zero COP2 ops.** Not a near-term candidate. |

### DSP math after the safe levers
- Current: 112/112 (100 %).
- After #1 (IIR, −8 DSP, certain): **104/112** — clears the hard DSP ceiling, gives 8 of headroom.
- After #1 + #2 (ascal bicubic, −10–14 if it prunes): **~90–94/112** — comfortable.
- Irreducible PSX-silicon DSP floor ≈ **69** (gpu 35 + gte 15 + spu 13 + cpu 6 — note gpu came in
  at 35 here vs the older 33). The full DSP budget reconciles to 112 exactly: PSX core 78 (gpu 35 +
  gte 15 + spu 13 + cpu 6 + mdec 9) + framework 33 (ascal 25 + audio/IIR 8) + 1. So even the
  framework levers alone get us well clear of the ceiling; the silicon itself is not DSP-bound.

### ALM/LAB math after the safe levers
- Persistence needs ~156 ALMs placed.
- #1 frees ~436 ALM, #3 frees ~575 ALM, #5 frees ~300–647 ALM.
- **#1 + #3 alone free ~1,000 ALMs** (≈97 %→94 %), and crucially drop LABs off the 99 % wall,
  which is what relieves the localized congestion. That is **~6× the persistence delta** — ample
  for persistence with margin to spare.

---

## 4. The DIO/MP3 (DDR) budget — the decision-critical finding

The k573dio / k573_mp3stream / k573_mp3dec blocks are **currently instantiated but are STUBS**:

- `k573dio.v:18` documents the registers as "MPEG control (FPGA - **stub**)" and "MAS3507D
  I2C (**stub**)".
- `k573_mp3stream.v:18-20` states plainly: *"the real MP3 sample/frame counter in hardware is
  derived from the decoder's frame-sync and **is not modeled here (it needs actual MP3
  decoding)**."*
- `k573_mp3dec.v` is the Konami **descrambler** only — it un-scrambles the bitstream
  word-by-word; it does **not** decode MP3 to PCM.
- The descrambled byte stream is wired out of system573_top (`dio_mp3_byte`/`dio_mp3_valid`)
  but **dangles** at the emu.sv instantiation (`.dio_mp3_byte()`, `.dio_mp3_valid()` —
  empty) — nothing consumes it.

So today the entire DIO/MP3 subsystem costs only **~200 ALM / 0 DSP** because it is the
descrambler + streaming FSM with **no decoder behind it.** A DDR title that needs to actually
*hear* its MP3 soundtrack requires a real MP3 decoder (or a HW MAS3507D model): Huffman
decode → IMDCT → polyphase synthesis filterbank. A synthesizable MP3 decoder is a **large**
block — order **3,000–8,000+ ALMs and several DSPs** (the IMDCT/synth filterbank is
multiply-heavy) — none of which exists in this design yet.

**This is the crux:** the ~200-ALM figure for DIO/MP3 is NOT the DDR budget. It is the cost of
the *plumbing*. The DDR audio budget is the cost of an MP3 decoder we have not built and have
not measured. Resource recovery must be sized against *that*, not against the stubs.

---

## 5. Math: recoverable vs needed

| Need | ALM | DSP | Verdict on recovery |
|---|---:|---:|---|
| **Persistence NOW** (s573_flash_saver) | ~156 | 0 | **EASILY met.** #1+#3 free ~1,000 ALM + drop LABs off 99 %. Even #1 alone (~436 ALM) likely suffices, and a fitter-seed retry might squeak the current design in with no recovery at all (see §6). |
| **Persistence + working DIO/MP3 *plumbing*** (DDR boots, security/CD path, no real audio) | ~156 + ~0 (stubs already in) | 0 | **Met** by the same levers. The DIO stubs already fit. |
| **Persistence + REAL MP3 decoder** (DDR with audio) | ~156 + **~3,000–8,000** | ~0 + **several** | **NOT met by recovery alone.** Even stripping EVERYTHING safely removable: |

### Maximum realistic recovery (all safe/medium levers, before touching gte)
| Lever | ALM | DSP |
|---|---:|---:|
| #1 IIR passthrough | 436 | 8 |
| #2 ascal bicubic (if it prunes) | ~300 | 10–14 |
| #3 joypad_pad + lightgun | 575 | 0 |
| #4 memcard2 + SNAC | ~80 | 0 |
| #5 savestate partial | ~300–647 | 0 |
| #6 mdec (if disasm clears it) | 714 | 9 |
| **TOTAL (optimistic)** | **~2,400–2,750** | **~27–31** |

Add gte (#7, HIGH risk, only if no 3D game needs COP2): +4,663 ALM / +15 DSP → up to ~7,000 ALM.

**Conclusion on DDR:** recovering ~2,400–2,750 ALM (safe-to-medium) is **probably NOT enough**
for a full MP3 decoder at the *upper* end of the estimate (~8k ALM), and is marginal even at
the lower end (~3k) once you also account for the additional DIO datapath (DRAM streaming,
MAS3507D I2C, the frame counter) that the real audio path needs on top of the decoder. It
*might* fit if the decoder lands near 3k ALM AND gte (#7) can also be removed (no COP2 game) —
that combination frees ~7k ALM, which would cover it. But that is two HIGH-risk bets stacked.

**Honest verdict: resource recovery on this die can comfortably unblock persistence and the
DDR *boot/security/CD* path, but it likely CANNOT free enough for a full MP3-decoder audio
path for DDR without either (a) removing gte (needs proof no target game uses COP2) or (b)
offloading MP3 decode to the HPS/ARM side (software MP3 → PCM over the existing audio bridge)
rather than synthesizing it in fabric.** Option (b) is the architecturally cleaner path for
the big-audio DDR family and sidesteps the fabric ceiling entirely — it should be evaluated
before committing to an in-fabric MP3 decoder.

---

## 6. Congestion vs ALM count — is recovery even the right lever for persistence?

The failure is **localized routing congestion at 99 % LABs / "High" packing difficulty**, with
global interconnect only 47 % avg / 71 % peak. Two implications:

1. **Recovery (fewer cells) IS the right structural lever** — freeing ALMs drops LAB occupancy
   off 99 %, loosens placement density, and removes the packing tax (1,011 ALMs currently lost
   to LAB-input/signal conflicts). #1+#3 do this cheaply and with low risk.

2. **BUT a fitter-seed retry is a legitimate zero-cost interim for persistence.** Because the
   congestion is one hotspot (not a global shortage) and the design *placed* successfully
   (95 % final-placement ALMs), a different seed may place that neighborhood less densely and
   route. This is cheap to try and could land persistence *today* with no RTL change:
   - Set a different `SEED` in the QSF (or vary placement effort), relaunch via the hub
     launcher, and watch for a clean route.
   - Treat a >1 h route as a fail signal (kill, apply lever #1, relaunch) — the af32f6a fail
     was fast (5 min routing), so a clean seed should also resolve fast.
   - **Recommended:** pair a seed retry with lever #1 in the *first* recovery build so you don't
     burn a build proving the seed alone is insufficient (the FIT.md precedent: pair the lever
     with the first instrumented build).

---

## 7. Verdict + recommended order

**Persistence: GO.** It needs ~156 ALMs; the die can free 6×+ that safely. The blocker is LAB
congestion, not a true resource shortage.

**DDR boot/security/CD path: GO** (the DIO stubs already fit at ~200 ALM / 0 DSP).

**DDR with real in-fabric MP3 audio: AT RISK / likely NO via recovery alone.** A synthesizable
MP3 decoder (~3–8k ALM + several DSP) does not exist yet and probably won't fit even after
stripping everything safe (~2.4–2.75k ALM) unless gte is also removable (no-COP2 proof) or the
decode is moved to the HPS/ARM side. **Decide the MP3-decode architecture (fabric vs HPS) before
investing in recovery for it.**

### Recommended execution order
1. **Lever #1 (audio IIR passthrough)** — frees 8 DSP (clears the 100 % DSP ceiling) + ~436
   ALM, LOW risk, zero boot exposure. Do this first; it unblocks the DSP wall for everything.
2. **Pair #1 with a fitter-seed retry of the persistence build** — cheapest path to land
   persistence; either the seed alone routes, or #1's headroom does.
3. If still tight: **#3 (joypad_pad + lightgun strip)** — ~575 ALM, drops LABs further. 573 is
   JVS so PSX pads are genuinely dead weight; just A/B the shared OR-bus.
4. **#2 (ascal bicubic off)** if more DSP headroom is wanted for the DIO datapath — verify the
   bic_* regs actually prune in the fit report (speculative).
5. For DDR audio specifically: **disasm target games for COP2 (gte) and MDEC use** (#6/#7
   gating), and **evaluate HPS-side MP3 decode** as the alternative to an in-fabric decoder.
   Do NOT remove gte/mdec without per-game proof.

### Doctrine reminders
- Each vendored removal = a numbered `psx_patches/` patch + apply-clean + NVC elab + `make -C
  sim` + boot A/B (the vendored-pristine rule).
- No LogicLock/partitions (Web Edition strips them) — headroom + seed + pipelining + per-cell
  `set_location` are the only license-free placement levers.
- Verify every "fits now" claim with the actual fit report's LAB% + congestion lines, and
  every "still boots" claim with a frame_diff NUMBER (CLAUDE.md non-negotiable #2).

---

## Sources
- `dell:~/System573_MiSTer/output_files/Konami_System_573.fit.rpt` (fit, FAILED 2026-06-12
  08:29:54Z): device totals, Fitter Resource Utilization by Entity (placed ALM/DSP per module),
  Routing Usage Summary, congestion warnings 16618/16684, Error 11802.
- `…/Konami_System_573.map.rpt` (synth 08:09Z): synthesis 124-DSP estimate, comb-ALUT for
  logic 56,975, Analysis & Synthesis Resource Utilization by Entity.
- `dell:/tmp/dellbuild-573.log`: build rc=3, 5-min routing termination, Error 11802.
- `rtl/k573dio.v`, `rtl/k573_mp3stream.v`, `rtl/k573_mp3dec.v`: DIO/MP3 = stubs/descrambler,
  no real MP3 decoder; `rtl/emu.sv:2094-95` (dio_mp3 outputs dangling).
- `rtl/s573_flash_saver.v`: persistence feature (the af32f6a overflow).
- Prior project memory [[fpga-resource-budget]], [[573-library-roadmap]];
  `tools/signaltap_573/FIT.md` (IIR/ascal lever recipes + the comb-node-cap datapoint).
- MAME `src/mame/konami/ksys573.cpp` (JVS inputs, no PSX pad port) and
  `src/mame/konami/k573fpga.cpp` (the descrambler our k573_mp3dec mirrors).
