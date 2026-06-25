# Handoff — ddrsbm BOOT CHECK ROOT CAUSE FOUND: IDENTIFY data-ready IRQ races the driver (2026-06-25)

Branch: `feat-digital-bringup` (probe work on `dbg-signaltap-atapi-irq`, HEAD `fd9f912`).
Supersedes `docs/2026-06-24-ddrsbm-bootcheck-handoff.md` (its "confirm the IRQ drop" framing was WRONG).

## ★ THE FIX (for the next session / stream) — write it, build, test
**`rtl/atapi.v` raises the IDENTIFY (and fixed-response data-in) data-ready IRQ IMMEDIATELY on the
command write, before ddrsbm's IRQ-driven driver sets up the transfer. Add a settle delay so the
IRQ fires AFTER the driver is ready** (mirror the `S_FETCH`/`FETCH_SETTLE`/`PACE_CLKS` pacing that
disc READ(10/12) already uses, atapi.v:88-89,580-603).

Concretely: the IDENTIFY case (atapi.v:454-461) does `r_status<=DRDY|DRQ; irq_pending<=1;
irq_event<=1; state<=S_DATAIN` in the SAME cycle as the `0xA1` write. So does every fixed-response
data-in command (INQUIRY 0x12 @329, REQUEST SENSE 0x03 @340, READ CAPACITY 0x25 @334, MODE SENSE
0x5A @357, and the TOC data phase @567). Route these through a short BSY settle (status=ST_BSY for
N clk1x, DRQ+INTRQ only after) instead of firing INTRQ instantly. Start N around a few hundred clk1x
(enough for the driver's "set the transfer-pending state byte" instructions after the command write;
the real CR-589 data-prep latency is much longer, so there is wide margin). Keep DRQ reachable by
polling so powyakex/hypbbc2p (which POLL, never use the IRQ) still pass — verify `tb_atapi`,
`tb_drivecheck`, `tb_atapi_cdread`, `tb_irqdeliver` + a de10 regress of both polling games.

## The proof chain (on-silicon SignalTap, all numbers, captures in `local/signaltap/20260624_*`)
1. **IRQ delivery WORKS** (v1, all-register probe): `atapi irq_out` asserts → `I_STATUS[10]` latches
   → `I_MASK=0x409` (VBLANK+DMA+IRQ10 enabled) → CPU takes the IRQ10 `exception[4]` (I_STATUS=0x400,
   IRQ10 the only pending source). So "device never asserts" + "never latched" are RULED OUT.
2. **The stalling event is the IDENTIFY read** (v2, PC+drain probe): byte count `0x0200` (512) =
   the only command in atapi.v that sets bchi=0x02 → IDENTIFY PACKET DEVICE (0xA1, atapi.v:455-456).
3. **The 512-byte IDENTIFY NEVER drains**: `ridx` stuck at 0 across the whole buffer, `r_status`
   stuck at `0x48` (DRDY|DRQ), the data phase never completes.
4. **The handler runs but SKIPS the drain** (v2 RECON=pc, trigger PC==0x803cb2dc): the PC trace
   walks `803cb2dc → 803cb304 (read reg7, INTRQ ack) → 803cb35c (dispatch on the SW transfer-pending
   state byte @struct+0x11df) → 803cb360..36c → 803cb4a8 (EXIT)`. It takes the **state==0 / skip-to-
   exit** branch and NEVER reaches the PIO drain loop `0x803cb284`. So the handler reads status,
   acks, and exits without transferring the data — because the dispatch state byte is 0.
5. **MAME reads this data via PIO, not DMA** (`/tmp/ddrsbm_ident_dma.lua` on dell: 1193 reg0 PIO
   reads, 0 ch5-CHCR DMA arms). So ddrsbm PIO-reads the IDENTIFY; the bug is NOT the DMA path.
6. **Why state byte == 0 = the RACE**: atapi.v fires INTRQ on the `0xA1` write; the driver sets the
   transfer-pending byte in the instructions AFTER the write. Our instant IRQ is taken/handled
   before the driver gets there → handler sees state 0 → skips drain → DRQ stuck → drive check times
   out (bounded wait 0x803cb010/0x803cb104, watchdog at 0x1f5c0000) → retry → BOOT CHECK.

## RULED OUT / LATENT (don't chase)
- IDENTIFY *content* (commit `76f0274`, exact CR-589) — correct but irrelevant: the data is never
  read because the drain is skipped. Keep the commit.
- The "IRQ is dropped / not latched / not taken" hypothesis (the prior handoff) — DISPROVEN on silicon.
- **LATENT (real, but NOT ddrsbm's gate):** atapi.v's DMA drain is gated to disc reads only
  (`data_consume = ... || (dma_rd && datain_disc)` @278; `dma_dout` serves only disc data @630). A
  game that DMAs a non-disc data-in command (IDENTIFY/INQUIRY/TOC) would get no drain + wrong data.
  ddrsbm uses PIO so it doesn't hit this, but fix it too when convenient (extend the DMA path to
  datain_ident/datain_toc/resp_byte sources + assert dma_req for them).

## Tools / probe (reusable; RUNBOOK = tools/signaltap_573/RUNBOOK.md)
- Generators: `atapi_irq_stp.tcl` (v1, 66-bit IRQ chain) + `atapi_irq2_stp.tcl` (v2, 82-bit: adds
  `cpu:icpu|PC[31:0]` + `atapi ridx` + byte count). All-register (PRESERVE_REGISTER), clk2x cap,
  depth 8192, qualifier `ce`. RECON modes: `any`/`gate`/`istat10`/`irqout` (v1); `pc` (PC-match
  trigger, default 0x803cb2dc)/`drain`/`irqout` (v2). Regenerate the .stp to retune the trigger —
  NO rebuild (all nodes are trigger inputs); restage as `dell:.../atapi_irq.stp`.
- Capture: `capture_atapi.sh <timeout>` (arms via dell JTAG, exports CSV to local/signaltap/<ts>/).
- Decode: `read_atapi_csv.py` (IRQ-chain a/b/c verdict) + `read_atapi_pc.py` (PC region histogram +
  drain check) + the generic `read_stp_csv.py` (info/hist/dump/edges/audit). NOTE: `state[2:0]` ties
  to GND in the build (FSM re-encoding -> PRESERVE_REGISTER ignored, Warning 12069, benign — infer
  state from r_status/r_ireason); `PC[31:0]` preserves CLEAN.
- The instrumented v2 rbf is on the de10 now (`_Console/Konami_System_573.rbf`, md5 4b4c8583).
  Restore the production core before non-debug work.
- De-confounded HW test: `devlock de10 reboot 573`; wait uptime<60s; re-acquire devlock; ONE
  `load_core` of the ddrsbm .mgl; arm capture within a few s (the drive check is early, ~T+20-40s,
  and it stops retrying once it gives up). MAME on dell: `mame ddrsbm -rompath 'dumps/mame573;dumps'
  -video none -sound none -nothrottle -seconds_to_run N -autoboot_script /tmp/x.lua`.

## Memory pointers
[[fabricore-573-digital-bringup]] (updated), [[no-mask-fault-with-fake-data]], the MAME handler
disasm is in this session's transcript (handler map: 0x803cb2dc entry, 0x803cb304 reg7 read,
0x803cb35c state-byte dispatch, 0x803cb284 PIO drain, 0x803cddb8 ch5 DMA, 0x803cb4a8 exit).
