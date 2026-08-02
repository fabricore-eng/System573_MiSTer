# RESULT — gate 5: the CDROM-timeout RED bench (2026-07-03, build-free)

Follows `docs/2026-07-02-gate5-cdrom-timeout-observation.md` (the observed verdict +
fix directions). This is the **next measurement** that doc called for: a sim RED
bench that reproduces the gate-5 stall offline. Memory: `[[fabricore-573-digital-bringup]]`.

## What was built

`sim/tb_gate5_replay.v` (+ the `gate5_replay` target in `sim/Makefile`) replays the
MAME oracle ATA workload (`local/g5_mame_oracle/g5_ata_e.log`, exact LBAs/lengths/CDBs)
against the silicon-proven `atapi.v` + `s573_cdimg.v` + `s573_cdtoc.v`, and asserts —
for every command — **bounded completion + served data == commanded LBA**.

- `make -C sim gate5_replay` → **RED** (RESULT: FAIL, 1033 errors) against current RTL.
- `make -C sim` → the 38-test suite stays **GREEN** (gate5_replay is a standalone
  RED/GREEN gate, NOT in `TESTS`).
- `make -C sim GATE5_FIX=1 gate5_replay` → the ide_rst→cdimg wire preview (closes
  sub-tests [C]/[D]; [B] STOP UNIT still needs the atapi fix → 6 errors remain).

Sub-tests (each asserts bounded completion + LBA-correct data):

| # | scenario | current RTL | under the fix |
|---|---|---|---|
| A | re-init bundle + swept-latency (fast→ms-slow) len=64 READ storm + BSY data-ready gate | GREEN | GREEN |
| B | per-song ritual VERBATIM: READ12 lba 2086/862/42911 len 1/57/450 (real garbage CDBs) + **STOP UNIT(0x1b) ×2** | **RED** — CHECK CONDITION (`status=41`) vs GOOD | GREEN |
| C | **recovery ritual**: wedge a fetch mid-stream, `ide_rst` + re-issue the identical READ ×3 | **RED** — READ never recovers across 3 drive resets (the `-1N` stall) | GREEN (recovers attempt 1) |
| D | stale-sector: abort LBA X mid-request, re-issue LBA Y | **RED** — serves X's buffer as Y (`4140` vs `b2b1`) | GREEN (serves Y) |

## Why the RED is the real defect (not a bench artifact)

Proven RED↔defect↔GREEN by compiling the SAME bench three ways (build-free):
1. current RTL → RED (the three defect classes above).
2. `-DGATE5_FIX` (wires `cdimg_rst = rst|ide_rst`, the top-level fix) → [C]/[D] flip
   GREEN, only [B]'s 6 STOP-UNIT errors remain.
3. `-DGATE5_FIX` + a scratch `atapi.v` with STOP UNIT(0x1b) as a GOOD no-op → **PASS**.

So the bench is genuinely red against the current RTL and green **only** under the full
documented fix (wire `ide_rst`→`s573_cdimg` + STOP UNIT as GOOD). Each RED maps to a
specific audited defect:
- **[B]** — `atapi.v:431` default arm answers CHECK CONDITION for 0x1b (the only opcode
  in the whole 10-min workload that isn't handled); MAME/CR-589 answer GOOD.
- **[C]** — `ide_rst` resets atapi (`atapi.v:293`) but NOT `s573_cdimg`
  (`system573_top.v:278-285`); cdimg samples `sec_req` only in S_IDLE
  (`s573_cdimg.v:94`), so a fetch wedged in S_STREAM survives every drive reset and
  drops every re-issued request → `atapi.v:611` S_FETCH holds BSY forever → driver
  status −10 forever → the observed screen.
- **[D]** — `sec_ready` is untagged (`s573_cdimg.v:120`): a wedged fetch's buffer is
  served as a later, different LBA. (The `ide_rst`→cdimg wire also closes this by
  resetting cdimg on the game's abort.)

## Doctrine + adversarial review

The host BFM is doctrine-clean (LESSONS.md #1): the stall is an **honest injected
environment fault** (a transient HPS/f2sdram wedge — the host truncates a sector and
stops emitting `cd_wr`; no zero-fill, no synthetic `sec_ready`, no fabricated
completion), and the RTL's job is to recover from it via `ide_rst`. Removing the host's
`ide_rst`-abort leaves the RED identical — the defect lives in the RTL, not the bench.

A 4-lane adversarial review (faithfulness / doctrine / false-RED-or-GREEN / verilog)
returned all lanes **sound, 0 material findings**. The one real robustness gap it
surfaced (sub-tests [C]/[D] gated their data/LBA check behind the DRQ bit, so a
hypothetical "complete-without-a-data-phase" RTL could slip past) was **fixed**: [C]
now requires a real data phase + LBA-correct drain + good completion (a bare completion
counts an error), and [D] fails loud if the re-issue produces no data phase. Faithfulness
was also tightened: the ritual reads now replay the real garbage CDBs, and the re-init
bundle (workload part (a)) is interleaved with the storm.

## Next (the FIX — NOT done here, deliberately)

Per the observation doc + this bench's GREEN preview, the fix (touches silicon-proven
RTL → needs the full regression battery: install-golden md5 + powyakex + hyperbbc):
1. wire `ide_rst` → `s573_cdimg` reset (`system573_top.v`);
2. implement STOP UNIT (0x1b) in `atapi.v` as a GOOD non-data completion;
3. (defense-in-depth) LBA-tag `sec_ready` + accept `sec_req` outside S_IDLE.

Then build via the hub launcher, deploy, and verify the cold ddrsbm boot survives past
the old ~40 s attract death window.

## Artifacts
- `sim/tb_gate5_replay.v`, `sim/Makefile` (`gate5_replay` target + `GATE5_FIX` knob).
- Review workflow: `wf_52bfb428-de5` (4 review lanes + verify, ~347k tokens, all sound).
