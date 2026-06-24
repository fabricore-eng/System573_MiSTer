# System 573 — I/O-board coverage audit (2026-06-23)

_Subject: do BOTH 573 I/O daughterboards work on the core, or only one? A core that implements
one board but not the other runs that board's games fine yet produces wrong/no behavior for the
other's — even with 100% correct ROM/CHD data. Produced by a 5-agent static audit (RTL + the
MAME 0.288 oracle, `konami/ksys573.cpp`). No game was run; this is the "what is INSTANTIATED"
pass + the test plan._

## TL;DR

Coverage is **lopsided**. Both daughterboards have *some* RTL, but only the analog board's
**digital** paths are HW-proven (via hyperbbc/hypbbc2p). The analog **input** axis and the
**entire digital board** are unverified-to-nonfunctional:

- **Analog input is dead by construction** — the ADC0834 is faithfully modeled but its 4
  channels are tied to `0x00` (`emu.sv:2183-2186`) **and** none of the analog daughterboard
  windows are decoded (`0x1f640000` is hardwired to `k573dio` only). Every wheel/reel/gun/force
  game would read a dead axis with correct ROM/CHD. Hasn't bitten yet only because the HW-proven
  games don't use analog input.
- **The digital board's outputs dangle** — descrambler + stream FSM are sim-perfect, but
  `lamp_out`/`dio_mp3_byte`/`dio_mp3_valid` terminate in a void at `emu.sv:2193-2195`, there is
  **no MAS3507D MP3 decoder**, and the sample counter (`0xca/cc/ce`) reads `0`. A DDR-family game
  can't produce audio, timing, *or* pad input today.
- **ZS01 security is sim-only** — its decrypt/CRC packet engine is inside `synthesis
  translate_off` (`rtl/zs01.v`), so on real silicon it does not exist. Every ZS01 title
  (GuitarFreaks 3m+, DDR 3m+, DanceManiax) would fail security on the de10.

## Coverage matrix

| Subsystem | RTL | HW-proven | Gap |
|---|---|---|---|
| Analog: motherboard ADC0834 | modeled (`adc0834.v`, `system573_top.v:167`) | probed only | **channels tied `0x00`** (`emu.sv:2183`) — no host axis reaches a game |
| Analog: ADC0838 (force sensors) | module exists, **never instantiated** | no | unwired + motor/pad physics model absent |
| Analog: gx700pwbf window (DDR/GF/DM 1st-mix, pnchmn) | **absent** | no | `0x1f640000` routes only to `k573dio` |
| Analog: ge765pwbba reel (uPD4701A) | **absent** | no | quadrature-encoder model missing |
| Analog: gunmania I/O (gun X/Y + sensors) | **absent** | no | whole `0x1f640000` register file absent |
| Digital: `k573dio` glue + board DS2401 + DRAM window | instantiated (`system573_top.v:288`) | no | board-detect (`0x1234`) passes, but… |
| Digital: MP3 descrambler + stream FSM | sim-PASS (`k573_mp3dec.v`, `k573_mp3stream.v`) | no | …streams into a void |
| Digital: **MAS3507D MP3 decoder** | **absent** | no | **no decoder → no audio** (needs an HPS minimp3 path) |
| Digital: lamp + MP3 outputs | decoded | no | **dangle `emu.sv:2193-2195`** → no audio *and no dance-pad* (pad mux is clocked by the lamp bus) |
| Digital: sample counter `0xca/cc/ce` | absent | no | reads `0` → arrows never sync to music |
| Digital: board DRAM | 4096-word sim M10K | no | too small for a multi-MB MP3 image (needs f2sdram/DDR3) |
| Digital: MAS3507D I2C (`0xac`), FPGA firmware (`0xf8`), network | stubs | no | config-only stubs; risk if a game spins on an I2C ACK |
| Security: **X76F100** | full (`x76f100.v`) | **PROVEN** (hypbbc2p, 2026-06-12) | — |
| Security: X76F041 | full (`x76f041.v`) | no | sim/boot-probe only, no in-game HW PASS |
| Security: **ZS01** | **packet engine `translate_off` (SIM-ONLY)** | no | **doesn't synthesize** → fails on silicon |
| Security: DS2401 | full (`ds2401.v`) | indirect | cassette-side DS2401 path unproven (hypbbc2p has no cassette DS2401) |
| k573mcr / k573kara / k573msu | **absent** | no | niche (Link-Kit / karaoke / late drmn) — out of scope |

## Corrections to the original brief (these change the test plan)

- **`ddra`, `gtrfrk2m`, `drmn`(1st) are ANALOG-board titles, not digital** (`k573a` + gx700pwbf).
  The first *true* digital DDR is `ddr3m`/`ddrsbm`; digital GuitarFreaks is `gtrfrk3m+`/`gtrfrk5m`.
- **`hndlchmp`/`strgchmp` use NO expansion board** (`konami573n`, motherboard only) — a poor
  analog-board probe.
- **Fishing games use a `uPD4701A` quadrature encoder, not the ADC bank** — a distinct missing
  peripheral on the ge765pwbba board.
- **hyperbbc/hypbbc2p/konam80 are digital-input only** — the zeroed ADC channels are harmless for
  them (which is exactly why they pass).
- There are **three+ distinct boards at `0x1f640000`** (gx700pwbf analog, ge765 reel, gunmania,
  k573kara karaoke, plus k573dio digital) — the core decodes that window to `k573dio` only.

## Proof status (6/11 on HW, all analog-side)

PROVEN on HW: operator-menu, hyperbbc-attract, cd-read, cassette-auth, cd-install, game2-boot.
PROVEN-in-sim: ram4mb. PENDING: nvram-persist (no power-cycle PASS), audio-match (qualitative
only), **dio-mp3-first (DIGITAL — nothing)**, crt-capture (no real PCB). **Every digital-board
goal is pending.** `dio-mp3-first` is the single open BOARD-COVERAGE goal.

## Recommended isolation test pair (minimal confounders)

- **Analog:** `fbaitbc` (Fisherman's Bait, GE765) — base motherboard + one uPD4701 reel +
  X76F041-only, no PCMCIA/memcard/DS2401. Only one small missing model (the encoder). Expected
  current behavior: boots but reel input dead.
- **Digital:** `ddrsbm` (DDR Solo Bass Mix, GQ894) — simplest DIO config (X76F100+DS2401, no
  PCMCIA), and the security chips it needs are already implemented + proven. Expected current
  behavior: security/boot may pass; MP3 silent/glitched, no dance-pad.

Run as a matched pair so any failure attributes to the I/O board, not ROM/CHD/security. Dumps:
the full ksys573 set (both classes) is staged on the NAS (`/mnt/nas/dumps/arcade/ksys573/`,
MAME 0.288) — so the audit's "zero DDR dumps" blocker is resolved; they just need pulling into the
de10 pipeline.

## NEXT MILESTONE — digital-board boot-layer bring-up

The single highest-value next step is **not** a full game run (the MP3/timing layer has no MAME
oracle and needs an unbuilt HPS decode path). It is the smallest move that makes the digital board
**observable on silicon** and separates the boot work from the MP3 work:

1. **Un-dangle** `emu.sv:2193-2195` (`lamp_out`, `dio_mp3_byte`, `dio_mp3_valid`) — for the boot
   layer, route `lamp_out` toward the JAMMA/dance-pad mux; park the MP3 stream outputs cleanly
   (no decoder yet). DEBUG probes gated OFF per CLAUDE.md.
2. **Stage `ddrsbm`** from the NAS: `gq894ja.u1` (X76F100, ioctl 4) + `gq894ja.u6` (DS2401,
   ioctl 5) + the `894jaa02` CHD; author a `.mgl` (+ pack if needed). Gate −1: MAME 0.288
   `-verifyroms ddrsbm` first.
3. **Honor the per-instance `DDRSBM` param** in `k573dio` (ddrsbm sets `set_ddrsbm_fpga(true)` →
   `decrypt_ddrsbm`; `k573_mp3dec` has it, the top instance must select it).
4. **Boot ddrsbm to the board-detect/boot/security/CD layer** on the de10 and MAME-oracle those
   layers (board id `0x80→0x1234`, status `0xf6→0xB000`, X76F100+DS2401 auth, CD read). Expected
   divergence at the MP3/audio/pad layer — that is the *following* milestone, not this one.

CAVEAT: `ddrsbm` is `MACHINE_NOT_WORKING` in MAME 0.288 (audio), so the MP3/timing layer has **no
frame/audio-diff oracle** — it must later be judged by NUMBER (counter advance vs music position +
audio-present), never by eye. The boot/security/CD layers *are* partly oracle-able.

The bigger digital datapath (MAS3507D decoder via HPS minimp3, PCM FIFO + SPU mixer, the
`0xca/cc/ce` counter driven off consumed PCM, DRAM→DDR3 widening, lamp→GN845 pad mux) is scoped in
`docs/audits/2026-06-12-ddr-feasibility.md` and is the milestone *after* boot-layer.

## Key references

- Analog source stub: `rtl/emu.sv:2183-2186`. DIO dangling outputs: `rtl/emu.sv:2193-2195`.
- `0x1f640000` window → k573dio only: `rtl/s573_bus.v:44`, `rtl/system573_top.v:288-296`.
- ZS01 `translate_off`: `rtl/zs01.v` (packet engine ~lines 324-379).
- Proof goals: `../tools/registry/proofgoals.json` (id `dio-mp3-first`, PENDING).
- DDR datapath scope: `docs/audits/2026-06-12-ddr-feasibility.md`.
- MAME oracle: `konami/ksys573.cpp` (per-machine I/O-board configs: `k573a`/`k573d`/`fbaitbc`/`konami573n`).
