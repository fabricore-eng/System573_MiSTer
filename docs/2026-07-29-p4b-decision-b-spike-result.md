# P4b — DECISION-B spike result: descramble on the HPS

Date: 2026-07-29 · Branch: `feat-digital-bringup` · Spike code: `sim/spike_b_descramble/`

## Verdict in one line

**The descramble leg is PROVEN feasible — build it. But do NOT build "decision B" as the
design doc words it.** The wording promises two things it cannot deliver ("deletes the epoch
handshake", "no loss of fidelity to the game"). The variant that survives adversarial review
is **option (c): delete the byte ring, keep `k573_mp3stream` as an HPS-credit-paced position
tracker** — and it has a hard prerequisite (bug 1 below) that must be fixed first.

## What was measured

A standalone C99 reference (`s573_descramble.c`, written to ship in
`Main_MiSTer/support/s573/`) reproduces the fabric's emitted MP3 byte stream **bit-exactly**:

| | |
|---|---|
| Cases | **31/31 passed** |
| Bytes compared | **45,377**, zero divergences |
| Reproduced independently | yes — re-run gives 31/31 in 8.3 s |
| Negative control | **RED**, three mutations, diagnostically specific |
| C throughput | 429.5 MB/s (default) / 707.4 MB/s (ddrsbm), Apple M1 Pro |

The bench instantiates the **real** `rtl/k573_mp3stream.v` + `rtl/k573_mp3dec.v` with no
expected values inside it and dumps every accepted `out_byte`; the C runs over the identical
DRAM image; a third analytic length check lives in the driver. Neither side sees the other.
Backing is req/ready with always-non-zero randomized latency (≥2 cycles, occasional ~40-cycle
DDR3-ish stalls). Sink is 6 seeded DEMAND patterns from always-ready to 1-in-64 near-stalled.

**Coverage** — both schemes; windows of 1, 2, 48, 64, 96, 128, 200, 256, 300, 333, 600, 777,
2048, 4000 words; zero / all-ones / `key1[15]`-set / `key1[15]`-clear / key3-wrapping / random
keys; window offsets 0 and words 4/7/11/32/64/512; C-side chunk sizes 1..4096 so the buffered
low-byte state is re-entered on odd boundaries; 4 mid-stream reload cases. Full stream
semantics, not just the per-word transform: fetch order, address-bit-0-ignored decode, running
key schedule in both schemes, high-then-low byte order, and the 2N−1 last-word drop **with the
schedule still advancing for that word**.

**Pacing invariance was tested directly, not inferred:** one window streamed under all 6
back-pressure patterns × 2 DRAM-latency seeds, all 12 RTL outputs byte-identical to each other
and to C.

### The negative control (the reason the number means anything)

Three mutations, each behind a `-D` define that is OFF in every normal build — the same
red/green discipline `sim/Makefile` already uses for `MP3_UNPACED`:

| Mutation | Result | Signature |
|---|---|---|
| `NO_KEY3_INC` (drop `key3++`) | 14/31 pass | first divergence at **byte 2** — the first byte of the *second* word, exactly where a dropped increment must first appear. Survivors are the 13 ddrsbm cases (which never touch key3) plus `min1word-def` (one word never observes the increment). |
| `LOW_FIRST` (swap byte order) | 0/31 pass | fails at byte 0 |
| `NO_2N1` (keep final low byte) | 0/31 pass | fails on **length** with every prefix byte identical |

A reviewer then added six more mutations to the untouched crypto core (drop the ddrsbm key1
rotate, drop the key2 conditional rotate, rotate key1 as a full 16, make `derive_key` the
identity, drop the `^ (key & 0x5555)`, break one bit of the key3 spread). **The harness caught
all six**, with survivors provably insensitive rather than missed (e.g. under the ddrsbm
no-rotate mutation the passing cases are exactly those with `key1 ∈ {0x0000, 0xFFFF}`, where a
rotate is a no-op). This is a discriminating differential, not an alarm.

### CPU cost is a non-issue

Measured ~7.5 cycles/output-byte on M1. Scaled to the Cyclone V HPS (800 MHz 2-wide in-order
A9, IPC ~1.2, +15% spills): ceiling ~12–16 MB/s against a real stream of 16–40 KB/s ⇒
**0.11%–0.29% of one core**, plus ~0.4% for uncached `/dev/mem` reads ⇒ **~0.7% worst case**.
minimp3 itself is 3–8% of a core, so the descrambler adds 5–10% *on top of the decoder*. Note
this is an estimate scaled from the M1, not measured on target — it was never the binding
constraint. Read in ≥1–2 KB chunks (not mdplus's 8192, which costs ~1.3 ms in one poll).

## Two real bugs found in the shipped tree — independent of decision B

Both were found because the cross-check to MAME was done properly for the first time.

**1. Enable-gating key desync — a genuine RTL/MAME divergence, and plan A is what arms it.**
`word_stb` fires in `S_STB` ([k573_mp3stream.v:131](../rtl/k573_mp3stream.v:131)) advancing the
key schedule, but `cur` advances only in `S_LO` ([:189-197](../rtl/k573_mp3stream.v:189)).
The mid-stream disable at [:205-208](../rtl/k573_mp3stream.v:205) dumps to `S_IDLE` from *any*
state — including after the key advanced but before `cur` did. Re-enable re-enters `S_ADDR`
([:165](../rtl/k573_mp3stream.v:165)) and **re-reads the same `cur`**, firing `word_stb` a
second time on a word whose schedule already moved. MAME buffers the decrypted word instead.
Measured: patching the bench to toggle bits 13/14 mid-stream, **35 of 200 disable offsets
change the emitted stream, every one emitting 666 bytes for a 665-byte window** — one extra
byte plus a corrupted tail. No bench in the suite catches it: `tb_k573_mp3stream` toggles the
enables only from the parked state after completion
([tb_k573_mp3stream.v:150-156](../sim/tb_k573_mp3stream.v:150)).
Inert today only because `emu.sv` ties `dio_mp3_ready = 1'b0`. **Driving `out_ready` — i.e.
building the byte ring — arms it.** Under option (c) it becomes live *and* corrupts `cur`,
which is the very thing (c) exists to protect. **Fix this before either path.**

**2. `0xae` bit 12 "still streaming" is permanently asserted** in the shipped tree, presenting
ddrsbm's three runtime callers (`0x800ac39c/3e4/7ec`, which require `==0` to proceed) with a
busy flag that never clears. Must be resolved whichever way B goes.

Two lesser findings worth recording: the design doc's PCM-ring depth is **wrong by 2×** (says
256 KiB ≈ 0.74 s; as built it is **1.486 s**) — every A-vs-B latency comparison written against
0.74 s is wrong, and `BEATS_LOG2=13` (0.37 s) is probably the sane starting point for must-fix
#4. And the epoch is **already missing for the built PCM leg**: `mp3_reload` is invisible to
the HPS and nothing flushes the ring, so at a song boundary the chart clock can lead the audio
by up to 1.5 s with every honesty signal reading GREEN. That is a plan-A bug too — neutral
between the options, but it needs owning.

Separately: the existing `tb_k573_mp3dec` reference model is a **transliteration of the RTL's
own functions**, so the "44/44 green" never tested fidelity to MAME — it tested
self-consistency. That gap is now closed for the descrambler by an exhaustive **2^32
(data,key)** sweep of `decrypt_common` against MAME master plus 20M stream words.

## The honest ledger: what B deletes vs what it moves

Four investigation lanes all returned *supports-B*. All three adversarial verifiers returned
*refuted* — every one of them against the claim's **wording**, and every one conceding the
direction is right.

**Genuinely deleted:**
- The **fabric→HPS byte ring** and its 64 KiB of DDR3.
- The **write-side arb mux** — a 64-bit mux out of the placement-marginal f2sdram `DDRAM_ADDR`
  combinational cone. The *narrower read-side* version already cost a hardening pass
  (`fc58752`), and bridge marginality is the design's #1 ranked risk.
- **must-fix #1 sub-hazard (iv)** — the producer/consumer ring splice, the one piece the design
  doc itself calls unprecedented ("MD+ has no seek-mid-stream analog"). This is the strongest
  single argument for B.
- ~32–80 KB/s off the bridge entirely.

**NOT deleted — moved, and in one case widened:**
- The **atomic snapshot** survives and grows from 2 words to ~8 (`mp3_start[24:0]`,
  `mp3_end[24:0]`, `key1/2/3`, `cfg_ddrsbm`, `fpga_ctrl[15:13]`, epoch).
- Those 8 words are **not plumbed anywhere today** — all five k573dio outputs are left open at
  [system573_top.v:334-335](../rtl/system573_top.v:334), and `mp3_reload` has no port at all
  ([k573dio.v:203](../rtl/k573dio.v:203)). B is a delete **plus a plumb**.
- Needs **one new SPI command** (`CMD_573_MP3CFG`, say 0x6B — 9 codes are free, and `dout_en`
  currently stops at 0x6A).

**New hazards B introduces:**
- **HPS mmap bypasses k573dio's drain-before-read interlock.** The DIO write path is posted
  twice over with no completion signal anywhere — `dio_wr_ack` is Avalon command *acceptance*,
  not DDR3 commit ([s573_ddram_arb.v:141-145](../rtl/s573_ddram_arb.v:141)), and the MiSTer
  DDRAM port has no write response. Up to 2 KiB of the game's writes can sit stranded in the
  1024-deep FIFO, invisible to an mmap reader, while the reload registers describing that
  payload arrive with **zero** latency. Mitigation (export `wf_cnt == 0` as a status bit) is
  cheap but is *not* sound as "committed" — price it as a cadence assumption, not an invariant.
  Note the bench guarding this exact invariant, `tb_k573dio_ram` part 7, is one of the tests
  literal-B makes vacuous.
- **Word-alignment desync fails silently in the worst way.** The schedule is per-word stateful
  with no resync point, so one skipped or duplicated word yields plausible-but-wrong audio
  while `0xa8`/`0xca`/`0xcc` all advance GREEN and minimp3 intermittently locks on. Plan step 7
  (byte-oracle check against MAME) is mandatory, not optional.
- **The pacing gate degrades from an RTL invariant to one line of C**, inside a ~5 ms poll
  where "top up the buffer each poll" is the natural thing to write — the `MP3_UNPACED` flood
  bug relocated to software with no sim oracle.

**Fidelity claims that are false as worded:** `0xaa` bit 12 DEMAND is *literally* sourced from
the byte ring (`mpeg_status = {1'b0, mpeg_playing, mpeg_idle, mp3_out_ready, 12'b0}`,
[k573dio.v:265](../rtl/k573dio.v:265)) — delete the ring and DEMAND has no source. `0xae`
bit 12 is sourced from `cur`. Enable-bit pause/resume and `[start,end)` bounds are enforced by
the FSM literal-B deletes.

## Recommendation

**Adopt B in the option-(c) shape**, with prerequisites:

> Delete the byte ring and the write-side mux. **Keep `k573_mp3stream` whole** as a position
> tracker whose `out_ready` is driven by an HPS-reported cumulative consumed-byte credit
> (reusing the cumulative-diff + rebaseline mechanism already built for the frame counters, and
> the `hps_byte_rd` mailbox word that already exists and is B-gated). Publish the 8 config words
> in one new atomic SPI command.

Why this and not literal-B: it keeps `0xae`, DEMAND, enable-gating and window bounds inside
tested Verilog — 44/44 stays *meaningful* rather than vacuous — while still deleting the ring,
the mux, and the unprecedented splice hazard. The trade-off the design doc worried about
("shifts position ownership to the HPS") **inverts** on the merits: `cur` under the byte-ring
plan measures bytes pushed into a ~4 s buffer, not audio played; an HPS-credit-paced `cur`
leads real audio by ~1.5 s and a PCM-drain-referenced one by ~5 ms. The 5 ms SPI poll is three
orders of magnitude below the ring latencies **both** designs already carry.

Honest cost of (c): the fabric still reads DIO RAM at 16–40 KB/s and still spends the
`k573_mp3dec` ALMs. It is "delete the ring", **not** "make the fabric consumer-only" — so this
is not literally the MD+ shape the design doc was reaching for.

**Prerequisites before writing option-(c) RTL:**
1. **Fix bug 1** (enable-gating key desync) and add the bench that catches it. Non-negotiable —
   (c) makes it live against `cur`.
2. Resolve `0xae` bit 12 (bug 2).
3. Specify the 8-word atomic snapshot + the `wf_cnt == 0` quiesce gate.
4. Cap the HPS input window with a `#define`; gate the read loop **strictly** on
   `pcm_ring_free >= 1 frame`, never on elapsed time.

## RESOLVED 2026-07-29 (later the same day): the three `0xae` bit-12 callers

The open question above — *what do the three runtime callers of `0xae` bit 12 actually gate
on?* — is now settled by disassembly, and it **decides the option-(c)-vs-literal-B question
against literal B**. No hardware needed: `local/ddrsbm_psx_exe.bin` covers the addresses
(load `0x80010000`, size `0xcf000`) and capstone disassembles MIPS locally.

`dio_get_mpeg_playing` (`0x800aaeb0`) is exactly what its name says — `lhu 0x1f6400ae`,
`andi 0x1000`, `sltu $v0,$zero,$v0`, i.e. it returns bit 12 as a boolean. Its three callers:

| Caller (fn / call site) | What it is | Guard | Effect |
|---|---|---|---|
| `0x800ac394` / `…39c` | **START** playback | acts only if **NOT** playing | `set_mpeg_ctrl(a1=1)` → sets bit 14 |
| `0x800ac3dc` / `…3e4` | **STOP** playback | acts only if playing | `set_mpeg_ctrl(a1=0)` → clears bit 14 |
| `0x800ac7e0` / `…7ec` | status getter | none (no branch) | stores the flag into a caller struct |

Both control paths funnel through the same worker `0x800ac200`, which shadows its three args
into a struct at `0x80154f08` and calls `dio_set_mpeg_ctrl` (`0x800aaecc`). That setter's bit
mapping, read off the disassembly: **a0→bit15 (`0x8000`), a1→bit14 (`0x4000`), a2→bit13
(`0x2000`)**, then `sh` to `0x1f6400ae`. Our `stream_en = fpga_ctrl[13] & fpga_ctrl[14]`
([k573_mp3stream.v:102](../rtl/k573_mp3stream.v:102)), so a1 is STREAMING_ENABLE and the
start/stop reading is exact.

**These are idempotence guards — "don't start what's already started, don't stop what isn't
running."** That is the worst possible shape for the literal-B plan, because a CONSTANT breaks
one path whichever value you pick:

- **tie bit 12 to 0** (what literal-B would have to do with no `cur`): the START guard always
  passes — fine — but the STOP guard **never** passes. The game can never stop playback.
- **tie bit 12 to 1**: the STOP guard always passes, but the START guard never does. The game
  can never *start* playback.

### Consequence 1 — this kills literal B's headline advantage

Bit 12 must be **honest and changing**, which means it needs a live position source. Under
literal B the fabric has no `cur`, so the HPS must report position back — i.e. literal B needs
the HPS→fabric position channel **anyway**. It therefore does NOT deliver "fabric
consumer-only / the exact MD+ shape", which was its main argument. What survives for literal B
is only the ALM saving from deleting `k573_mp3dec` + `k573_mp3stream` — real on a 97%-full die,
but now paid for by moving start/stop/window-bounds semantics into unguarded C.

Option (c) gets an honest bit 12 for free, because it keeps `cur`. **Recommendation stands:
build option (c).**

### Consequence 2 — the shipped tree has a live bug, worse than previously recorded

Bug 2 above ("`0xae` bit 12 permanently asserted") was filed as a should-fix with unclear
impact. Correcting an overstatement in the first version of this section: it is **not** true
that "the game can never begin playback at all". The readback is
`fpga_ctrl[14] && cur >= mp3_start && cur < mp3_end`
([k573_mp3stream.v:182](../rtl/k573_mp3stream.v:182)), and `fpga_ctrl[14]` is exactly what the
START routine sets — so before the first start it reads 0 and **the first start succeeds.**

The real defect is the one after that. `emu.sv` ties `dio_mp3_ready = 1'b0`
([emu.sv:2277](../rtl/emu.sv:2277)), so `out_ready` never rises, `cur` never advances, and the
window is never traversed. Therefore:

- bit 12 latches high the moment streaming is enabled and **never self-clears**;
- **the game can never observe a song ending** — on real hardware `cur` reaches `mp3_end` and
  the bit drops by itself, which is precisely the end-of-song signal;
- a subsequent START is then refused by its own guard, unless a STOP intervenes first (STOP
  clears `fpga_ctrl[14]`, which drops the bit).

So it is a *song-never-ends* bug, not a *never-starts* bug — worse in a rhythm game, and still
not cosmetic. Note the fix is **not** a patch to k573dio's read path, which is already correct:
the bit is dishonest only because `cur` is frozen. Giving `cur` an honest advance source IS the
option-(c) consumption credit. Bug 2 therefore closes as part of the credit slice, not as a
separate change.

### ALSO RESOLVED: `0xaa` bit 12 (DEMAND) is never read

Settled the same way, statically over the whole executable rather than from a boot-only
trace. `mpeg_status` (`0x1f6400aa`) has four one-bit accessors, one per status bit —
`0x800aad5c` bit15 ENABLED, `0x800aad78` bit14 PLAYING, `0x800aad94` bit13 IDLE,
`0x800aadb0` **bit12 DEMAND** — each a three-instruction `lhu`/`andi`/`sltu` getter, and
they look auto-generated.

**All four have ZERO callers.** A scan of every `jal`/`j` target across all 189,419
decoded instructions finds nothing reaching any of them. So ddrsbm reads `0xaa` never,
and deleting DEMAND's source costs nothing for this title.

Two things make that null trustworthy rather than another dead instrument:

- **Positive control.** The same scan finds exactly the three known callers of the
  `0xae` streaming getter (`0x800ac39c/3e4/7ec`) and one caller each for the `0xcc` and
  `0xce` counter getters. An instrument that finds the knowns can be believed about the
  unknowns.
- **The first attempt was wrong and was caught.** A naive single-pass disassembly stopped
  after **2 instructions** (capstone halts at the first non-code word) and reported "no
  DIO accesses at all". That null was an artifact. The scan above restarts every 4 bytes
  past undecodable data — MIPS is fixed-width — and recovers 189,419 of 211,968 words.

Remaining caveats, stated plainly: this is **ddrsbm only** — GuitarFreaks, DrumMania and
Mambo could differ and have not been scanned. And an indirect call through a function
pointer (`jalr`) would not be caught; only direct `jal`/`j`.

## The one thing that still needs hardware

Two lanes converged independently on the same decisive, **build-free** check:

> With ddrsbm running, mmap-dump a window at `0x32000000 + mp3_start` and byte-compare it
> against the scrambled MP3 as it exists in the disc image.

Because the scrambling lives on disc and the fabric descrambles only on the way out, a match
proves the write path, the address map, and cross-agent visibility **in one shot, without
needing the keys**. Nobody has yet mmap'd `0x32000000` on the de10 — it is strongly inferred
from `tools/mister_vram_dump.sh` working at `0x30000000`, never executed.

The address contract itself is *derivable*, not assumed: `phys = 0x32000000 + dio_byte_addr`,
plain little-endian, strict 1:1, no swap and no translation table
([s573_ddram_arb.v:105-112](../rtl/s573_ddram_arb.v:105),
[k573dio.v:405-407](../rtl/k573dio.v:405)).

## What this spike does NOT prove

1. **Visibility.** The algorithm is portable; that the HPS mapping of
   `0x32000000..0x33FFFFFF` sees the same bytes the fabric sees, live and correctly ordered, is
   an untested hardware question (the check above settles it).
2. **Ownership.** Only the "can C reproduce the bytes" risk is removed.
3. **The 2N−1 boundary is MAME-oracle-derived, not silicon-derived.** Both sides implement it,
   so if real DIO silicon emits 2N, both are wrong together — already flagged for P4c.
4. **The reload race.** The bench quiesces the sink before pulsing `reload` and takes the
   pre-reload byte count from the RTL as a *stimulus boundary* (asserted to land within +2 of
   where it was asked). That race **is** must-fix #1 and is deliberately out of scope. Reload
   coverage is also the weakest part of the case set: `mp3_start` is never moved and the keys
   are never changed at a reload, yet in hardware a reload is *caused* by writing exactly those
   registers. A reviewer measured a **30% divergence (588 vs 766 bytes)** in the
   `mp3_start`-moved case class, which the spike never instantiates — coverage hole, not a
   rigged result (the shipped cases are byte-identical under both reload pulse shapes).

## Reproducing

```
cd sim/spike_b_descramble && ./run_spike.py
./run_spike.py --mutate NO_KEY3_INC | LOW_FIRST | NO_2N1     # must go RED
```

Everything is seeded — same command, same bytes, every run. Generated artifacts stay in
`build/` and are gitignored. Nothing existing was modified: `sim/Makefile` drives an explicit
`TESTS` list with no `$(wildcard)` and compiles `tb_<name>.v` from `sim/` itself, so a
subdirectory cannot be picked up by `make -C sim`. Suite re-verified at **44/44** before and
after.
