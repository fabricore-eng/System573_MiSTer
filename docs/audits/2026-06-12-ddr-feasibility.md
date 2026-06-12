# DDR Feasibility — Unified Plan (System 573 MiSTer)

**Date:** 2026-06-12
**Scope:** Board-free research/scope synthesis. No RTL edits, no build.
**Inputs:** Four sub-scopes (MP3+descrambler architecture; DIO de-stub + undumpable MCU; target game + dumps; resource budget), plus the prior `docs/audits/2026-06-12-resource-recovery-scope.md` and a direct re-verification of the load-bearing RTL facts at HEAD.
**Author:** synthesis pass per the human.

---

## 0. Verdict — CONDITIONAL GO

**Getting a DIO/MP3 DDR title (e.g. DDR Solo Bass Mix / 3rd Mix) running on this core is FEASIBLE — CONDITIONAL GO.** It does *not* require removing GTE or MDEC, does *not* hit the 112/112 DSP wall, and is *not* blocked by the "undumpable MCU." The two conditions are: (1) the human must **source DDR dumps** — we have *zero* today; and (2) the **MP3-decode-on-HPS** path must be built from scratch (there is no upstream MiSTer template for HPS→core PCM injection), and its sample-counter coherence must hold for arrow timing.

The two make-or-break items, called out plainly:

- **MAKE-OR-BREAK #1 — HPS-side MP3 decode: FEASIBLE (the linchpin).** MAME itself decodes 573 MP3 in software with minimp3 (`mas3507d.cpp` → `mp3_audio.cpp`), so decode-off-fabric is the *reference-correct* architecture, not a shortcut. The Konami descrambler is already built and faithful in RTL (`k573_mp3dec.v`, both `decrypt_default` and `decrypt_ddrsbm` schemes), and the keys come from the **game code over the bus** — nothing to reverse-engineer or provision. The fabric cost is a small PCM FIFO + mixer + counter feedback (~350–700 ALM, 1 M10K, **0 DSP**). The *risk* is not feasibility but engineering: no off-the-shelf HPS→core PCM mechanism exists (MiSTer `audio.cpp` is volume/filter-only; ALSA is the wrong direction), so it must be written — but the CD-DA streaming path (NeoGeo CD / PCE-CD, `user_io_file_tx_data` + hps_io SD-block) is a direct, working copy-source already mirrored by this core's own `s573_cdimg.v`. **Confirmed feasible.**

- **MAKE-OR-BREAK #2 — the undumpable DIO MCU (`hd6473644h.18e`, "NO GOOD DUMP KNOWN"): RED HERRING, not a blocker.** Two "H8" things were being conflated and both are already solved: (a) there is **no MCU on the DIO board at all** — MAME's `k573dio.cpp` instantiates only the Altera FPGA HLE + a DS2401; (b) the `hd6473644h.18e` is on the **main board**, in a *dead* MAME ROM region — MAME never creates an H8 CPU from it. Its only observable behavior is a fully-dumped 64-byte response table (`h8a01.bin`/`h8b01.bin`, real CRCs), HLE'd by `h8_clk_w`. **Our core already implements this** at `rtl/s573_io.v:76-89` (it was one of the gates knocked down for hyperbbc). `mame -verifyroms sys573` reports the MCU missing **and** "1 romsets found, 1 were OK"; MAME runs every DDR title without it. **Not a blocker — exactly the cassette-BAD_DUMP situation.** (One small latent TODO: 700B's `h8b01.bin` is not a constant fill, so multi-BIOS support eventually needs a clock-stepped 64-byte ROM-backed shift register instead of the constant — ~tens of ALMs, off the DDR critical path.)

**Why CONDITIONAL and not unconditional GO:** the gate is **dumps, not silicon and not architecture**. Every DIO-based DDR set is also `MACHINE_NOT_WORKING` in MAME (0.285 and master), so MAME is **not a frame-diff oracle for DDR audio/timing** — verification of the MP3 path will lean on real-HW capture and on MAME only for the boot/security/CD layers. That removes our usual objective oracle for the very subsystem being built, which is the single biggest verification risk.

**If it were infeasible, this doc would say so.** The one path that *is* infeasible on this hardware is **in-fabric MP3 decode**: a synthesizable Huffman→IMDCT→polyphase-synth decoder is ~3,000–8,000 ALM + several DSP, which collides with both the ALM/LAB routing wall (the die already failed to route at 99% LAB with a mere +156-ALM feature) and the hard 112/112 DSP ceiling. It would force *both* HIGH-risk removals (GTE −4,663 ALM/−15 DSP and MDEC −714/−9), each needing per-game COP2/MDEC disasm proof that does not exist. **Reject in-fabric decode.** The HPS path is what makes the verdict GO.

---

## 1. Recommended architecture

**Descramble in fabric, decode on the HPS, mix PCM back into the SPU output.**

```
  GAME (PSX CPU)                    FABRIC (Cyclone V)                         HPS / ARM
  ─────────────                     ──────────────────                         ─────────
  scrambled MP3  ──EXP1 writes──►   k573dio board-DRAM window
  (0xb0/b2/b4)                      (TODAY: 4096-word M10K sim-sized;
                                     DDR: multi-MB in DDR3/f2sdram)
  keys 1/2/3     ──0xa8/ea/ec──►    crypto_key{1,2,3} latches
  start/end      ──0xa0..a6───►     mp3_start / mp3_end
  fpga_ctrl      ──0xae─────────►   k573_mp3stream FSM
                                         │ reads DRAM, byte-swaps
                                         ▼
                                    k573_mp3dec  (descrambler — DONE, faithful)
                                         │ descrambled MP3 bytes
                                         ▼
                                    dio_mp3_byte / dio_mp3_valid
                                    (TODAY dangle at emu.sv:2148-49)
                                         │
                                    NEW: MP3-byte → HPS transport
                                    (DDRAM ring or upload FIFO) ───────────►   minimp3
                                                                               mp3dec_decode_frame()
                                                                                    │ 16-bit stereo 44.1k PCM
                                    NEW: PCM-in FIFO ◄──── PCM back ───────────────┘
                                    + 2-ch mixer (sum with PSX SPU
                                      sound_out_l/r at emu.sv:1513-14)
                                    + sample-counter driven off the
                                      PCM-FIFO DRAIN (not bytes-sent)
                                         │ AUDIO_L/R
                                         ▼
  game polls 0xca/cc/ce ◄──counter feedback── (must track CONSUMED PCM)
```

**Keep (already built, faithful to MAME):**
- `k573_mp3dec.v` — Konami descrambler, both schemes + key schedule. Cost ~0 ALM folded.
- `k573_mp3stream.v` — streaming FSM (read DRAM → descramble → byte-swap → emit). ~31 ALM. (Its frame/sample counter is the stub: line 20 "is not modeled here (it needs actual MP3 decoding)" — *verified at HEAD*.)
- `k573dio.v` — register glue, board id `0x1234`, status `0xB000`, lamp fan-out with the `{0,2,3,1}` remap, DS2401, DRAM window. ~167 ALM.
- Security: `x76f100.v` / `x76f041.v` / `zs01.v` / `ds2401.v` / `s573_seccart.v` — all present; DDR cassettes covered.
- MCU HLE: `s573_io.v:76-89` — the 18E response check, already passing.

**Build (new, small fabric + new HPS C):**
1. **Un-dangle** `lamp_out`, `dio_mp3_byte`, `dio_mp3_valid` at `emu.sv:2147-2149` (and `system573_top.v:292-295`). *Verified dangling at HEAD.* This is step 1 of everything — even DDR's dance-pad read rides the lamp path (the GN845-PWB(B) foot-panel sensor mux is clocked by the lamp outputs: `ddr_output_callback` → `gn845pwbb_clk_w`/`do_w`).
2. **Board-DRAM → DDR3:** replace the 4096-word sim M10K (`k573dio.v:35` `RAM_WORDS=4096`, *verified*) with a multi-MB window backed by f2sdram/DDR3 (DDR3 capacity is free — block-mem is 39%). Few-hundred to ~1k ALM of control/FSM/FIFO; 0 DSP.
3. **MP3-byte → HPS transport:** DDRAM ring buffer or upload-channel readback. ~150–300 ALM, 0 DSP.
4. **PCM-in FIFO + SPU mixer + back-pressure:** one M10K, sum with `sound_out_left/right` before `AUDIO_L/R`. ~200–400 ALM, 0 DSP.
5. **HPS service (Main C):** read descrambled MP3 bytes, run minimp3 (header-only, ~3k LOC, zero deps — the *same* decoder MAME uses, inheriting its hardware-parity validation), pace PCM back to the core. Copy the CD-DA streaming scaffolding. The bulk of the *effort* is here, not in fabric.
6. **Sample-counter coherence (the one correctness detail that matters most):** the FPGA `0xca/cc/ce` counters DDR polls to sync arrows to music must track **consumed PCM (PCM-FIFO drain)**, not bytes-sent — otherwise step timing drifts. Spec against MAME's `mp3_frame_counter`/DAC-counter behavior (`get_counter() = counter_value * 44100`; the counter only advances on real frame-sync). In MAME a descrambler-without-decoder streams into a void and the counter never moves — which is exactly today's stub state.

**Leave stubbed (irrelevant to DDR PCM correctness):**
- **MAS3507D I2C at `0xac`** — config-only (volume/mute/gain), not on the PCM datapath. Stay a stub, or forward its gain bytes to the HPS mixer.
- **Network (RS485, `0xc0..c5`/`0x90`)** — MAME stubs it; not used by single-cabinet DDR.

---

## 2. Resource math — DDR FITS via HPS-MP3 (no GTE/MDEC removal)

**Source of truth:** the *successful* fit at HEAD `ca09f54` (persistence-UX build, psx_patch 0025 IIR-passthrough applied), `dell:~/System573_MiSTer/output_files/Konami_System_573.fit.summary` (Fitter Successful, 2026-06-12 09:27).

| Resource | Used | Device | % |
|---|---|---|---|
| Logic (ALMs) | 39,220 | 41,910 | **94%** |
| DSP Blocks | **112** | 112 | **100%** |
| Block memory bits | 2,229,143 | 5,662,720 | 39% |
| M10K | 360 | 553 | 65% |
| PLLs | 4 | 6 | 67% |

**Correction to the prior audit, carried forward:** IIR-passthrough (psx_patch 0025) *did* free its 8 DSP (`audio_out` = 0 DSP in this fit), but **gpu came in at 43 DSP, not the predicted 35**, so the net is still **112/112**. The DSP ceiling is *not* cleared by 0025 alone. Per-entity DSP in this fit: gpu 43 + ascal 25 + gte 15 + spu 13 + mdec 9 + cpu 6 = 111 (+1 misc). This matters only insofar as **HPS-side MP3 adds 0 DSP**, so the 100% wall is irrelevant to the DDR path.

**DDR fabric need (HPS-MP3):** DIO de-stub + DDR3 datapath + small MP3/PCM FIFOs ≈ **~1,000–1,500 ALM / 0 DSP**, on top of the ~198 ALM of DIO stubs already in this fitting build. (Flash-persistence `s573_flash_saver` = 154 ALM is already in-fit.)

**Recovery levers (the binding constraint is ALM/LAB routing, NOT DSP):**

| Lever | Frees ALM | Frees DSP | Risk | Note |
|---|---:|---:|---|---|
| #1 IIR passthrough | ~436 | 8 | LOW | **already applied** (banked) |
| #3 joypad_pad + lightgun strip | ~575 | 0 | MED | 573 is JVS, not PSX pads |
| #4 memcard2 strip | ~64 | 0 | MED | |
| #2 ascal bicubic-off | few-hundred | ~10–14 (speculative) | LOW–MED | only lever for DSP headroom if wanted |
| #5 savestate partial stub | ~300–630 | 0 | MED–HIGH | |

**ALM math:** #3 + #4 free ~640 ALM; add #2 or partial #5 to reach **~1,000–1,500 ALM** — covers the HPS-MP3 DDR datapath with margin. The current build at 94% ALM has *already* relieved the LAB-congestion wall that broke the earlier 97%/routing-fail build. **No GTE/MDEC removal required.**

**DSP math:** HPS-MP3 needs **0 DSP** → 112/112 does not block DDR. If safety headroom is wanted, #2 ascal-off is the only lever, keeping GTE/MDEC (and their risky disasm gates) off the critical path for the entire DDR/BEMANI family.

---

## 3. First target game + dumps

**First DDR target: `ddrsbm` — Dance Dance Revolution Solo Bass Mix (GQ894, VER. JAA).** It is the structurally simplest DIO/MP3 DDR title: DIO board + X76F100+DS2401 cassette + CD, and **no PCMCIA, no memory-card reader**. (One caveat: it sets `set_ddrsbm_fpga(true)` — a one-off FPGA-program variant that selects the `decrypt_ddrsbm` descrambler scheme, which our `k573_mp3dec.v` already implements but `k573dio.v` must honor via the `DDRSBM` param per-instance.)

**Note for the human:** the task brief names "DDR 3rd Mix," but **3rd Mix is *not* the cleanest** — it adds two whole subsystems over Solo Bass Mix: a 32 MB PCMCIA card (the game installs to it from CD) and the `k573mcr` memory-card reader (with its own `885a01.bin` TMPR3904 ROM). Recommend `ddrsbm` first, then **`ddr3mj` (3rd Mix JP)** as the immediate follow-on once PCMCIA + k573mcr are wired. 3rd Mix Plus (`ddr3mp`) is the hardest of the three (mixed ZS01+X76F041 cassette on top of PCMCIA + reader).

**Optional pre-DIO warm-up that needs no new RTL:** `ddr2m` (2nd Mix) — X76F041 + CD, **no DIO/MP3**, and **WORKING in MAME**. It proves the DDR program/chart/JAMMA-dance-pad path on hardware we already run (we boot hyperbbc/hypbbc2p, which are X76F041+CD), without touching the unbuilt MP3 decoder. It does *not* exercise the DIO/MP3 stack that is the point of this scope — it's a de-risking stepping stone only.

**Dumps inventory — we have ZERO DDR dumps today.** *Confirmed:* `mame -verifyroms` on dell for `ddr3mk/ddr3mj/ddr3ma/ddr3mp/ddrsbm/ddr2m/dstage/ddru` → all "romset not found!"; home-wide `find` for `ddr*.zip`/`887*.chd`/`894*.chd`/`a22*.chd`/redump archives → nothing on either Mac or dell. The README's `mame573/` DDR-cart list and `konami-system-573-redump.zip` are **stale/aspirational — those files do not physically exist.**

**Exactly what to source per candidate** (sizes/CRCs from MAME `-listxml`; all cassette files expected `BAD_DUMP`-flagged, which is normal for 573 and still works):

- **`ddrsbm` (recommended first):**
  - CD: disc `894jaa02` (CHD, sha1 d6872078…) — the only large file
  - Game cassette: `gq894ja.u1` (132 B = X76F100, crc 10b85f6b) + `gq894ja.u6` (8 B DS2401, crc ce84419e)
- **`ddr3mj` (3rd Mix JP, follow-on):**
  - CD: disc `887jaa02` (CHD, sha1 8736818f…)
  - Game cassette: `gn887ja.u1` (132 B X76F100) + `gn887ja.u6` (8 B DS2401)
  - Install cassette: `ge887ja.u1` (132 B X76F100) + `ge887ja.u6` (8 B DS2401)
- (3rd Mix Korea2 family-parent `ddr3mk`: discs `887kba02`, carts `gn887kb`/`ge887kb`. 3rd Mix Plus `ddr3mp`: disc `a22jaa02`, game `gca22ja.u1` 140 B=ZS01, install `gea22ja.u1` 548 B=X76F041.)

**Non-sourcing items (do not chase):** `hd6473644h.18e` is NO-DUMP for *every* 573 game and already proven tolerable; the DIO `digital-id.bin` (8-byte DS2401) is a MAME device-internal ROM our fabric supplies — `verifyroms` does not demand it.

---

## 4. Phased roadmap

Headline ordering: **A) bank the ALM recovery → B) de-stub DIO + DDR3 datapath → C) build the HPS MP3 path → D) bring up the game.** Phases A–C are board-light and dump-free; Phase D is dump-blocked and is where the MAME-oracle gap bites.

### Phase A — Resource recovery (bank the ALM headroom)
- **Do:** confirm the banked #1 IIR-passthrough in the current fit; apply #3 (joypad/lightgun strip) and #4 (memcard2). Hold #2 (ascal-off) and #5 (savestate stub) in reserve.
- **Resource math:** target ~640 ALM from #3+#4, reaching ~1,000–1,500 ALM with #2/partial-#5 if needed. DSP unchanged (HPS-MP3 = 0 DSP).
- **Riskiest unknown:** #3 strip assumes 573's JVS input path never touches PSX joypad_pad logic — verify no shared instantiation before cutting. #5 (savestate) is MED–HIGH and only if the ALM budget runs tight.

### Phase B — DIO de-stub + DDR3 board-DRAM datapath
- **Do:** un-dangle `lamp_out`/`dio_mp3_byte`/`dio_mp3_valid` (emu.sv:2147-49); wire the lamp lines into the JAMMA/sensor mux for the GN845 dance-pad protocol; replace the 4096-word sim M10K with a multi-MB f2sdram/DDR3 window; honor the `DDRSBM` FPGA-mode param per-instance.
- **Resource math:** ~few-hundred to ~1k ALM / 0 DSP; DDR3 capacity free (block-mem 39%).
- **Verification:** this is the phase MAME *can* partly oracle for boot/security/CD + board-detect (`0x80`→`0x1234`, `0xf6`→`0xB000`) and the lamp/dance-pad path. Frame-diff the boot/self-test against MAME for the non-audio layers.
- **Riskiest unknown:** the lamp→dance-pad multiplexor wiring (GN845 shift-register clk/DO) is subtle and currently fully disconnected at the top level. Get pad reads working *before* touching audio so DDR can at least boot and accept input.

### Phase C — HPS MP3 path (the linchpin)
- **Do:** MP3-byte→HPS transport (DDRAM ring / upload FIFO); HPS minimp3 service; PCM-in FIFO + SPU mixer; sample-counter feedback driven off PCM-FIFO drain.
- **Resource math:** ~350–700 ALM + 1 M10K + 0 DSP on the fabric side; the weight is HPS C effort (minimp3 is header-only; copy CD-DA scaffolding).
- **Riskiest unknowns (two):** (1) **no upstream MiSTer HPS→core PCM template** — this must be written; budget Main/HPS C accordingly. (2) **Sample-counter coherence** — the HPS round-trip adds latency; the `0xca/cc/ce` counters MUST track consumed PCM (FIFO drain), not bytes-sent, or DDR arrow timing drifts. This is the single most important correctness detail; spec it against MAME's `mp3_frame_counter`/DAC-counter semantics.
- **Verification gap:** MAME is `NOT_WORKING` for every DIO DDR set, so it is **not an audio/timing oracle here**. This phase's verdict needs real-HW capture (audio present + counter advancing + arrows in sync) plus a state-level check on the counter, not a frame-diff.

### Phase D — Game bring-up (`ddrsbm` first, dump-blocked)
- **Prereq:** the human sources the `ddrsbm` dumps (§3). **Nothing in Phase D can start until then.**
- **Do:** stage CHD `894jaa02` + cassette `gq894ja.u1`/`.u6`; bring up boot → security → CD → self-test → DIO MP3 playback → dance-pad input → in-sync gameplay. De-confounded HW capture each step (warm-reboot, `/proc/uptime` < 60 s, exactly one `load_core`).
- **Riskiest unknown:** with no MAME audio oracle, "DDR plays in sync" must be judged by a NUMBER — counter advancement vs music position, audio-present measurement, and arrow-timing state — never by eye. Establish that objective check *before* claiming the milestone.
- **Follow-on:** `ddr3mj` (3rd Mix JP) once PCMCIA (32 MB) + `k573mcr` memory-card reader are added (their own bring-up, not in this plan's critical path).

---

## 5. What the human must decide or source

**MUST SOURCE (hard blocker for Phase D — nothing else gates the work):**
1. **A DDR romset.** Recommend `ddrsbm` first: CHD `894jaa02` + `gq894ja.u1` (X76F100) + `gq894ja.u6` (DS2401). Then `ddr3mj` for the 3rd-Mix follow-on (adds install cassette `ge887ja.u1/.u6`). All cassette files expected `BAD_DUMP`-flagged — normal, still works. **We have zero DDR data today; the README's staged set is stale.**

**MUST DECIDE:**
2. **First target: `ddrsbm` vs the requested "3rd Mix."** Recommendation is `ddrsbm` (cleanest DIO config), 3rd Mix second. If the human specifically wants 3rd Mix first, budget the extra PCMCIA + k573mcr bring-up.
3. **Optional pre-DIO warm-up `ddr2m`?** It de-risks the DDR program/chart/dance-pad path on already-working RTL (no DIO), but needs its own dump and doesn't touch MP3. Worth it only if the dance-pad/JAMMA path is suspect.
4. **Accept the MAME-oracle gap for DDR audio.** Every DIO DDR set is `NOT_WORKING` in MAME → no frame-diff oracle for the MP3/timing path. Verification will rely on real-HW capture + counter state. Confirm that's acceptable, or decide whether to invest in a non-MAME reference (e.g. capturing the real PCM stream from a known-good source).

**NOTHING to reverse-engineer or provision:** descrambler keys come from the game over the bus; the descrambler is already built and faithful; the "undumpable MCU" is HLE'd and not on the DIO/audio path; security cassettes are all present in RTL.

---

## Citations

- Sub-scope 1 (MP3 + descrambler): MAME `k573fpga.cpp`, `k573dio.cpp`, `mas3507d.cpp`, `mp3_audio.cpp` (minimp3, `mp3dec_decode_frame`); RTL `k573_mp3dec.v`, `k573_mp3stream.v`, `k573dio.v`, `emu.sv:1513-14`/`:2148-49`, `s573_cdimg.v`; MiSTer `audio.cpp` (no PCM injection), `support/neogeo/neogeocd.cpp` (`user_io_file_tx_data` CD-DA pattern); psx-spx Konami System 573; Virtex-4/Virtex-II MP3-core literature (in-fabric order of magnitude).
- Sub-scope 2 (DIO de-stub + MCU): MAME `ksys573.cpp` (H8 desc lines 219/1257-1295/3703-3710 — dead `"mcu"` NO_DUMP + live `"h8_response"`; `gn845pwbb_*` dance-pad mux via lamps), `k573dio.cpp`, `k573fpga.cpp`, `mas3507d.cpp`; RTL `s573_io.v:76-89`, `k573dio.v`, `k573_mp3stream.v`, `emu.sv:2147-49`, seccart modules; `mame -verifyroms sys573` on dell.
- Sub-scope 3 (target + dumps): MAME `ksys573.cpp` + `k573cass.cpp` (mamedev/mame master, fetched on dell), `mame -listxml`/`-verifyroms` (0.285) on dell; `dumps/` (Mac) + `dell:~/System573_MiSTer/dumps/` inventories; `dumps/README.md`.
- Sub-scope 4 (resource): `dell:~/System573_MiSTer/output_files/Konami_System_573.fit.summary` + `.fit.rpt` (successful fit, HEAD `ca09f54`, 2026-06-12 09:27); `rtl/k573dio.v:35` (RAM_WORDS=4096), `k573_mp3stream.v:20` ("not modeled"), `emu.sv:2147-49`; `docs/EXECUTION_PLAN.md:170-180` (Phase 9 MP3 options).
- Prior audit: `docs/audits/2026-06-12-resource-recovery-scope.md` (levers, risk ranking, DSP 112/112, DIO = stubs).
- Re-verified at HEAD this pass: `emu.sv:2147-2149` dangle, `k573_mp3stream.v:20` "not modeled," `k573dio.v:35` RAM_WORDS=4096 sim-sized, prior resource-recovery audit present.
