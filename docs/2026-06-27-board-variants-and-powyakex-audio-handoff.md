# Handoff — 573 board variants (analog vs digital) + powyakex audio wobble

_Session 2026-06-27 (573). Branch `feat-digital-bringup`. This is a conversation/analysis
session — no code changed, no build, no HW capture. Two open questions raised by Human were
characterized against the actual RTL. Pick up from "Next steps" at the bottom._

---

## Question 1 — "Have we accounted for the main 573 board varieties (analog vs digital)?"

**Answer: partly. The doc-level map exists; the implementation only does the base-board audio
path. The digital-I/O (MP3) path is the real gap.**

The 573 is **base unit + one I/O daughterboard + a security variant** — and the *audio path
forks* depending on which daughterboard:

| Variant | Adds | Audio source | Our core today |
|---|---|---|---|
| **Base + security cassette + CD** (hyperbbc, hypbbc2p, **powyakex**) | nothing extra | PSX **SPU only** | working |
| **Analog I/O board** GX700-PWB(D) | ADC0834 analog inputs, lamps | SPU only | partial — `adc_ch0..3` hardwired `8'h00` (rtl/emu.sv ~line 2175); fine until a game reads an analog control |
| **Digital I/O board** GX894 / k573dio (entire DDR / GuitarFreaks / DrumMania family) | MAS3507D **MP3 decoder**, DRAM, network, DS2401 | SPU **+ MP3 stream** | **the gap** |

**The digital-I/O gap, concretely:** the register block (`rtl/k573dio.v`) and the descrambler
datapath (`rtl/k573_mp3dec.v`) both exist and pass sim (see `docs/ROADMAP.md` Phase 4), **but
the MP3 output is not wired into the audio mix at all** — `.dio_mp3_byte()` / `.dio_mp3_valid()`
dangle at rtl/emu.sv:2185. This is exactly the ddr-bringup track (HPS-side MP3 decode, not yet
built — see memory `ddr-bringup-plan` + `fabricore-573-digital-bringup`).

**Secondary honesty note (not the audio bug, but related):** the 573's own software audio
control is also unmodeled — `.audio_amp_en()`, `.audio_mute()`, `.spu_dac_en()` all dangle at
rtl/emu.sv:2179. A game that toggles the amp/mute could produce level pops; we'd never honor
it. Worth wiring when we touch the audio path.

**Bottom line for Human's worry:** the architecture docs (`docs/ARCHITECTURE.md`) *list* all
three variants, but at the implementation level only **base-board SPU audio is real**. Treating
"the 573" as one board is the trap — the digital family needs the whole MP3 transport built.

---

## Question 2 — "powyakex audio sounds like it slows down / speeds up a little"

**That's wow-and-flutter, a distinctive + real signal. powyakex is a base-board game → SPU
audio only (NOT MP3), which narrows the cause to three. The board-side quick test is BLOCKED
(see the SDRAM2 finding). Next move = MEASURE before any build.**

Context: powyakex now boots to attract via the dual-lane flash-ID fix
(`feat-flash-id-dual-lane`, commit c16559d — see `docs/2026-06-21-powyakex-flash-install-stall.md`).
So the audio is now audible enough to judge.

Audio path is the plain PSX SPU: `sound_out_left/right` -> `AUDIO_L/R` (rtl/emu.sv:1513). No
MP3 mix involved for this game.

### Three candidate causes (powyakex = SPU-only narrows it to these)
1. **SPU sound-RAM fetch contention <- lead hypothesis.** SPU reads its sample RAM through the
   shared memory arbiter. A baseball game streaming CD commentary/BGM + busy GPU starving SPU
   fetches -> exactly this wobble. Tell: wobble would *track* CD activity / on-screen load.
2. **Emulation-speed jitter** — frame pacing not locked / the marginal f2sdram bridge stalling
   the core unevenly (see memory `f2sdram-bridge-placement-marginal`). Tell: wobble is *steady,
   independent of load*.
3. **CD-streamed-audio delivery jitter** — bursty HPS sector delivery.

### ★ Key finding this session: the SPU-RAM mitigation knob is DEAD in this build
Human checked the OSD: **"SPU RAM select" (Video & Audio) is greyed out, stuck on DDR3.** Root
cause in RTL:

- The option is `"d1P1O[44],SPU RAM select,DDR3,SDRAM2;"` (rtl/emu.sv:476) — the `d1` prefix
  greys it out when menu-mask **bit 1** is off.
- Menu-mask bit 1 = `SDRAM2_EN` (rtl/emu.sv:557).
- **`wire SDRAM2_EN = 0;`** — hardwired off (rtl/emu.sv:2379). The `sdram sdram2` instance
  (rtl/emu.sv:2323) is tri-stated.
- Effect: `.SPUSDRAM(status[44] & SDRAM2_EN)` (rtl/emu.sv:1301) is forced 0 -> SPU sound RAM is
  **forced into DDR3**, the same bus as framebuffer + CPU + CD DMA. There is currently **no
  second SDRAM enabled to move it to**, hence the greyed toggle.

**Interpretation:** this doesn't disprove hypothesis #1 — it makes it *more plausible* (SPU is
stuck on the busiest bus with no alternative). But it **kills the cheap OSD A/B test** I'd
proposed (flip SPU RAM -> SDRAM2). Any contention fix is now build-level.

---

## Next steps (ranked — do NOT touch a build first)

1. **Confirm + characterize the wobble objectively (cheap, board-side, earns a number).**
   Per project doctrine (verify with a NUMBER, never the ear for a verdict): record powyakex
   audio off the board and run a **pitch-stability track on a sustained note**, AND check
   whether the wobble **correlates with CD activity / heavy on-screen action**.
   - Correlates with load -> DDR3 **contention** confirmed (hypothesis #1).
   - Steady regardless of load -> **frame-pacing / clock-ratio** (hypothesis #2).
   - Needs a small audio-pitch tool — it's on the AV-eval roadmap
     (`docs/AV_EVAL_TOOLING_SPEC.md`, memory `av-eval-tooling-priority`) but **never built**.
   - Compare against MAME audio for the same scene (MAME is the only oracle — no real-573
     ground truth; the persistent gap, memory `mame-reference-oracle`).
2. **If contention:** real fixes are build-level — (a) actually enable `SDRAM2_EN` so SPU RAM
   gets its own chip, **but first verify the de10 / SuperStation physically has the second
   SDRAM module wired** (unknown — don't count on it); or (b) give SPU fetches priority in the
   DDR3 arbiter.
3. **If frame-pacing:** chase the f2sdram bridge / vsync lock, not the SPU.

### Existing knobs worth noting (don't fix the wrong thing)
- `"h3P3O[43],RepTimingSPUDMA,Off,On;"` (rtl/emu.sv:508) — SPU DMA timing repro toggle (debug menu).
- `"P2O[72],Pause when CD slow,On,Off(U);"` (rtl/emu.sv:488) — relevant if CD delivery is the culprit.

## Don't-lose facts
- powyakex = base-board game, SPU-only audio. No MP3 path involved -> DDR/MP3 work is unrelated
  to this wobble.
- SPU RAM is forced into shared DDR3 in every current build (SDRAM2_EN hardwired 0).
- No audio-diff / pitch tool exists yet — building one is the gating task for an objective
  verdict here.
- No code changed this session. Branch `feat-digital-bringup` unchanged.
