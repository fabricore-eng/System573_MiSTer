# MP3 audio verdict on silicon: **NEGATIVE** — the forked Main changes nothing measurable

First on-hardware test of the P4b MP3 transport, now that ddrsbm boots from its restored
flash install (`docs/2026-07-31-ddrsbm-flash-restore-root-cause.md`). **No MP3 audio.**
Stock Main and the forked Main produce the same audio on the same screen, to within 0.1 dB.

## The A/B (de10, core `abfe073a`, ddrsbm SELECT MODE screen, 25 s astats each)

| Main | md5 | Peak dBFS | RMS dB | screen |
|---|---|---|---|---|
| stock | `f867e7bb…` | −5.406 | −30.672 | SELECT MODE (`local/audio/screen_stock.png`) |
| forked (`08b3488`) | `e584938a…` | −5.627 | −30.764 | SELECT MODE (`local/audio/screen_fork.png`) |

Both screenshots are the identical SELECT MODE frame (BEGINNER / EXPERT / NONSTOP MEGAMIX,
`CREDIT(S): 0  1/2`). Each run was de-confounded: devlock reboot → MENU → `.s4` + straps →
exactly one `load_core` → coin ×3 → start. The human, listening live, heard no music in
either. **Δ = 0.09 dB. There is no MP3 layer in the output.**

## Instrument checks (both passed — the null is real)

- **The capture chain carries audio.** `ffprobe` on `rtsp://…/de10` shows
  `Stream #0:1: Audio: opus, 48000 Hz, stereo`. Pressing coin/start produced
  **Peak −4.66 dB / RMS −30.74 dB** where the attract screen had measured a hard `-inf`.
  So the SPU → HDMI → capture card → mediamtx → ffmpeg path is alive end to end, and a
  `-inf` really means silence rather than a dead instrument.
- **`s573_audio_mix` is a passthrough when MP3 is idle** (`rtl/s573_audio_mix.v`), so SPU
  reaching the output does not imply the MP3 channel does — which is exactly the observed
  split: SFX present, music absent.
- **The game's BGM is genuinely MP3, not SPU.** DIO-board games are "SPU + MP3 stream";
  base-board games are SPU-only (`docs/2026-06-27-board-variants-and-powyakex-audio-handoff.md`).
  So a silent BGM with working SFX is the expected signature of a dead MP3 path.

## Correction to an intermediate claim

One earlier 25 s window on this same screen read **Peak +0.14 dBFS / RMS −20.2 dB** and was
reported here as music. **It did not reproduce** — the controlled A/B above, run twice on the
same screen, sits at −30.7 dB for both binaries. Treat the −20.2 dB reading as unexplained,
not as evidence. Two candidates worth keeping: a transient SPU announcer/jingle burst that
happened to land inside that particular window, or a genuinely intermittent MP3 burst that
underran immediately. It is *one* unreproduced measurement either way.

## Deploy provenance (settled, since it would otherwise invalidate the null)

The core on the board is `abfe073a`, the timing-closed build with the option-(c) fabric.
dell's `output_files/Konami_System_573.rbf` is a *different* image (`e204c70c`, 4,216,676 B)
built 2026-07-31T01:40Z from ref **`6cf6e92`** — an abandoned bisect build from the
"boot regression" false alarm, never deployed (`head /tmp/dellbuild-573.log` records the
ref). Do not confuse the two; the log is namespaced per build and is overwritten each time.

Residual risk, stated plainly: the deployed rbf's exact source commit is inferred from
timestamps (Mac `output_files` mtime 2026-07-30 18:10 PDT, i.e. after the last RTL commit
`43f26af` at 17:15 PDT), not from a recorded build log. It has not been *proven* to contain
`s573_hps_ext`. Closing that hole is step 1 below.

## Next, in order

1. **Get observability before another swing.** Main is launched from `/etc/inittab`
   (`::sysinit:/media/fat/MiSTer &`) with stdout on `/dev/console`, so the service's own
   prints — `s573mp3: service up (DIO %08x, PCM ring %08x, %u beats)`, the mono/sample-rate
   warnings — are currently going nowhere we can read. There is no `/tmp/MiSTer.log`. Replace
   `/media/fat/MiSTer` with a two-line wrapper that execs the real binary with stdout+stderr
   redirected to a file (keep `MiSTer.orig` as the escape hatch; `load_core` re-execs Main via
   `fpga_io app_restart`, so the wrapper survives a core load). Without this every further
   step is blind.
2. **Then split the transport at the mailbox.** "Service up" printing at all proves the core
   really has `s573_hps_ext` (and retires the provenance risk above). If it never prints, the
   service is not starting; if it prints but the PTRS epoch never gets acked, the SPI mailbox
   is the fault; if the epoch acks but `hps_cons_bytes` never advances, the fault is the
   decode/ring side.
3. Only after 1–2 is a rebuild-at-HEAD worth 35 minutes of the shared box.

## Board state at end of session

Forked Main installed (`e584938a`, from `Main_MiSTer@08b3488` rebuilt on dell this session —
dell's binary had been stale at `fb2497c`). `MiSTer.orig` = stock `f867e7bb`, revert with
`ssh de10 'cp -a /media/fat/MiSTer.orig /media/fat/MiSTer.tmp && mv -f /media/fat/MiSTer.tmp /media/fat/MiSTer'`.
ddrsbm sitting at SELECT MODE. Golden `ddrsbm.sav` intact (`82243fe3`). devlock released.
