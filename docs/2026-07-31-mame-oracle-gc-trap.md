# MAME Lua oracle: three instrument failures, three fake results — 2026-07-31

Standing up the oracle took three rounds. Each round produced a log that looked like a
clean negative result and was actually a broken instrument. They are recorded in order
because the *third* one is the dangerous kind: the instrument was fully alive, producing
millions of correct-looking writes, and still systematically blind to the exact register
the investigation was about.

## Symptom

`tools/mame_dio_regs.lua` tapped the k573dio page (`0x1f640000..0xff`) to answer the one
question our own instrumentation structurally cannot: *what does ddrsbm write when playback
should stop?* Three runs at 40 / 400 / 700 emulated seconds all produced:

- exactly 105 log lines,
- **zero** writes to `0xae` (`fpga_ctrl`),
- the log ending at t=3.209 in the middle of a 96-write run to `0xf8`,
- the 400 s log **byte-identical** to the 40 s log, and the 700 s log *smaller*.

Read naively that says "the game stops touching the DIO right after boot, and never
enables MP3." That reading is wrong in a way that would have sent the next session chasing
a nonexistent bug.

## Cause

Every MAME Lua handle involved is **garbage-collector-owned**, and dropping it silently
removes the thing it owns:

- `space:install_write_tap(...)` returns a `memory_passthrough_handler`. When that object is
  collected, **the tap is removed**.
- `emu.add_machine_frame_notifier(...)` / `add_machine_stop_notifier(...)` return
  subscription objects with the same contract.

An `-autoboot_script` chunk's **locals die when the chunk returns**. The tap was in a local,
and the notifier return values were thrown away entirely inside a `pcall`. So the tap lived
until the first GC cycle — about 3.2 emulated seconds, right in the middle of the FPGA
bitstream upload — and then vanished. The notifiers never fired even once, which is why
there was no liveness line to contradict the empty log.

The tell was there in the data: a log that ends **mid-burst**, at no boundary the game
cares about, and run length having no effect on output size. Neither is explicable by any
correct reading of game behaviour.

## Fix

Every handle now lives in a global table (`_G.DIO`, `_G.SP`), and each is checked for `nil`
at arm time with an explicit warning. Do not demote these to locals.

Same 60 s romset, before and after:

| | before | after |
|---|---|---|
| log lines | 105 | 1379 |
| total DIO writes | (uncounted; tap dead) | 332,051 |
| liveness lines | 0 | 11, through t=60 |
| stop notifier | never fired | fired, `# DONE t=60.0` |

## Register decode was also wrong

The old annotation called `0xe0..0xe6` "crypto keys". Per our own `rtl/k573dio.v:679-682`
they are **lamps**; the crypto keys are `0xa8` / `0xea` / `0xec`. The map in the script is
now taken from the RTL write decode directly.

## What the live instrument immediately surfaced

`0xac` — the MAS3507D I²C bit-bang (`scl=din[13]`, `sda=din[12]`) — takes 1181 writes per
minute, which is why it now gets decoded into I²C transactions rather than dumped. Boot
issues two: `3a 68 a0 00 00 01 03 2f 00 30 00 00` and `3a 68 0f cb` (device 0x3a, command
0x68), i.e. decoder init.

That matters because `rtl/mas3507d_i2c.v:23-28` states plainly that subcommand `0x69`
(frame-count read) is served and **"0x68 pipes, 0x6a control, register/memory writes are
accepted and DROPPED — there is no decoder behind this port yet."** So every mute, volume,
or stop command the game sends the decoder chip is ACKed and discarded by our core.

That is a candidate explanation for the open bug (*music keeps playing when a stage is
failed*) with exactly the right shape: **a stop signal we are structurally unable to see.**
It is a hypothesis, not yet a finding — confirming it needs the oracle to show ddrsbm
actually using that path at a music stop.

## Then the SECOND instrument failure, hiding behind the first

With the tap fixed, the log was still flat: `writes` frozen at 332,051 from t≈40 onward,
zero `fpga_ctrl` writes, two I²C transactions total, PC pinned in `8001e0d8..8001e138`.
A tempting reading: "ddrsbm doesn't touch the MP3 registers in attract."

It never reached attract. A screen probe (`tools/mame_screen_probe.lua`) caught it parked on:

> DO YOU WANT TO INITIALIZE FLASH-ROM?  Yes: Please press test button

— the *same screen the real hardware was stuck on*. dell's `~/.mame/nvram/ddrsbm/` was
assumed to be a working installed flash; it was not. The tight PC loop was the game
polling a button that headless MAME was never going to press. Every conclusion drawn from
those logs was measuring an unpressed button.

Two traps inside the probe itself, both worth remembering:

- `manager.machine.video:snapshot()` returned **success** under `-video none` while writing
  nothing where it was looked for. The files existed — MAME's `snapshot_directory` is
  `$HOME/.mame/snap`, *not* the working directory. `pcall` returning true says the call
  didn't raise, not that it did anything.
- `pkill -f "mame ddrsbm"` on dell exited 255 having killed **its own shell** — the remote
  command string contains the pattern it searches for. Same self-match as the cockpit
  watchdog (`cockpit-watchdog-pgrep-self-match`). Kill by PID, or bracket the pattern.

## Getting past it

`tools/mame_flash_install.lua` presses the test button (`:IN3 :: Service Mode`) and watches:

| t | state |
|---|---|
| 20–45 | parked at the prompt, PC `8001e0d8..8001e138` |
| 45 | TEST DOWN — PC range immediately widens to `00000c80..800a0730` |
| 110 | `INITIALIZE FLASH-ROM NOW / PLEASE WAIT` — 20% |
| 200 | `FLASH-ROM INITIALIZE COMPLETE / Please press test button` |
| 210 | back in the poll loop, waiting on a *second* press |

MAME persisted the result to nvram on exit. The oracle now auto-presses when it detects a
park (PC inside a <0x400 window for a full 5 s sample), capped at 4 presses and disabled
permanently once any `fpga_ctrl` write appears — so it can never fire during real play,
where a test press would open the operator menu.

## THIRD failure: the 32-bit lane split — `fpga_ctrl` was never decoded at all

With the tap alive and the game confirmed in attract (screenshot: the DDR attract video),
a 1200 emulated-second run still reported **`fpga_ctrl_writes=0`**. It also reported
201,476 writes to `0xc0`, which is not an audio register at all — MAME maps it to the
**network buffer**, and our RTL does not implement it.

That near-became the finding "ddrsbm drives playback through some register we don't model".
It is false.

The PSX bus is **32 bits wide**. MAME reports every write-tap hit at a **dword-aligned**
offset and indicates which 16-bit half is live via the `mask` argument. The k573dio's
registers are 16-bit, so the register at `base+2` arrives in the **upper half of `data`**.
The tap did `data & 0xffff` and keyed off the aligned offset alone. Therefore:

| register | rides in | was decoded? |
|---|---|---|
| `0xa2` mp3_start lo | upper half of `0xa0` | no |
| `0xa6` mp3_end lo | upper half of `0xa4` | no |
| `0xaa` mpeg_ctrl | upper half of `0xa8` | no |
| **`0xae` fpga_ctrl** | upper half of **`0xac`** | **no** — and `0xac` was routed straight into the I²C decoder, which `return`ed early |

`0xae` is the register the entire investigation is about, and it was being swallowed by the
I²C branch.

**The tell was in the data from the first run onward: every offset ever logged was a
multiple of 4. Not one was 2 mod 4.** Real 16-bit register traffic cannot look like that.

Fixed by splitting on `mask` and decoding each live half separately. Same romset, 120 s:
`fpga_ctrl_writes` 0 → **14**, and `aa ae b2 b6 ba ee f6 fa fe` all appear. The boot init
sequence becomes legible at `pc=800aaefc`.

## FOURTH failure, mine: the fpga_ctrl bit labels were inverted

The first version of the decoder annotated `0xae` as *bit14 = MP3_ENABLE, bit13 =
STREAMING_ENABLE*. It is the other way round. Ground truth, two independent sources that
agree:

- MAME `k573fpga.h`: `FPGA_MP3_ENABLE = 13`, `FPGA_STREAMING_ENABLE = 14`,
  `FPGA_FRAME_COUNTER_ENABLE = 15`.
- our `rtl/k573_mp3stream.v:140`: `stream_en = fpga_ctrl[13] & fpga_ctrl[14]`.

This one mattered more than it looks, because **the stop event this oracle exists to find is
bit14 going low** — and with the labels swapped, every stop was being reported as a change
to the other bit. Fixed in `tools/mame_dio_regs.lua` and `tools/dio_log_summary.py`, which
now also print an explicit `*** PLAYBACK STARTS/STOPS ***` marker computed from
`bit13 AND bit14` rather than from either bit alone.

A **self-check now runs at end of every run** and prints an `INSTRUMENT WARNING` if a
substantial run decoded nothing at `2 mod 4` — so this exact blindness cannot recur
silently.

## Lesson

**Two more absent-output traps in one investigation**, on top of the `/dev/null` stdout
trap, the log marker that never landed, and the retracted audio false positive.

The pattern is consistent enough to name: *this project's default failure is a dead
instrument that looks like a clean negative result.* A control that shares a failure mode
with the thing it checks is not a control — the GC-owned liveness notifier died with the
GC-owned tap it was meant to police.

Three guards, in increasing order of what they catch:

1. **Before believing any zero, prove the subject was in a state where a non-zero was
   possible.** For an emulated game that is one screenshot. Catches failure #2.
2. **A positive control must be independent of the mechanism it validates.** Catches #1.
3. **Sanity-check the *shape* of the data you did collect, not just its presence.**
   Catches #3, and nothing else would have. The log was large, detailed, internally
   consistent, and wrong. What exposed it was noticing that every offset was a multiple
   of 4 — a property of the *distribution* of captured values, not of any one value. When
   an instrument reports a structural impossibility about its own output, that is the bug
   announcing itself.

Failure #3 is the one to remember. #1 and #2 produced obviously empty output. #3 produced
14 MB of plausible, useful-looking data with a single register class silently missing — and
that register class was the answer.
