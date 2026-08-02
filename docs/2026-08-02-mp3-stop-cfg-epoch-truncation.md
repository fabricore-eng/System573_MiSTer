# ddrsbm — "the music never stops" is an 8-bit epoch compared against a 16-bit one

**Date:** 2026-08-02 · **Board:** de10 · **Core build:** `Konami_System_573.rbf`
sha256 `9d96871d…` (the 2026-07-31 timing-closed build, deployed this session)
**Firmware:** Main fork `feat-s573-mp3` — instrumented `6f8fe0a`, fixed `3f52ed5`

## TL;DR

The reported bug — *music continues past a failed stage and across menu changes* — is a
**firmware-only** defect, and it is **not** "the enable-driven stop never fires". The enable
path works fine. What breaks is the test that decides whether to re-read the config at all:

> `s573mp3_poll()` re-reads the config when `r.cfg_epoch != c->cfg_epoch`.
> `r.cfg_epoch` is the **full 16-bit** counter riding the hot PTRS poll. But
> `apply_cfg` adopted `cfg.epoch`, and `CMD_573_MP3CFG` word 0 carries only
> **`cfg_epoch[7:0]`** *by design*. Below 256 the two agree by luck. Past 255 they can
> never be equal again.

Once that happens the branch re-fires on **every poll**: it re-applies a stale config, which
re-arms `DRAIN_EN` from that config's `stream_en`, and resets `in_len`/`in_pos`/`cons_bytes`
so decode cannot advance either. The game's stop is overwritten milliseconds later, forever.

## The experiment that was asked for, and its actual answer

One bounded capture (`S573MP3_HB=1`, `SECS=1500`, `MAXMB=48`), de-confounded: warm reboot,
`/proc/uptime` 23.8 s, exactly one `load_core`. Ran through attract **and** a real credited
stage driven headlessly to failure.

```
grep -c "DRAIN OFF via ENABLES"    -> 18
grep -c "DRAIN OFF via EXHAUSTION" -> 70533
```

The handoff's decision rule was *"zero via ENABLES → the enable-driven stop is dead"*. It is
**not zero**, so that inference does not apply. The enable path fires, and in the healthy
region it is the dominant stop cause. The 70,533 is not a real signal — it is the runaway.

## Root cause, proven with numbers

Parsing every `cfg=<adopted>/<fabric>` heartbeat in the capture:

| | value |
|---|---|
| heartbeats with `adopted == fabric` | 519 — max fabric epoch while equal: **247** |
| heartbeats diverged | 229 |
| diverged heartbeats satisfying `adopted == fabric % 256` | **229 / 229 (100.0 %)**, zero counterexamples |
| first divergence | the **first** heartbeat whose fabric epoch exceeded 255 (262) |
| max fabric epoch reached | 567 |

A clean 8-bit truncation, and the onset is exactly the 255 boundary — not a race, not a
timing window.

**The fabric is correct as designed.** This is not an RTL bug:

- `rtl/k573dio.v:161` — `output reg [15:0] cfg_epoch` — the counter is 16-bit.
- `rtl/s573_hps_ext.v:335` — `io_dout <= {8'd0, cfg_epoch[7:0]};` — MP3CFG word 0 is an
  **8-bit identity echo**, documented as such at `:127`.
- `rtl/s573_hps_ext.v:324` — `snap[2] <= cfg_epoch;` — the PTRS poll carries the full 16 bits,
  and `:67` says the epoch rides the hot poll *on purpose*.

The firmware simply adopted the echo instead of the value its own comparison tests.

## The fix (firmware-only — no Quartus rebuild)

`support/s573/s573mp3.cpp`, in the config-moved branch, adopt what the test compares:

```c
c->cfg_epoch = r.cfg_epoch;
```

plus a **loud** one-shot warning when the 8-bit echo disagrees with the low byte of the PTRS
epoch — that is a genuinely torn read, and it self-corrects on the next poll rather than being
silently swallowed. `s573_core_apply_cfg()` keeps its signature, so the 12 host-test groups are
untouched and still PASS.

## Verification on silicon

Second capture, same de-confounded protocol (fresh boot, uptime 16.9 s, one `load_core`),
`SECS=1800` so the run is guaranteed to cross the 255 boundary that triggers the bug.

| | before (`6f8fe0a`) | after (`3f52ed5`) |
|---|---|---|
| heartbeats `adopted == fabric` | 519 / 748 | **898 / 898** |
| diverged | 229 (all `== fabric % 256`) | **0** |
| max fabric epoch reached | 567 | 500 |
| `DRAIN OFF via ENABLES` | 18 | 36 |
| `DRAIN OFF via EXHAUSTION` | 70,533 | 9 |
| torn-cfg warnings | — | 0 |
| log size | 20.5 MB | 234 KB |

Zero divergence across 898 heartbeats up to epoch 500 — roughly twice the boundary that used
to break it — and the drain now stops predominantly via the enables, as it should.

## What this retires

- **The 846,906 `stream_en=0` adoptions are explained, and they never meant what they were
  used for.** That count is the *signature of this runaway*, not evidence that the firmware
  "sees stops". In the stuck state `apply_cfg` runs every poll, so adoptions accumulate at
  poll rate indefinitely. Any statistic gathered from a long board log **after** the epoch
  passed 255 is measuring this bug, not the thing it was pointed at.
- **The "long runs of 47 / 79 s vs MAME's ~23.5 s" observation** is consistent with the same
  cause: past the boundary nothing can stop a song except the window running out.
- **The leading hypothesis is refuted.** "The enable-driven stop never fires" was wrong; it
  fires, then gets overwritten. Worth keeping as a case where a plausible mechanism and the
  real one both predict the same user-visible symptom.

## Landmarks

- `support/s573/s573mp3.cpp` — the config-moved branch and the fix (Main fork).
- `support/s573/s573mp3_core.c:97` — `c->cfg_epoch = cfg->epoch;`, the original adoption.
- `rtl/s573_hps_ext.v:127`/`:335` — the 8-bit echo, by design.
- `rtl/s573_hps_ext.v:324`/`:67` — the authoritative 16-bit epoch on the hot poll.
- Board logs kept at `de10:/media/fat/s573_capture_3f52ed5.log` (post-fix).

## Still open

- The pre-existing `[HUMAN]` item: cold boot **intermittently hangs at `DATA LOADING … No.30`**.
  Not seen this session (two cold boots, both reached attract).
- Savestates remain advertised (`emu.sv:804`) but cannot work on this core — unchanged.
- The gain path: `gain_seen` should now read 1 with this `.rbf`; not separately confirmed here
  because the stop bug was the whole budget of the session.
