# ddrsbm — the previous song bleeding into the next one: two ring-pointer bugs

**Date:** 2026-08-02 · **Board:** de10 · **Firmware:** Main fork `feat-s573-mp3` →
`2833cc1` + `679bcb0` · **Bitstream:** unchanged (`9d96871d…`) — both fixes are firmware-only

## The report

After the `cfg_epoch` fix (`3f52ed5`) made the game's stop actually take effect, play testing
surfaced a second symptom: *"the audio stops when it's supposed to, but the next time audio
plays it plays a second or so of the last song before playing the track it's supposed to."*

That was two separate defects, not one.

## Bug 1 — we masked ourselves out of the fabric's emptiness test

`s573_core_wrote_pcm()` masked `pcm_wr` to 15 bits and `s573_core_pcm_free()` masked the
difference. But the ring compares the **full 16 bits including the wrap MSB**:

- `rtl/s573_pcm_ring.v:54-55` — `hps_wr_ptr` / `fab_rd_ptr` are both `[BEATS_LOG2:0]`
- `rtl/s573_pcm_ring.v:83` — `have_data = (hps_wr_ptr != fab_rd_ptr)`
- `rtl/s573_pcm_ring.v:43-47` — documents the convention *and* guards elaboration against
  truncating that bit; `rtl/s573_hps_ext.v:46-49` says the same

So `hps_wr_ptr[15]` was permanently 0 while `fab_rd_ptr[15]` toggles every 32768 beats. **For
half of every lap the two could never compare equal**: the reader saw data in a physically
empty ring, lapped it, and replayed up to 1.486 s of already-drained PCM — with `underrun_cnt`
reading a clean 0 the whole time. It also made the exhaustion backstop's `pcm_wr == pcm_rd`
test unsatisfiable half the time.

This needed no stop to trigger. **The audio path had never been correct for half of every
~3 s lap**, which means the earlier "MP3 audio works on silicon" verdict was measuring a path
with a live defect in it.

The ring TB (`sim/tb_s573_pcm_ring.v:33,:103`) drives 16 bits correctly. The firmware was the
only side masking — a firmware defect against a written fabric contract.

**A companion change is mandatory, not cosmetic.** `pcm_write()` turns `pcm_wr` into a byte
offset. Widening the pointer without masking there makes `S573_PCM_BYTES - byte_off` underflow
and the `memcpy` run off the end of the 256 KiB mapping. The widening and that mask must land
together.

## Bug 2 — the known `reset_playback` gap

A stop **freezes** the ring rather than draining it (`rtl/s573_mp3_pcm.v` gates `pcm_ce` on
`drain_en`; the ring reader has no `drain_en` port at all), so ~1.49 s of the old song survives
and drains first on the next play. MAME's `update_mp3_decode_state()` calls
`mas3507d->reset_playback()`, which discards decoded PCM too. We never did — written down at
`docs/2026-07-31-mp3-audio-WORKING.md:94-97` and never implemented.

It stayed invisible because nothing ever stopped, so nothing was ever left buffered. Fixing the
stop exposed it.

**Gated on the re-arm, NOT on the enable edge.** `cfg_epoch` also moves on `fpga_ctrl[14:13]`,
and on a bare pause/resume the buffered PCM is exactly the audio the resume continues with —
dropping it would fast-forward the song by up to 1.49 s, the mirror image of the rewind bug.
MAME draws the line in the same place: `set_fpga_ctrl`'s `reset_playback()` never touches
`mp3_cur_addr` or the keys, while `update_mp3_decode_state()` does both.

## The correction that only measurement caught

The first implementation deferred the flush until a poll where the drain was off and
`fab_rd_ptr` had parked. It measured **INERT** — zero flushes across a full attract cycle while
music was demonstrably playing.

ddrsbm delivers a new song as **one** adoption carrying the new window *and* `stream_en=1`
together (epoch N `flags=000f` with a fresh start/end, after a bare stop at N−1 `flags=000b`).
So `rearmed` fires on the same poll the drain goes back ON, and the deferred path cancelled the
intent every time.

The gate is the drain state **before** the adoption. When `drain_before == 0` the deferral was
also unnecessary: the fabric reader parked at the stop seconds ago, against the ~240 µs it
needs to back up on `wr_full`. The `drain_before == 1` case still defers and now logs that it
did, rather than failing silently.

*Worth keeping:* the deferral's reasoning was internally sound and still wrong, because it
assumed an adoption ordering this game never uses. Only running it produced that.

## Verified on silicon

De-confounded (fresh boot 30 s, `/proc/uptime` checked, exactly one `load_core` at 49 s),
bounded capture `HB=1 SECS=1500 MAXMB=48`:

| measurement | result |
|---|---|
| PCM FLUSH events | **26**, one per song change |
| beats dropped per flush | 32,064 – 32,548 |
| seconds dropped per flush | **1.454 – 1.476 s** |
| total stale audio removed | **38.1 s** across 26 song changes |
| `wr == rd+1` after collapse | **26 / 26** |
| write pointers above 32767 | **11** (max 58,998) — impossible under the old 15-bit mask |
| deferred flushes | 0 (the `drain_before==1` case never occurs on ddrsbm) |
| epoch heartbeats diverged | **0 / 747** (max epoch 400) — `3f52ed5` still holds |
| torn cfg-read warnings | 0 |
| DRAIN OFF via ENABLES / EXHAUSTION | 26 / 9 |
| log size | 206 KB (no runaway) |

The per-flush figure lands exactly on the predicted ring depth: 32768 beats × 2 stereo frames
÷ 44100 Hz = 1.486 s.

## Host tests, and a gap the mutation check found

12 groups PASS, and each half was **mutation-verified RED**:

- restoring the `wrote_pcm` mask → T8 fails
- restoring the `pcm_free` mask → *initially still passed*. That half was untested. A new
  discriminator was added — a ring exactly one lap ahead must read **FULL, not empty**, which
  is the case the old mask got catastrophically wrong (it would have allowed overwriting 32,767
  undrained beats) — and the mutation then fails as it should
- forcing `apply_cfg` to return 0 → the new flush-gate check fails

The lesson is the middle one: a suite that passes both before and after a fix is not evidence.

## Landmarks

- `support/s573/s573mp3_core.c` — `s573_core_pcm_free`, `s573_core_wrote_pcm` (the wrap bit)
- `support/s573/s573mp3.cpp` — `pcm_ring_collapse`, the arm site, the mandatory mask in
  `pcm_write`
- `rtl/s573_pcm_ring.v:43-47,:54-55,:83` — the fabric contract we were violating
- Board log kept at `de10:/media/fat/s573_flush_679bcb0.log`

## Still open

- **Song-select inputs.** A Solo cabinet drives the song wheel from *Select L / Select R* on
  IN3 (`0x1f40000c`/`0x1f40000e` bit 9), a different register from the dance panels on IN2.
  Both are hardwired to `1'b1` (never pressed) at `rtl/s573_io.v:140,:143`, so the song-wheel
  buttons do not exist in our RTL and only START can move menus. The six Solo panels are also
  split across `p1_ctrl`/`p2_ctrl`, making Up-Right reachable only from controller 2. **Needs a
  Quartus rebuild** — see the separate design write-up.
- Cold boot intermittently hangs at `DATA LOADING … No.30` (pre-existing; not seen across four
  cold boots this session).
- Savestates remain advertised but cannot work on this core.
