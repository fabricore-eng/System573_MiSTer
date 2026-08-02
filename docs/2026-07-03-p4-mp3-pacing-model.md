# P4 — the MAS3507D MP3 pacing + counter model (MAME 0.285 ground truth) — 2026-07-03

Observe-first grounding for P4 (MP3 audio), the blocker that leaves ddrsbm song
gameplay looping on the stage `ready` screen after gate 5 cleared the `-1N` CD wedge.
Source of truth: MAME 0.285 (matches the binary on dell), files
`src/mame/konami/k573fpga.cpp` / `k573dio.cpp` and `src/devices/sound/mas3507d.cpp`.
Memory: `[[ddr-bringup-plan]]` (P4), `[[573-audio-and-board-variants]]`,
`[[fabricore-573-digital-bringup]]`.

## The one sentence

The MP3 byte stream is **demand-paced** (back-pressure from the decoder's input
FIFO), and the gameplay clock the game reads to advance the chart is a **decode
counter** (elapsed playback samples and decoded-frame count) — *never* a
bytes-sent proxy. Today our streamer floods (no back-pressure → drains a song in
~0.3 s) and every counter register reads 0, so the game can't sync → loops on
`ready`.

## How pacing actually works (MAME)

The FPGA does not free-run and does not throttle to a fixed rate. It is gated by the
MAS3507D's **DEMAND** line, which reflects the decoder's input-buffer fill:

- `mas3507d`'s input FIFO `mp3data` is **0xe00 = 3584 bytes**. `sid_w(byte)` pushes
  one byte and raises `cb_demand(mp3data_count < 3584)` — **demand high ⇔ FIFO not
  full**.
- `k573fpga::mas3507d_demand(state)`: on demand-high it re-arms the stream timer
  (`adjust(zero)` → fire ASAP); on demand-low it parks it (`adjust(never)`).
- `k573fpga::update_stream()` (the timer callback) feeds **exactly one byte** per
  call via `sid_w`, and only if `PLAYBACK_STATE_DEMAND` is set AND
  `FPGA_MP3_ENABLE(13)` AND `FPGA_STREAMING_ENABLE(14)` AND
  `cur ∈ [cur_start, cur_end)`. Reads a word from RAM only when `remaining==0`,
  decrypts (default or ddrsbm), byte-swaps, emits **high byte then low byte**,
  `cur += 2`.
- The FIFO drains in `fill_buffer()`, called from `sound_stream_update` at the
  **44100 Hz** stream rate: each call decodes one MPEG frame (≤1152 samples),
  consuming `pos` input bytes, then re-raises demand.

Net: the decoder pulls bytes at exactly the rate it turns them into 44100 Hz PCM ⇒
average byte rate = the MP3 bitrate/8 ≈ **16 KB/s (128 kbps) … 40 KB/s (320 kbps)**,
delivered in bursty fills (top up to 3584, wait, top up again). **The rate is an
emergent property of consumption, not a number in the streamer.** This is the
faithful, no-mask model: pace to the sink, don't invent a clock.

**Two exact-fidelity details (caught by the P4a RTL review, both matched):**
- **Byte count = 2N−1 for an N-word window.** `update_stream()` checks the window
  (`cur >= end`) BEFORE feeding the buffered low byte, so after the final word's
  read advances `cur` to `end`, the next tick early-returns and the last word's LOW
  byte is never fed. So MAME feeds **2N−1** bytes, not 2N. (Immaterial to decode —
  MP3 is self-framing and the clock is decode-driven — but matched for oracle
  byte-fidelity; real CR-589/DIO-FPGA boundary behavior is unconfirmed → P4c.)
- **Enable bits only GATE; they never re-init.** `set_fpga_ctrl` only
  `reset_playback()`s the decoder FIFO on a bit13/14 change — it never touches
  `mp3_cur_addr` or the key schedule. `cur`/keys reset ONLY via
  `update_mp3_decode_state` (a start/end/key write). So a stream STARTS from `cur`
  when enabled (after a setup write seeded it) and a bit13/14 pause RESUMES in place
  — it does **not** rewind to the top of the window.

## How the gameplay clock works (MAME) — the actual `ready`-loop unblock

Registers (byte offsets in the 0x1f640000 window; `k573dio.cpp` amap):

| off | R | W |
|-----|---|---|
| 0xa8 | `get_mp3_frame_count()` = `mp3_frame_counter & 0xffff` (decoded-frame count) | crypto key1 |
| 0xaa | `get_mpeg_ctrl()` = `mpeg_status` (bit12 DEMAND, 13 IDLE, 14 PLAYING, 15 ENABLED) | — |
| 0xae | `get_fpga_ctrl()` = streaming status `<<12` (bit12; needs `fpga_ctrl[14]` + in-window) | fpga_ctrl latch |
| 0xca | `mp3_counter_high_r` = **latched** `fpga_counter >> 16` | — |
| 0xcc | `mp3_counter_low_r` = **latches** `fpga_counter = get_counter()`, returns `&0xffff` | `reset_counter()` |
| 0xce | `mp3_counter_diff_r` = `get_counter_diff() & 0xffff` | — |

- `mpeg_frame_sync(1)` fires **once per successfully decoded MPEG frame** (from
  `fill_buffer`); when `FPGA_FRAME_COUNTER_ENABLE(15)` is set it does
  `mp3_frame_counter++`. Clearing bit15 resets the frame counter to 0.
- `get_counter()` = `counter_value * 44100`. `counter_value` is **elapsed playback
  time in seconds** since the first frame-sync (default games) or free-running since
  decode-state reset (ddrsbm). So the counter is the **PCM sample position**
  (44100/s) — i.e. driven by decode/PCM-drain progress.
- **Read order matters:** the game reads **0xcc first** (this *latches* the full
  32-bit counter and returns the low word) then **0xca** (returns the high word of
  that same latch). An RTL counter must replicate the latch-on-low-read so hi/lo are
  coherent.
- **ddrsbm** specifically syncs its internal playback timer to the counter/frame
  count (see `update_counter` ddrsbm branch) — this is exactly the register the
  looping stage `ready` screen is waiting on.

`update_mp3_decode_state()` (MAME) resets on **any** write to start/end/key1/2/3:
`cur = start`, re-seed keys, `frame_counter = 0`, `reset_counter()`,
`mas3507d->reset_playback()` (the comment flags the exact FPGA update timing as
unknown — a documented HACK). This is the model for our streamer's re-arm /
"mp3_end extension after park" behavior.

## Delta vs. our core (we decode HPS-side, there is no MAS3507D chip)

Per `[[ddr-bringup-plan]]` P4: in-fabric MP3 decode is rejected (ALM/DSP); decode is
HPS-side (minimp3, the same decoder MAME uses). So each MAME concept maps to a
transport boundary we must build:

| MAME concept | our core equivalent |
|--------------|---------------------|
| MAS3507D DEMAND (FIFO not-full) | back-pressure from the HPS-side byte-FIFO into `k573_mp3stream` (`out_ready`) |
| `sid_w` byte push | `mp3_out_byte`/`mp3_out_valid` accepted under `out_ready` |
| `mpeg_frame_sync` pulse | HPS "decoded one frame" pulse → frame counter |
| `get_counter` = elapsed·44100 | PCM-drain sample position (44100/s) → 0xca/cc latch |
| `mas3507d` PCM out | HPS minimp3 PCM → mixed into AUDIO_L/R |

**The single biggest correctness risk (from the plan): the 0xca/cc counter MUST be
driven off PCM-FIFO DRAIN, not bytes-sent** — else arrow-sync drifts (VBR + bytes≠
samples).

## P4 slices (this doc grounds all of them)

- **(a) DONE — demand-pace `k573_mp3stream`.** Added `out_ready` back-pressure:
  emit/advance only on an accepted byte; hold the byte stable while `!out_ready`. No
  rate number in the RTL — the sink sets the pace. Re-arm is a `reload` pulse
  (k573dio, on any start/end/key write) → `cur=start`, re-seed keys — the ONLY
  re-init path; the enable bits merely gate/resume (fixes both the ignored-`mp3_end`
  extension and the pre-fix enable-edge rewind). Matches MAME's 2N−1 last-byte drop.
  byte_counter stays a data-position proxy, NOT the sample counter. RED/GREEN in
  `tb_k573_mp3stream` via `MP3_UNPACED`; suite 38/38; `mp3_out_ready` plumbed
  k573dio → system573_top → emu.sv (tied `1'b0` = honest halt until P4b). A 5-lane
  adversarial review vs the MAME source drove the 2N−1 + enable-gate corrections.
- **(b1) DONE — RTL decode-counter slice** (commit `cde2c6b`, sim-only). Added to
  `rtl/k573dio.v` the registers the game polls: 0xa8 frame counter (++ per
  `dec_frame_sync`, gated by `fpga_ctrl[15]`, reset on bit15-clear + `mp3_reload`),
  0xca/cc sample counter = `get_counter` = PCM sample position **driven off
  `pcm_sample_tick` (PCM drain), never bytes-sent** — with latch-on-0xcc-read (0xca =
  latched high; hi/lo coherent vs the EXP1 registered-slave read timing), 0xaa
  mpeg_status ({ENABLED=0, PLAYING, IDLE, DEMAND=`mp3_out_ready`}), 0xce diff
  (games-unused, best-effort). Wired `mas3507d_i2c.frame_count` to the real counter.
  Three new decode-driver inputs (`dec_frame_sync`/`dec_frame_idle`/`pcm_sample_tick`)
  plumbed k573dio → system573_top → emu.sv, **tied 0** (honest halt until b2) → every
  counter reads a truthful zero. RED/GREEN via `make MP3_COUNTER_STUB=1 k573dio`;
  suite 38/38; a 5-lane adversarial review vs the MAME source came back clean (1
  candidate, refuted). *The counters are correct but INERT until b2 drives the
  inputs — this does NOT yet advance gameplay.*
- **(b2) HPS decode chain + transport** (the remaining, off-fabric work). Transport
  `mp3_out_byte`/`valid` → HPS ring (mirror `s573_cdimg` CD-DA scaffolding); HPS
  minimp3 decode service in Main/ARM; PCM back over f2sdram/DDR3 mixed into
  `AUDIO_L/R`; then DRIVE the b1 inputs from real decode: `out_ready` = HPS byte-FIFO
  not-full (replaces the `emu.sv` `1'b0` tie), `dec_frame_sync` per decoded frame,
  `pcm_sample_tick` per drained PCM sample; drive `cfg_ddrsbm` per-game (tied 0 today
  in `emu.sv`). No sim oracle for this half → verify on silicon (slice c).
- **(c) Silicon verify.** A started ddrsbm song PROGRESSES past `ready` with audio;
  verify the sample counter STATE numerically (advances 44100/s, tracks PCM drain) +
  audio/arrow sync from HW capture (no MAME timing oracle — HW-only). Full
  regressions (install-golden `.sav` == 82243fe3, powyakex, hyperbbc).

## Caveats

- No MAME **timing/audio** oracle for the MP3 path (every DIO/MP3 DDR set is
  `MACHINE_NOT_WORKING`); MAME is an oracle for register/key/decrypt LOGIC only.
  Silicon state (counter advance, audio) is the operative evidence for (b)/(c).
- (a) alone does NOT make gameplay progress — the counter+decode chain (b) is the
  actual `ready` unblock. (a) is the faithful foundation + defines the (b) interface.
