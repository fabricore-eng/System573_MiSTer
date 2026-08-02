# MP3 AUDIO WORKS ON SILICON — first time (2026-07-31)

ddrsbm plays its MP3 music on the de10. **RMS −11.4 dB, peak +1.17 dBFS**, sustained, on a
fully de-confounded boot (devlock reboot → stock init → one `load_core`) with the clean
probe-free binary `0c5d306b`. The human confirmed it by ear. Against the SPU-only baseline
of **−30.7 dB** measured earlier the same session, that is **~19–21 dB** of new signal.

Supersedes `docs/2026-07-31-mp3-audio-verdict-negative.md`, which was correct about the
measurement and wrong about the cause.

## Root cause: the service was gated behind a test that could never be true

`s573mp3_poll()` opens with `if (!is_573()) return;`. `is_573()` (Main `user_io.cpp:288`)
tested:

```c
is_573_type = strncasecmp(orig_name, "Konami_System_573", 17) ? 2 : 1;
```

`orig_name` is **CONF_STR field 0**, not the `.rbf` filename — and the 573 core is a PSX
derivative whose CONF_STR still begins `"PSX;SS3E000000:400000;"`. So `orig_name` is
`"PSX"`, the comparison never matched, and the MP3 service **never ran a single poll** since
the day it was written. Confirmed at runtime before the fix:

```
s573mp3: poll reached -- is_573=0 core_name='PSX'       orig_name='PSX'   <- bare .rbf
s573mp3: poll reached -- is_573=1 core_name='System573' orig_name='PSX'   <- after the fix, via .mgl
```

The fix also accepts `core_name` `"System573"`, which comes from the `.mgl` `<setname>` /
`.mra` override and *is* 573-specific. The `orig_name` arm stays so a future CONF_STR rename
keeps working.

**Why no test caught it:** the HPS host tests (10 groups) exercise `s573mp3_core.c`. The gate
lives in `user_io.cpp`, outside that seam — the classic untested boundary between a
well-tested unit and its caller. The unit was perfect and never invoked.

## The thing that cost the most time: `stdout` is `/dev/null` by default

Three rebuild cycles were spent believing the service "never started", because *nothing*
printed — not the service, not a one-shot probe on the first line of `s573mp3_poll()`, not
even one on the first line of `user_io_poll()`. All three strings were verifiably in the
binary.

`cfg.cpp` reassigns the **global `stdout`** while parsing the INI and then restores it as:

```c
stdout = (cfg.debug == 2) ? debug_file : cfg.debug ? orig_stdout : dev_null;   // cfg.cpp:442
```

With no `debug=` key in `MiSTer.ini`, `stdout` stays `/dev/null` for the entire run. Every
`printf` after INI parsing is discarded — which is exactly why the log ended at `ttyS1: 0`
every time. **Set `debug=1` under `[MiSTer]` in `/media/fat/MiSTer.ini` before believing any
absence of output from Main.** An empty log is not evidence.

Capturing Main's output at all: it is started from `/etc/inittab` as `::sysinit:` — run-once,
**not** respawn — so killing it leaves nothing racing you and you can relaunch it yourself with
redirection. Use `stdbuf -oL -eL`: with `stdout` on a plain file glibc block-buffers it, which
silently swallowed the first capture attempt too (only unbuffered `stderr` got through). A
power-cycle restores the stock arrangement. Recipe: `local/tracedig/mister_main_logcapture.sh`.

## What the heartbeat showed once it was visible

New opt-in diagnostic `S573MP3_HB=1`, at the ddrsbm mode-select screen:

```
s573mp3: rst=4/4 ack=1 cfg=21/21 have=1 | in_len=4096 pos=418 cons=12121  | frames=1873 sync=81  idle=25  | wr=30272 rd=63589 free=548 | ctrl=0002 echo_bad=0
s573mp3: rst=4/4 ack=1 cfg=40/40 have=1 | in_len=4096 pos=418 cons=509075 | frames=4630 sync=22  idle=111 | wr=12672 rd=13127 free=454 | ctrl=0002 echo_bad=0
```

Every half of the transport reads healthy, and each field retires a specific doubt:

- `rst=4/4 ack=1` — the **SPI mailbox round-trips**. This also *proves the deployed rbf really
  contains `s573_hps_ext`*, which had only been inferred from file timestamps. The provenance
  risk flagged in the negative-verdict doc is closed: no rebuild was needed.
- `cfg=21/21 → 40/40, have=1` — the fabric publishes a per-song config and we adopt it; the
  epoch advancing across songs means reload works.
- `in_len=4096, cons` climbing 12k → 509k — we are fetching the game's scrambled window.
- `frames` 1873 → 4630 — minimp3 is decoding continuously.
- `wr`/`rd` both advancing with `free` down to 43 — **the fabric is draining what we write**.
  A full-but-static ring would have meant the fabric side was dead.
- `ctrl=0002` — drain enabled; `echo_bad=0` — HPS and fabric agree on the descramble scheme,
  so the audio is correctly descrambled, not luck.

## Also added (both opt-in, off unless the env var is set)

- `S573MP3_HB=1` — the state line above.
- `S573MP3_TONE=1` — substitutes a 440 Hz sine for the decoded MP3 through the **same** ring
  path, to bisect delivery from decode. It was built but never needed: the gate fix made real
  audio play, so the tone stayed unused. Keep it — it is the right first instrument if the
  audio ever goes silent again.

## ~~Open bug~~ FIXED 2026-07-31: music kept playing after the game stopped it

Leaving the stage/mode screen back to the main menu, the stage music **kept playing**. This
is the known `reset_playback` gap: MAME flushes the decoder FIFO on **both** edges of the
playback enable, and we flush on neither, so whatever is already buffered keeps draining and
the streamer keeps being credited.

Pin which side owns it before writing any fix — the heartbeat answers it in one run. Bring up
the log (`local/tracedig/mister_main_logcapture.sh` with `HB=1`), trigger the transition, and
read the line at the moment the game stops:

- `ctrl` drops the drain bit (`0002` → `0000`) but audio continues → the **fabric** keeps
  draining a stale ring; the fix is RTL and costs a Quartus build.
- `ctrl` stays `0002` and `frames`/`cons` keep climbing → the **HPS** never learned about the
  stop; fix is service-side, no build.
- `cfg_epoch` moves at the transition but the ring is not re-initialised → we are decoding the
  new config on top of old buffered PCM; fix is a flush (`mp3dec_init` + zero the ring +
  reset `pcm_wr`) on the epoch change, service-side.

Ring depth is 32768 beats ≈ 1.5 s at 44.1 kHz, so a tail *longer* than about a second and a
half means something is still actively feeding, not just buffered residue — that distinction
alone narrows it before any code is touched.

### DIAGNOSED 2026-07-31: the drain follows bits the game never clears

Measured, not inferred. Raw config flags on every adoption (new `S573MP3_HB` CFG line):

```
epoch=0   flags=0001  mp3_en=0 stream_en=0  start=00000000 end=00000000   <- idle, drain OFF (correct)
epoch=7   flags=000f  mp3_en=1 stream_en=1  start=0067b840 end=006c3bac
epoch=14  flags=000f  mp3_en=1 stream_en=1  start=006c4040 end=0079c4fa
epoch=33  flags=000f  mp3_en=1 stream_en=1  start=00a72840 end=00be271a
epoch=47  flags=000f  mp3_en=1 stream_en=1  start=0079c840 end=00854ab2
```

**The game asserts `fpga_ctrl[14:13]` once and never clears them.** Every song change rewrites
`start`/`end` with both enables still high. Corroborating: across a 3-minute window spanning
several screens, `ctrl` stayed `0002` and `frames` climbed at a constant rate; over the whole
run there were ZERO `ctrl=0000` samples with a nonzero `cfg` epoch; and `cfg_epoch` stepped in
a rigid +7 (one tick per MP3CFG register write, i.e. song setup only) rather than the irregular
steps a play/stop toggle would produce.

Both sides are individually "correct" and the bug lives between them: `s573_core_apply_cfg()`
does clear `DRAIN_EN`, and `k573dio` does tick `cfg_epoch` on `fpga_ctrl[14:13]` — but the game
never moves those bits, so the clear never fires. The comment in `apply_cfg` ("those bits are
the game pressing play or stop") is **not true of ddrsbm**.

Fix direction (service-side, no build): stop the drain on window exhaustion — `cur` reaching
`end`, which the mailbox already reports — rather than on an enable bit. Keep the enable as a
gate for *starting*, since epoch 0 shows it correctly reads 0 while idle.

### FIXED (fork `ae5c62d`, service-side, no build)

Enable = START gate only; end on the honest signal instead — the descrambled window
exhausted (`cur >= mp3_end`, the same bound the fabric's own `stream_en` uses), gated on the
ring having drained (`pcm_wr == pcm_rd`) so the decoded tail plays out rather than being cut
mid-phrase.

Verified on de10:

```
s573mp3: song end -- window exhausted (cur=006c3bac end=006c3bac) and ring drained, drain OFF
s573mp3: song end -- window exhausted (cur=0004a2b2 end=0004a2b2) and ring drained, drain OFF
```

`cur` lands EXACTLY on `end` (clean termination, not an overshoot), and the pre-registered
discriminator moved as predicted: **`ctrl=0000` with a nonzero `cfg` epoch went 0 → 20** over a
3-minute window spanning several screens. Zero was not a small number before — that state was
structurally unreachable. Host tests still 10 groups PASS.

## Open follow-up: it CLIPS

Peak is **above 0 dBFS** on every measurement (+1.17, +1.64). `s573_audio_mix` saturates at the
16-bit rails by design, so this is clean clipping rather than wrap — but SPU + MP3 at full
scale is hitting the ceiling. Worth an attenuation pass (or a look at the MP3 channel's gain)
before calling the audio *finished*. It sounds right; it is not yet proven undistorted.

## Board / repo state

- `/media/fat/MiSTer` = `0c5d306b` (fork `79f1031`, clean, no probes). Stock is
  `/media/fat/MiSTer.orig` = `f867e7bb`.
- `/media/fat/MiSTer.ini` has `debug=1` added; backup at `/media/fat/MiSTer.ini.bak573`.
- Fork commits `79f1031` (the `is_573` gate) and `ae5c62d` (song end) are **pushed** to
  `fabricore-eng/Main_MiSTer` `feat-s573-mp3`.
- Golden `ddrsbm.sav` intact (`82243fe3`).

## Remaining: an EARLY stop (failed stage) is invisible to us — MAME is the next instrument

Reported by ear: music keeps playing when a stage is **failed**. The song-end fix above does
not cover this and cannot: it ends on window exhaustion (`cur >= mp3_end`), and a failed stage
aborts the song *early*, so `cur` never reaches `end`.

Measured (2026-07-31, 16 config adoptions across a full run): **every single adoption reads
`flags=000f`** — `mp3_en=1 stream_en=1`, without exception, through song changes and menu
transitions. There is therefore **no signal on our side that represents "stop now"**. The
enable bits are a start gate and nothing else, and no epoch tick accompanies an abort.

That exhausts what our own instrumentation can answer. It shows what we *receive*; the open
question is what the game *intends*, and that is an oracle question:

**Next: stand up MAME as a behavioural oracle.** Everything needed is already on `dell` —
MAME 0.285 at `/usr/games/mame`, the ddrsbm set at `dumps/mame573/ddrsbm.7z`, and
`tools/mame573.sh` (a thin wrapper over the hub runner, currently hardcoded to `hyperbbc` —
teach it the ddrsbm set). Lua-hook the k573fpga control-register writes, drive ddrsbm to a
stage failure, and log the actual write sequence. That says what the game does to stop
playback instead of us inferring it from an absence.

Two caveats worth carrying in: MAME's 573 MP3 emulation is itself an approximation, so treat
it as authoritative for **register-level intent** (what is written, when) and only indicative
for exact sample output; and reaching a stage failure inside MAME needs the flash install plus
menu navigation, so it is a session of work, not a quick check.

It also settles the clipping item: our peak > 0 dBFS is currently a taste question, but
against MAME's decoded PCM for the same song it becomes a level diff with a reference — the
same move that turned this whole audio question from vibes into −30.7 vs −11.4 dB.

**Method note.** The first pass at this capture reported three empty result sections. The
marker used to bound the log range never landed (`grep -c STAGE-STARTED` = 0), so the ranges
were vacuous — an artifact, not a finding. Re-extracting without the marker gave the 16/16
result above. Second time this session an empty output nearly became a false conclusion (see
the `/dev/null` stdout trap): **verify the instrument before believing a null.**

## MAME oracle: BUILT, taps correctly, NOT YET reaching the MP3 code

`tools/mame_dio_regs.lua` + `MAME573_SET=ddrsbm tools/mame573.sh` (both committed). The tap
works — the game's FPGA bitstream upload to `0xf8` is logged exactly where the docs say it
should be, so the address base `0x1f640000` and the decode are right.

**It has not yet produced a usable answer, and the zeros must NOT be read as one.** Across
40 / 400 / 700 emulated-second requests, DIO activity always stops at t≈3.209 (the bitstream
upload) with **zero** `0xae` (`fpga_ctrl`) writes — but the liveness control never fired
either, so there is no evidence distinguishing:

- the game is stalled early (plausible: `gq894ja.u1` and `.u6` are `ROM NEEDS REDUMP`, and the
  hub's Gate −1 doctrine says a bad security dump fails exactly like a logic bug), from
- the game is running fine and simply has not reached the MP3 code inside the emulated window,
  from
- MAME exiting early for an unrelated reason — the 400 s run returned a byte-identical log to
  the 40 s run, and the 700 s run returned a *smaller* one, which no correct interpretation
  explains.

**Blocker for the next session: get liveness working first.** `emu.register_periodic` and
`emu.register_stop` are gone-or-deprecated in 0.285 and did nothing;
`emu.add_machine_frame_notifier` registered without error (no warning printed) and still never
fired. Until a heartbeat with a PC sample lands in that log, every conclusion from it is
unfounded. Options: check the 0.285 Lua API directly (`mame -help` / the plugin docs on dell),
or drop the notifier entirely and sample from the tap itself (log one line per N writes plus a
periodic PC read driven by a debugger hook).

Corroborating evidence that MAME *can* run this title: `~/.mame/nvram/ddrsbm/` on dell holds a
complete installed set — 8× `29f016a.*` flash chips, the 132-byte `cassette_game_eeprom`, and
`m48t58` — which is where the golden images came from originally. So the security data exists
despite the redump warnings, and reaching gameplay should be possible.

**Third time this session** an absent output nearly became a finding: the `/dev/null` stdout
trap, the log marker that never landed, and now this. The rule has earned its place — *verify
the instrument before believing a null.*
