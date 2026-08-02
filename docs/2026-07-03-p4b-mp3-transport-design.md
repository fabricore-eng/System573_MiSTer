# P4b(b) — HPS↔FPGA MP3 byte/PCM transport design — 2026-07-03

Design pass for the ddrsbm `ready`-loop unblock: the transport that carries **descrambled
MP3 bytes FPGA→HPS** and **decoded PCM HPS→FPGA**, so the P4b(a) decode counters (already
built + sim-proven, commit `cde2c6b`, currently reading a truthful zero because their inputs
are tied `1'b0` at `rtl/emu.sv`) can be driven from real decode.

Produced by an Understand→Design→Verify workflow (5 parallel subsystem readers → synthesis →
adversarial verify). Grounded in the RTL (read directly) + `Main_MiSTer` (cloned at
`~/Dev/fabricore/Main_MiSTer`). Supersedes the transport-open parts of
`docs/audits/2026-06-12-ddr-feasibility.md` §1/§4-Phase-C. Memory:
`[[fabricore-573-digital-bringup]]`, `[[f2sdram-bridge-placement-marginal]]`,
`[[no-mask-fault-with-fake-data]]`, `[[ddr-bringup-plan]]`.

## TL;DR — the decision

**Two DDR3 ring buffers in the DIO 32 MiB window, serviced by a forked-Main poll-hook
(`support/s573/`) gated on the core name, with ring pointers exchanged over the EXT_BUS SPI
sideband (never through DDR3).** Adversarially CONFIRMED sound (doctrine PASS). It is a
near-verbatim clone of the **shipping MegaDrive MD+ CDDA path** (`Main_MiSTer/support/
megadrive/mdplus.cpp`: `shmem_map(0x30000000)` DDR3 ring + `CMD_MDP_AUDIO` SPI pointer
exchange + core-name-gated `mdplus_poll()`) — so ring coherence, lifecycle, and deploy are
solved precedent, **refuting** the earlier audit's "no upstream HPS→core PCM template".

- **MP3-byte ring** (fabric→HPS): fabric writes descrambled bytes via the existing
  `s573_ddram_arb` DIO *write* channel; HPS mmaps + feeds minimp3. *(Candidate for
  elimination — see "Open decision B".)*
- **PCM ring** (HPS→fabric): HPS memcpys decoded 16-bit stereo PCM in; fabric reads via the
  DIO *read* channel into a small on-fabric BRAM elastic buffer, **drains at 44100 Hz** into a
  new `AUDIO_L/R` mixer, and emits `pcm_sample_tick` per real drained sample.
- **Pointers ride EXT_BUS SPI, not DDR3** → coherence is safe across the placement-marginal
  f2sdram bridge (the bridge carries bulk payload only; `dio_wr_ack` orders each payload write
  before its pointer is advertised).
- **Reuses the existing DIO arb client** → NO new f2sdram port, NO new placement pressure.
  *(2026-07-15 wire-up amendment: "no placement pressure" was overstated — the 2-client read
  mux initially put a live 2:1 addr mux in series into the arb's combinational DDRAM_ADDR
  cone; the after-review hardening registers the granted address at the grant edge, restoring
  the pre-mux single-register-bank cone shape. And "nothing changes" holds for VALUES only:
  every existing DIO-RAM read now pays +1 clk_1x cycle (~30 ns) of grant latency through the
  mux — accepted; do not chase it with a combinational idle-bypass, that re-adds logic depth
  in the bridge cone for zero functional gain.)*

### Options scored
| Option | Score | Verdict |
|---|---|---|
| **DDR3 dual-ring + forked-Main poll-hook** | **9** | CHOSEN — highest precedent (MD+), lowest novel surface, cleanest lifecycle (dies with the Main process on core unload). |
| DDR3 dual-ring + standalone daemon | 5 | Transport-equal but FATAL on lifecycle (no clean unload signal; keeps mmap'ing into the next core) + zero precedent, for no deploy saving. |
| SPI-FIO push (Neo Geo CD / MSU-1) + forked-Main | 6 | Best f2sdram-risk profile (PCM off the bridge) + proven DOWN leg, but the fabric→HPS byte UP leg has NO SPI template → re-introduces novel code. **Viable fallback if the PCM ring wedges the bridge on HW.** |

## DDR3 memory map (parameterized — addresses provisional, see must-fix #2)
All ring memory lives inside the existing DIO window `0x32000000..0x33FFFFFF` (fabric via
`s573_ddram_arb`, HPS via `mmap(/dev/mem)`). **Do NOT use `0x34000000`** — it collides with
PSX rewind (`+128M`) / savestate (`+224M`) inside the psx `0x30000000..0x3FFFFFFF` span.
Carve from the TOP of the DIO window (game sample-RAM lives low, where POST MEMORY CHECK
sweeps):

- **MP3-byte ring** (fabric→HPS): base `0x33F00000`, 64 KiB, via the DIO 16-bit posted-write.
- **PCM ring** (HPS→fabric): base `0x33F10000`, **depth a PARAMETER** (256 KiB ≈ 0.74 s was the
  strawman; must stay tunable — see must-fix #4), via the DIO 64-bit read (1 beat = 2 stereo
  pairs).

mmap contract (from `tools/mister_vram_dump.sh` + Main `shmem.cpp`):
`open("/dev/mem",O_RDWR|O_SYNC|O_CLOEXEC)` → `mmap(0,size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,
phys)`; phys is 1:1; pointer MUST be `volatile` (uncached, fabric mutates underneath); **mmap
ONLY, never `read()`/`dd`** (STRICT_DEVMEM zeroes `read()` here but allows mmap). FPGA beat
index = `phys>>3` (`DIO_BASE_BEAT = 0x32000000>>3`). Little-endian native.

## Fabric side (b1) — signal-level, all in `clk_1x`
1. **MP3-byte ring writer** (beside the k573dio backing): consume the `k573_mp3stream` producer
   (`out_valid`/`out_byte`/`out_ready`) — assert `out_ready = ring_not_full`, latch on accept,
   advance `fab_wr_ptr`. `ring_not_full = ((hps_rd_ptr - fab_wr_ptr - 1) & MASK) != 0`. NEVER
   free-run `out_ready` (that IS the demand model). Preserve byte order (no re-swap); tolerate
   the 2N−1 last-byte quirk; on `mp3_reload` reset `fab_wr_ptr` + bump a monotonic **epoch**
   (see must-fix #1).
2. **PCM ring reader + 44100 drain** (the `pcm_sample_tick` source): burst-read the PCM ring
   into an on-fabric BRAM elastic buffer (≥512 stereo samples); a **fractional accumulator**
   (`acc += 44100; if acc>=33_868_800 { acc-=…; pcm_ce=1 }`, one `pcm_ce` per ~768 `clk_1x`)
   gates the drain. On each `pcm_ce`: if BRAM non-empty → pop one stereo sample, register into
   `mp3_pcm_l/r`, assert `dio_pcm_sample_tick` for **exactly 1 cycle** (advance the counter by
   EXACTLY 1 — never batch +1152, or the 0xcc low-word latch aliases). No CDC on the tick (the
   counter block is clk_1x).
3. **Underrun** (BRAM empty at `pcm_ce`): drive `mp3_pcm_l/r=0` (honest silence on the MP3
   channel only; SPU passes through), do NOT pop, do NOT tick (counter FREEZES truthfully),
   increment a saturating `mp3_underrun_cnt` (DEBUG-gated per CLAUDE.md #6; on SignalTap + the
   SPI mailbox). NEVER replay-last-sample / zero-fill-AND-tick / free-running clock.
4. **Audio mixer** (replaces the bare `assign` at `rtl/emu.sv:1520-1521`): route SPU→`spu_l/r`,
   saturating 17-bit signed add with `mp3_pcm_l/r`, clamp to `[-32768,32767]`. `AUDIO_S=1`.
5. **EXT_BUS SPI mailbox** (extend the `hps_ext` stub at `emu.sv:724`, mirror MD+
   `CMD_MDP_AUDIO`): `CMD_573_PTRS` exchanges `{fab_wr_ptr, fab_pcm_rd}`↑ / `{hps_byte_rd_ptr,
   hps_pcm_wr}`↓; `CMD_573_STATUS` carries `{epoch, cfg_ddrsbm echo, underrun_cnt, mpeg
   flags}`. Use **sample-granular** PCM pointers so each fits one 16-bit SPI word (must-fix #3).
6. **`dec_frame_sync`/`dec_frame_idle`**: 1-cyc clk_1x pulses carried from the HPS per decoded
   frame / per no-frame decode, toggle-synchronized and edge-reduced to exactly 1 cycle (a wide
   strobe multi-counts 0xa8). Do NOT derive frame-sync by counting 1152 ticks (VBR breaks it).

## HPS side (b2) — forked Main `support/s573/s573mp3.cpp` (cloned from `mdplus.cpp`)
- **Lifecycle:** gate on `user_io_get_core_name(1) == "Konami_System_573"` at the top of
  `s573mp3_poll()`; register it in `user_io_poll()` next to `mdplus_poll()`/`psx_poll()` behind
  an `is_573()` helper (mirror `is_psx()`). Init on first poll after load: mmap both rings,
  zero the PCM ring, reset cursors. **No explicit teardown** — core unload is a full Main
  process teardown (`fpga_io.cpp:app_restart` fork/execl), so the service dies with the core.
- **Decode loop** (~5 ms throttle like MD+, or a CPU-pinned `offload.cpp` worker if poll jitter
  starves the drain): exchange pointers over SPI; on epoch change flush + `mp3dec_init`; drain
  bytes into a sliding window (≥~1441 B lookahead so a frame never splits); `mp3dec_decode_
  frame()` loop; push interleaved int16 PCM into the PCM ring respecting free space; emit
  `dec_frame_sync` per frame / `dec_frame_idle` on stall/EOF. The bytes are **already
  descrambled in fabric** → minimp3 sees ordinary MPEG-1 L3; `cfg_ddrsbm` is fabric-side
  descramble-select only (forward as metadata, don't touch the decoder).
- **minimp3:** vendor `lib/minimp3.h` (single-header, `MINIMP3_IMPLEMENTATION`), same style as
  `lib/libchdr`. `mp3d_sample_t` = int16 interleaved; expect `hz=44100 channels=2` for ddrsbm.
- **Deploy:** today `tools/mister_load.sh` pushes only the `.rbf`. This adds a **custom MiSTer
  ARM binary** as a second artifact (build via `build.sh`). → **Open decision A.**

## Driver plan (b3) — replace the five `1'b0` ties at `emu.sv:2236,2243-2245` (+ `cfg_ddrsbm` ~2142)
The HPS never drives these RTL inputs directly — it drives them THROUGH the rings + SPI
mailbox, and the fabric converts ring/drain state into 1-cyc strobes:
`dio_mp3_ready = mp3_ring_not_full`; `dio_mp3_byte/valid` now CONSUMED by the writer;
`dio_pcm_sample_tick = pcm_drain_tick` (the load-bearing, PCM-drain-only signal);
`dio_dec_frame_sync/idle` toggle-sync'd from HPS events; `cfg_ddrsbm` per-game from the SPI
mailbox (HPS knows the mounted game) or a core-config bit, stable before/while streaming.

## Must-fix BEFORE writing the affected RTL (from the adversarial verify)
1. **Reload/epoch atomic handshake** (the one unprecedented, highest-risk piece — MD+ has no
   seek-mid-stream analog): on `mp3_reload`, latch a **monotonic epoch counter** (NOT a sticky
   bit — two reloads between polls would be missed), reset `fab_wr_ptr`, and expose
   `{epoch, fab_wr_ptr}` in the SAME SPI exchange so the HPS reads a consistent pair; HPS treats
   any epoch change as: discard un-decoded bytes, `mp3dec_init`, re-baseline its read cursor;
   fabric must not overwrite past the HPS's last ack until the epoch is exchanged (or the ring
   is drained) so a fast HPS never splices two epochs. *Define this before the byte-ring writer.*
2. **Ring placement vs ddrsbm sample-RAM:** confirm `0x33F00000/0x33F10000` (top 320 KiB) is
   clear of ddrsbm's actual top-of-window usage on HW **before** baking address constants (into
   both fabric decode and HPS mmap) — wrong = silent live-data corruption.
3. **SPI pointer encoding:** use **sample-granular** pointers for the PCM ring so each fits one
   16-bit SPI word (a 256 KiB byte pointer does not — MD+'s single-word `spi_w(wr_ptr)` assumes
   ≤64 KiB). Or spec a two-word exchange explicitly.
4. **PCM ring depth = a PARAMETER**, not fixed 256 KiB: the `ready`-loop reads 0xca/cc as timing
   feedback, so ~0.74 s of ring latency is a rhythm-game variable — keep it tunable so HW step 8
   can dial the latency/underrun-margin trade.
- Enforce in RTL (not a violation, a caveat): keep a transient BRAM underrun DISTINCT from
  `dec_frame_idle` (mpeg IDLE = song ended). Never conflate momentary buffer-empty with IDLE.

## Ranked risks (all HW/counter-state verified — no MP3 sim/MAME oracle)
1. **f2sdram bridge marginality** (medium; re-rolls on rebuild) — bandwidth is NOT tight
   (176 KB/s vs a deep ring, ~3 orders of slack); residual risk is a placement re-roll → wedge,
   presenting as rising `mp3_underrun_cnt` (watch on SignalTap; re-verify every rbf).
2. **Reload/epoch ordering** (high) — see must-fix #1.
3. **Reload/song-boundary splice** (verify epoch round-trip on HW: force a song change).
4. **`dec_frame_sync` CDC multi-count** (edge-reduce to 1 cycle; sim-check 0xa8 +1/frame).
5. **`cfg_ddrsbm` wrong per game** (mpeg IDLE / zero frame-sync on HW ⇒ wrong scheme).
6. **Custom Main binary drift/deploy** (a stale binary silently disables MP3 — log the core
   gate hit; 0xa8 advancing on HW proves the HPS half is live).

## Implementation order — fabric-first, sim-provable before HW
1. *(fabric, sim)* MP3-byte ring writer + `ring_not_full` backpressure — fake HPS reader
   advancing `hps_rd_ptr`; assert `out_ready==ring_not_full`, byte order, 2N−1, reload→epoch.
   **← gated by the Open-decision-B spike (may be eliminated).**
2. **★ RECOMMENDED FIRST SLICE (fabric, sim, model-INDEPENDENT):** PCM-ring reader + BRAM
   elastic buffer + 44100 fractional drain + `pcm_sample_tick` + underrun suppression +
   `mp3_underrun_cnt`. Bench with the REAL k573dio counter block: prefill→exactly 1 tick/pop +
   monotonic +1 + 0xcc/0xca latch coherent; starve→silence + NO tick + counter FREEZES +
   `underrun_cnt`++ (no-mask verified in sim). **De-risks the single load-bearing signal;
   needed in every option.**
3. *(fabric, sim)* saturating 17-bit `AUDIO_L/R` mixer at `emu.sv:1520-1521` (clamp vectors).
4. *(fabric, sim)* extend `hps_ext`/EXT_BUS with `CMD_573_PTRS`/`CMD_573_STATUS`; loopback bench.
5. *(wire-up)* replace the five `emu.sv` `1'b0` ties + `cfg_ddrsbm`; whole-core elaboration +
   suite **38/38** stays green (counters still read truthful zero until the HPS half exists).
6. *(HPS, HW-only)* vendor `lib/minimp3.h`; write `support/s573/s573mp3.cpp`; build forked Main.
7. *(HW loopback — a byte-level oracle DOES exist)* mmap-read the byte ring, compare a captured
   window against MAME's descrambled bytes for the same game; confirm 0xa8/0xca-cc advance.
8. *(HW end-to-end, P4c)* run ddrsbm: `underrun_cnt`==0 across a song (SignalTap), 0xca/cc
   `get_counter/44100` tracks wall-clock, audio present, gameplay advances past `ready`.

## Open decisions
- **A — deploy/release model. DECIDED 2026-07-29: YES, FORK.** Accepted by the human: the core
  ships a **forked/side-loaded `Main_MiSTer` ARM binary** as a second deploy artifact (rebased
  on upstream, our code under `support/s573/`). Every option that runs HPS C needs a custom
  binary and the fork scores best on lifecycle — it dies with the core, because core unload is
  a full Main process teardown. Consequences now in scope: `tools/mister_load.sh` grows a
  second scp; the binary is **system-wide**, not per-core, so it must stay rebased on upstream
  and must not regress other cores; and design risk #6 (stale binary silently disables MP3)
  becomes real — log the core-name gate hit, and treat `0xa8` advancing on HW as the proof the
  HPS half is actually live.
- **B — DECIDED 2026-07-29: YES, in the option-(c) shape.** The spike proved the descramble
  ports to C bit-exactly (31/31 cases, 45,377 bytes; `sim/spike_b_descramble/`), so the byte
  ring, its epoch handshake and the write-side arb mux are all deleted. But NOT literal B:
  `0xae` bit12 is a START/STOP idempotence guard in the game, so a constant breaks one path
  either way — `k573_mp3stream` therefore STAYS as an HPS-credit-paced position tracker. Full
  reasoning + the disassembly: `docs/2026-07-29-p4b-decision-b-spike-result.md`. Fabric side
  landed in three slices (`f39ab2a`, `06f0e6a`, `6422625`).
  *Original framing, kept for context:* have the HPS mmap-read the **already-in-DDR
  scrambled** stream and do **descramble+minimp3 on the HPS** (algorithm is known/portable from
  `k573_mp3dec.v`/MAME). If faithful, it deletes the byte-ring writer + its epoch handshake (the
  highest-risk piece) and makes the fabric **consumer-only** (exact MD+ shape). Trade-off it
  under-weights: it shifts stream position/`get_fpga_ctrl`(0xae)/DEMAND ownership to the HPS,
  disturbing the already-reviewed P4a `k573_mp3stream` role. **Run this spike before building
  step 1.** Does NOT gate step 2.
- **C — `cfg_ddrsbm` source:** SPI mailbox (HPS knows the mounted game) vs a core-config/ioctl
  bit; confirm the per-game ddrsbm=0/1 table.
- **D — pre-authorize the SPI-FIO fallback** (Neo Geo CD/MSU-1, PCM off the bridge) if HW step 8
  shows the PCM ring wedges the marginal bridge irrecoverably, or gate it on a human call?
