# Spike B — can the HPS descramble the MP3 stream itself, bit-exactly?

**Question (Decision B, `docs/2026-07-03-p4b-mp3-transport-design.md`):** if the HPS
mmap-reads the *already-scrambled* MP3 words out of the DIO sample-RAM window in DDR3 and
descrambles them in C, does it get **byte-for-byte** the same stream the fabric
(`k573_mp3stream` + `k573_mp3dec`) would have written into the fabric→HPS byte ring? If yes,
the byte-ring writer — and the reload/epoch atomic handshake that is must-fix #1, and the
second write-side mux on the arb DIO channel — can be deleted, leaving the fabric
consumer-only.

**Answer: yes.** 30 randomized differential cases + 1 pacing-invariance case, **45,377 bytes
compared, zero divergences**, and the harness is proven able to fail (three deliberate C
mutations, all caught). Numbers and caveats below.

This directory is a **spike**, not part of the unit-test suite. It adds no file to `sim/` and
changes no RTL: `sim/Makefile` drives an explicit `TESTS :=` list with no `wildcard`, and each
entry compiles `tb_<name>.v` from `sim/` itself, so a subdirectory cannot be picked up by
`make -C sim`. Everything here is new and self-contained.

---

## What's in here

| file | role |
|---|---|
| `s573_descramble.h` / `.c` | **the deliverable.** Standalone C99 reference — no deps, no allocation, no globals, no I/O — shaped to drop into `Main_MiSTer/support/s573/`. Resumable pull() API so it fits an MD+-style poll loop. |
| `tb_spike_descramble.v` | Verilog **vector dumper**. Instantiates the REAL `rtl/k573_mp3stream.v` + `rtl/k573_mp3dec.v`, backs the `rd_addr/rd_req/rd_data/rd_ready` port with a randomized-latency sim DRAM, drives `out_ready` with a randomized DEMAND pattern, writes every accepted `out_byte` to a file. Contains **no expected values**. |
| `spike_main.c` | offline driver for the C side (emit mode + `--bench`). Not shippable code. |
| `run_spike.py` | builds both sides, generates cases, runs them, diffs byte-exact. |
| `build/` | generated: `.vvp`, `spike_c`, per-case `.hex` / `.bin` / `.rtl.bin` / `.c.bin` / `.meta`. Disposable. |

## Re-running it

```sh
cd sim/spike_b_descramble
./run_spike.py                        # everything: 31 cases, ~9 s      -> exit 0 on PASS
./run_spike.py --case 22              # one case
./run_spike.py --bench --mib 64       # throughput only
./run_spike.py --mutate NO_KEY3_INC   # NEGATIVE CONTROL, must go RED   -> exit 1
./run_spike.py --mutate LOW_FIRST
./run_spike.py --mutate NO_2N1
```

Needs `iverilog`/`vvp` and any C99 compiler on PATH. Everything is seeded — the same command
gives the same bytes on every run and on every machine.

## What the harness actually proves

The two sides never see each other. The RTL side is the real streaming engine simulated
cycle-accurately; the C side is a from-scratch reimplementation. The only value that flows
RTL → C is the *measured* pre-reload byte count in the reload cases (a stimulus boundary, not
an expected value — see below), and the harness asserts it landed within 2 bytes of where it
was asked to.

Semantics covered — the full stream, not just the per-word transform:

* **word fetch order** and the byte address → word decode (address bit 0 ignored, matching the
  k573dio backing mux);
* **running key schedule**, both schemes: `decrypt_default` (derived key from
  bitswap(key1^key2), key3 8→16 spread, conditional key2 rotate, key1 rotate-[14:0], key3++)
  and `decrypt_ddrsbm` (dec_common on key1, key1 rotate-left);
* **byte order**: descrambled word emitted **high byte then low byte**;
* **the 2N-1 quirk**: the final in-window word's low byte is dropped, and the key schedule
  still advances for that word;
* **reload / re-arm** (MAME `update_mp3_decode_state`): mid-stream `reload` re-inits
  `cur ← mp3_start`, re-seeds the keys, and drops the buffered low byte — including the case
  where `mp3_end` is extended at the same time;
* **pacing invariance**: the emitted byte *sequence* does not depend on how the sink
  back-pressures, nor on DRAM read latency. Tested directly, not inferred: the
  `bp-invariance` case streams one window under all 6 DEMAND patterns × 2 latency seeds and
  requires all 12 outputs to be byte-identical to each other and to the C reference.

Stimulus realism: the DRAM backing answers with a **randomized, always non-zero** latency
(≥ 2 cycles req→ready, plus rare ~40-cycle DDR3-ish stalls), data registered and held until
the next request — the `BACKING_EXTERNAL` contract. `out_ready` patterns run from always-ready
to a near-stalled 1-in-64 sink.

### Cases (30) + invariance (1)

Both schemes throughout: window sizes 1, 2, 48 (odd byte length), 64, 96, 128, 200, 256, 300,
333, 600, 777, 2048, 4000 words; keys all-zero, all-ones, key1[15] set and clear, key3 seeded
to wrap mid-stream, and per-case random keys; windows at offset 0 and at word offsets 4/7/11/
32/64/512; C-side chunk sizes 1, 2, 3, 5, 6, 7, 9, 13, 16, 17, 64, 512, 4096 bytes (so the
buffered-low-byte state is re-entered on odd boundaries); back-pressure patterns 0–5; and
2 + 2 mid-stream reload cases (plain re-arm, and re-arm with `mp3_end` extended 200 → 512
words).

### The one deliberate soft spot: the reload epoch

Pulsing `reload` while the sink is live is a **race** — whether the byte in flight at the
reload posedge is consumed depends on cycle alignment. That race *is* must-fix #1 in the design
doc, and it is not what this spike is testing, so the testbench **quiesces the sink** (holds
`out_ready` low for 16 cycles) before pulsing `reload`, then records the actual pre-reload byte
count in the `.meta` file for the C side to cut at. Measured: asked for 301/301/150/150, got
301/302/150/150 — inside the asserted ±2 window.

Note what this means for Decision B: **deleting the byte ring does not delete the epoch
problem, it moves it.** The HPS still has to decide what happens to bytes already pulled when
the game rewrites a setup register mid-song. It gets much easier (it is a local software
decision inside one C function instead of a cross-clock DDR3 ring handshake), but it does not
vanish.

---

## Negative control (mandatory — a green harness proves nothing until it can go red)

Three mutations live behind `-D` defines in `s573_descramble.c`, all **off** in every normal
build — the same red/green discipline `sim/Makefile` uses for `MP3_UNPACED`, `DIO_RAM_STUB`,
etc. Each was built and run against the same 30 cases:

| mutation | what it breaks | result |
|---|---|---|
| `S573_MUT_NO_KEY3_INC` | drops `key3++` in `decrypt_default` | **RED, 16/30 cases fail.** First divergence `two-word-def` **byte 2**: RTL `0x98`, C `0x67`. Byte 2 is the first byte of the *second* word — exactly right, key3 is consumed before it increments. The 14 passing cases are precisely the 14 `ddrsbm` cases, which do not use key3. |
| `S573_MUT_LOW_FIRST` | emits low byte before high | **RED, 30/30 fail** at **byte 0** (`min1word-def`: RTL `0x64`, C `0xfa`). |
| `S573_MUT_NO_2N1` | keeps the final word's low byte (2N, not 2N-1) | **RED, 30/30 fail** on **length**, every prefix identical (`min1word`: RTL 1 vs C 2; `big`: RTL 7999 vs C 8000). |

Clean build: exit 0. Mutated build: exit 1. The mutation's fault signature is specific and
correct in all three cases, so the harness is discriminating, not merely noisy.

---

## Performance

Measured with `./run_spike.py --bench --mib 64` (64 MiB buffer, best of 5 passes, output
byte count = 67,108,863):

| host | scheme | throughput | cycles / output byte |
|---|---|---|---|
| Apple M1 Pro (arm64, ~3.23 GHz, `cc -O2`) | `decrypt_default` | **429.5 MB/s** | ~7.5 |
| Apple M1 Pro | `decrypt_ddrsbm` | **707.4 MB/s** | ~4.6 |

Reproducible to ±0.3% across runs. `decrypt_default` is the number that matters (ddrsbm is one
game).

### Does it fit on the DE10-Nano's Cortex-A9? — yes, by three orders of magnitude

**These A9 figures are an ESTIMATE scaled from the measured M1 number, not a measurement on the
target.** Basis: the compiled hot loop is ~98 arm64 instructions per 16-bit word (2 output
bytes) — 87 for the word path, 11 for the buffered-low-byte pass — which the M1 retires in
~15 cycles/word (IPC ≈ 6.5). The Cyclone V HPS A9 is 2-wide **in-order** ARMv7 with 14 GPRs, so
assume IPC ≈ 1.2 and ~15% more instructions from spills: **~100–130 cycles/word**, i.e. a
ceiling around **12–16 MB/s** at 800 MHz.

Against that, the real stream is tiny:

| MP3 bitrate | stream rate | words/s | A9 cycles/s | share of one 800 MHz core |
|---|---|---|---|---|
| 128 kbps | 16 KB/s | 8,192 | ~0.9 M | **~0.11 %** |
| 320 kbps | 40 KB/s | 20,480 | ~2.3 M | **~0.29 %** |

Add the DDR3 read itself. `shmem_map()` opens `/dev/mem` with `O_SYNC`, so the mapping is
**uncached** — every 16-bit fetch is a full uncached round trip (~150–200 ns, no line fill, no
prefetch). At 320 kbps that is 20,480 × ~200 ns ≈ **4 ms/s ≈ 0.4 %** of wall time. Mitigation
if it ever matters: `memcpy` the scrambled window into a cached staging buffer in bulk and
descramble from there — the mirror image of what `mdplus.cpp` already does in the write
direction.

**Total worst case ≈ 0.7 % of one A9 core at 320 kbps** (≈ 0.3 % at 128 kbps).

**Against the ~5 ms MD+ poll loop** (`mdplus_poll()` gates on `now - last_poll < 5`): at
320 kbps a 5 ms slice needs 200 bytes = 100 words ≈ 12 µs of compute + ~20 µs of uncached read
stall ≈ **33 µs of a 5000 µs slice**. Chunking mdplus-style at `STREAM_CHUNK = 8192` bytes
would instead cost ~1.3 ms in one poll every ~200 ms of audio — still inside the slice, but
lumpy; **recommend 1–2 KB chunks (≈25–50 ms of audio) so no single poll exceeds ~300 µs.**

For scale: minimp3 decoding 128 kbps stereo on an A9 is on the order of 3–8 % of one core. The
descrambler adds roughly 5–10 % *on top of the decoder's own cost* — it is in the noise, and
minimp3, not the descrambler, is the thing to budget for.

---

## What this spike does NOT prove

1. **Visibility.** It proves the *algorithm* is portable. It does not prove the HPS mapping of
   the DIO sample-RAM window (`0x32000000..0x33FFFFFF`) sees the same bytes the fabric sees,
   with the right ordering, once the game is writing that window live. That is an HW check.
2. **Ownership.** The design doc's stated counter-argument stands untouched: moving descramble
   to the HPS moves stream position / `get_fpga_ctrl(0xae)` / DEMAND ownership with it, and
   `k573_mp3stream`'s reviewed P4a role has to be re-cut. This spike says nothing about that
   cost — it only removes the "but can C even reproduce the bytes?" risk.
3. **The last-word boundary is oracle-derived, not silicon-derived.** Both sides here implement
   MAME's 2N-1; if real DIO silicon emits 2N, both sides are wrong together. Flagged for P4c
   in `k573_mp3stream.v`'s header — unchanged by this spike.
