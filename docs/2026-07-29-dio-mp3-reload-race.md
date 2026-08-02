# k573dio MP3 re-arm race — one-cycle `mp3_reload` vs the register it describes (2026-07-29)

Found reviewing `45b09e8` (the k573_mp3stream enable-gating fix). **Pre-existing, not
introduced by that commit** — the same repro fails identically against `HEAD~2`'s
streamer. Fixed here; `sim/tb_dio_mp3_reload.v` is the guard.

## The defect

`rtl/k573dio.v` derived the stream re-arm pulse combinationally from the bus write:

```verilog
wire mp3_reload = sel && we && (off == 8'ha0 || off == 8'ha2 || ... );
```

The register that write updates lands **non-blocking on the same posedge**
(`8'ha2: mp3_start[15:0] <= din`), and `k573_mp3stream`'s re-init runs on that same edge:

```verilog
if (do_reinit) cur <= mp3_start;      // samples the PRE-write mp3_start
```

So `cur` re-armed to the **previous** song's address. Measured on the real k573dio bus,
ending the setup burst with the `0xa2` write:

```
after writes   mp3_start = 32   u_stream.cur = 0        <-- stale
```

MAME cannot have this: `k573dio.cpp` stores the register **first** and only then calls
`update_mp3_decode_state()`, so `mp3_cur_addr` always gets the new `mp3_start`.

**It is a last-write bug.** Any further setup write re-pulses `reload` and self-heals it,
and the reload list includes the three key registers — so it only bites when `a0` or `a2`
closes the burst. `a4/a6` (end) and `a8/ea/ec` (keys) closing the burst are harmless:
nothing in the re-init branch samples `mp3_end`, and `S_LOAD` latches the keys the cycle
*after* the pulse, by which point the key registers have updated.

Two distinct game-visible failures, depending on where the stale address falls:

| stale start vs the new window | symptom |
|---|---|
| inside `[start,end)` | streams the **wrong DRAM region** and runs long — garbage audio |
| outside `[start,end)` | never starts; `0xae` readback never reads `0x1000`, so the game's "is the song still playing" poll never goes true — a hung song |

## Why 45 tests missed it

- `tb_k573dio`'s streaming case sets `mp3_start = 0` — stale and correct are both 0 — and
  ends its burst on `0xa6`.
- `tb_k573_mp3stream` and `tb_k573_mp3stream_engate` drive the streamer's `reload` **port**
  directly, bypassing k573dio's pulse entirely.

Only a bench on the real register bus that ends the burst on a START write can see it.

## The fix

Register the pulse before it reaches the streamer, so the streamer samples post-write
values — the same ordering MAME gets from store-then-update:

```verilog
reg  mp3_reload_q = 1'b0;
always @(posedge clk) mp3_reload_q <= rst ? 1'b0 : mp3_reload;
wire mp3_reload_s = mp3_reload_q;      // -> .reload()
```

Pulse **count** is preserved (one per write, even back-to-back), so the `mp3_end`
extension re-arm that `tb_k573_mp3stream` phase 2 pins is unaffected — re-checked through
the bus as `tb_dio_mp3_reload` P4.

The decode-counter resets (`0xa8` frame count, `0xca/cc` sample counter, `0xce` diff)
deliberately stay on the **undelayed** pulse: they only zero counters, sample no register
value, and a counter cannot advance in the one cycle of skew.

`k573_mp3stream` is instantiated exactly once (in `k573dio`), so this is the whole blast
radius. No `emu.sv` / `system573_top` change; no port-list change.

## Verify

```
make -C sim                              # 46/46, ALL TESTS PASSED
make -C sim MP3_RELOAD_RACE=1 dio_mp3_reload   # RESULT: FAIL (4 errors) -- discriminator
```

`tb_dio_mp3_reload` drives the real k573dio bus: P1 `a2`-last (stale inside the window),
P2 `a0`-last (stale outside it), P3 the self-heal control that hid the bug, P4 the
`mp3_end`-extension control. P1/P2 discriminate; P3/P4 are green in both builds. An
anti-vacuity guard fails the bench if the decoy and intended DRAM regions ever descramble
to the same first byte.

## Reachability in a real game — UNCONFIRMED, and probably not reachable

Bounded dig; stating what was and was not established.

**What was checked.** Every ddrsbm memory dump we hold — `ddrsbm_psx_exe.bin` (the whole
847 KB game executable, text @ `0x80010000`), `gwait` (the DIO driver region
`0x800a8000+32K`), `gimg`, `gmain`, `code`, `bss`, `kram`, `kram2`, `verify` —
disassembled (capstone, MIPS32 LE) looking for stores to DIO offsets
`a0/a2/a4/a6/a8/ea/ec`.

**Result: zero.** The DIO driver in the main executable writes the board ID, the MAS3507D
I2C port (`0xac`), 1-Wire (`0xee`), and the network/`f4`/`f6`/`ba` registers via
`lui $at, 0x1f64` + `sh` — but never an MP3 setup register. The code that arms the MP3
stream is in a runtime-loaded module we have not dumped. `local/ddrsbm_dio_tap.log` is
boot-check-only (frame 207) and contains no setup burst either.

**The one real hint, and its limits.** The executable holds a 25-entry table of DIO
register addresses at `0x800197cc..0x8001982c`, unreferenced by any code in the dump —
almost certainly a literal pool. Its MP3 entries are grouped
`a0, a2, a4, a6` then `a0, a2, a8`: start-hi, start-lo, end-hi, end-lo — then start-hi,
start-lo, key1. Read as first-use order, both groups end on a **safe** register
(`0xa6`, `0xa8`), which is what you would expect from MAME-shaped code that sets the
window and then the keys. That is an inference from pool layout, **not** evidence of
execution order, and it is not tied to any code we can see.

**So: the fix is correct on its own terms — our pulse ordering differed from the hardware
model MAME implements — but no game has been shown to trigger it, and the pool hint leans
toward "not reachable in practice."** Settling it needs a DIO-window tap on ddrsbm driven
all the way to MP3 playback in MAME (attract-mode music would do); that has not been run.
Cheap to revisit when P4c puts a real song through the streamer.
