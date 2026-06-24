# Handoff — ddrsbm BOOT CHECK (ATAPI completion-IRQ) + powyakex parked (2026-06-24)

Branch: `feat-digital-bringup`. Written for a fresh session to resume without re-deriving.

## ★ RESUME HERE — the ONE next action
**SignalTap the de10 to confirm the ATAPI completion-IRQ delivery during ddrsbm's drive check.**
Tap: `atapi_intrq` (= `atapi.v` `irq_out`, system573_top:284 `cdrom_irq`), the PSX `I_STATUS` bit 10
(inside `psx/rtl/irq.vhd`), and the PSX `ce`. Run ddrsbm, watch the drive check. The capture answers
in one shot whether the completion IRQ (a) asserts, (b) latches into `I_STATUS`, (c) is handled
(host acks bit10). Use the `fabricore:signaltap` skill. Static analysis CANNOT resolve this (below).

## The bug
ddrsbm (DDR Solo Bass Mix, GQ894 digital 573) boots but STALLS at a static **"BOOT CHECK"** screen on
the de10 (capture: `local/ddrsbm_de10_c.png`). MAME (oracle, dell) passes it → "INITIALIZE FLASH-ROM"
(`local/mame_ddrsbm.png`). It's the CD/ATAPI **drive check**.

## Gate pinned (high confidence, from disassembly of `local/ddrsbm_code.bin`)
ddrsbm's drive-check driver (`0x803cba40`) issues an ATAPI **PACKET** command (CDB = all-zero =
**TEST UNIT READY**): drive-select 0xA0→offset 0xC, feat0→0x2, byte-count 0x800, PACKET cmd 0xA0→**0xE**,
wait-DRQ (`0x803cb104`, checks `(status&0x88)==0x08`), write 12-byte CDB→data port (`0x803cb258`),
then **completion-wait `0x803cb4b8` which is INTERRUPT-DRIVEN** — it snapshots a counter
(`[0x803d2284]=[0x803d2280]`) before the CDB and spins until they differ, i.e. until the **IRQ10
handler bumps the counter**. If no IRQ → timeout → retry → BOOT CHECK (watchdog pet at `0x1f5c0000`).
**powyakex/hypbbc2p POLL status for completion → they pass; ddrsbm needs the IRQ → it's the only one
that trips.** That asymmetry is the key insight.

IRQ path: `atapi.v irq_out` (FREE-RUNNING clk1x) → system573_top:284 `cdrom_irq` → emu.sv:2183
`exp_irq10` → `psx/rtl/irq.vhd:127` `I_STATUSNew or (irqIn and not irqIn_1)` = a **ce-GATED rising-edge
detect**. **Static result (important):** that latch can only miss a *re-arm-collision glitch*
(`atapi.v:304-305`, a 1-clk low between back-to-back IRQs landing in a `ce=0` window) — a SINGLE
held-high completion IRQ IS caught. So TEST-UNIT-READY's single IRQ *should* be delivered. Unresolved
runtime question (→ SignalTap): (a) a multi-IRQ data-in command hits the collision miss, OR (b) the IRQ
is caught but the handler doesn't run (I_MASK/timing), OR (c) the completion-wait read is incomplete.
A blind IRQ fix is a guess — confirm first (no-mask/verify doctrine).

## RULED OUT this session (do NOT re-try)
1. **IDENTIFY content** — built exact CR-589 values (word0 0x8500, fw "1.0 ") = commit `76f0274`,
   deployed, HW-tested → STILL BOOT CHECK. Kept (correct-on-merits), NOT the gate.
2. **ATA address decode** — a workflow proposed remapping offset 0xC→reg7; its own adversarial-verify
   REFUTED it by disasm: the command 0xA0 is at **0xE** (existing `exp1_addr[3:1]` decode → reg7 is
   correct + dispatches); the 0xA0 at 0xC is the *drive-select* (the two identical bytes were conflated).
   Would have broken `tb_drivecheck`+powyakex+hypbbc2p. DO NOT apply.
3. **CDB-dispatch hang** — `atapi.v` handles TEST UNIT READY (line 319), INQUIRY, etc.; unsupported CDBs
   return CHECK CONDITION (line 419). Every path completes with an IRQ. So it's not a missing CDB.

## ⚠️ Trust the disassembly, NOT the runtime trace
`local/ddrsbm_ata.txt` (the ATA bus trace) MISLABELED offsets (it showed 0xC not 0xE for the command,
and never 0xE) — it was a MAME-internal port index, not the 573 bus offset. The capstone disasm of
`local/ddrsbm_code.bin` (base 0x803c0000) is authoritative. de10 band `idecmd_seen` (0x0e probe) also
confirms cmd@0xE.

## Env / setup state (already wired)
- **Cockpit progress** (tools commit d79d526): builds **self-scrape**; workflows →
  `tools/wf_cockpit_progress.sh --key 573 &`; runs → `tools/with_progress.sh "<label>" -- <cmd>`
  (+ `tools/fab_beat.sh <pct> <eta_s> "<detail>"`). 573 card has a status chip + up-next queue set.
- **Hub chat**: `/fabricore:group-chat on`, key `573`. Re-arm the watcher after every wake.
  (Human's only token concern was chat burn — keep wakes terse; engineering work/builds/workflows are fine.)
- **Live MAME view**: `vnc://dell.local:5900` (password `mame573`); launcher `~/mame_vnc.sh <romset>` on
  dell (+ `tools/mame_vnc_dell.sh` in repo). TigerVNC Xvnc; bound LAN+VncAuth (not localhost — macOS
  Screen Sharing refuses self).
- MAME runs on **dell** (`cd ~/System573_MiSTer; mame ddrsbm -rompath 'dumps/mame573;dumps' -video none
  -sound none -nothrottle -seconds_to_run N -autoboot_script /tmp/x.lua`). capstone on the **Mac**.

## Build / deploy / de-confounded HW test recipe
1. Build: `DELL_PROJECT=573 DELL_TARGET=Konami_System_573 DELL_REPO=System573_MiSTer ~/Dev/fabricore/tools/tools/dell_build.sh feat-digital-bringup` (~37min, self-scrapes progress; rbf → dell `~/System573_MiSTer/output_files/Konami_System_573.rbf`).
2. Deploy: fetch rbf to Mac `output_files/`, then `MISTER_ALIAS=de10 tools/mister_deploy_console.sh output_files/Konami_System_573.rbf`.
3. De-confound: `dell_coord.sh devlock de10 acquire 573`; `devlock de10 reboot 573`; wait uptime<60s; re-acquire devlock (reboot wipes it); **ONE** `load_core` of the ddrsbm .mgl: `ssh de10 'echo "load_core /media/fat/_Console/DDR Solo Bass Mix (573).mgl" > /dev/MiSTer_cmd'`.
4. Capture: `~/Dev/fabricore/tools/tools/grab_card.sh de10`. **GOTCHA:** a warm-reboot drops HDMI → the
   capture latches a "de10 — waiting for signal" STANDBY card (luma ~3.9, looks dark). SIGTERM the
   `av_publish ...de10` child so `capture_card.py` re-syncs, THEN grab. VIEW the frame (luma alone lies).
5. Verify objectively: ddrsbm advances PAST BOOT CHECK (frame_diff vs `local/mame_ddrsbm.png`), AND
   regress-test powyakex + hypbbc2p still pass their drive check.

## powyakex — PARKED (separate bug, fully diagnosed)
powyakex now BOOTS + runs attract (past the old FLASH ROM CHECK stall, via the dual-lane flash-ID fix,
PR #1). Its overnight fault: after ~10h of UNTOUCHED attract it shows "HARDWARE ERROR / PLEASE CALL THE
STAFF". Diagnosed: that's the game's CD/data-**LOADER timeout** screen (handler `0x80019590`, string set
"NOW LOADING"/"PLEASE WAIT"/"HARDWARE ERROR"/"PLEASE CALL THE STAFF") — a data load our core doesn't
complete; the ~10h is just when the attract first issues that long-period load. RULED OUT by a workflow +
adversarial verify: RAM bit-rot and the 4MB-aliasing (patch 0022). Forensics confirmed the de10 was NOT
externally disturbed (no SD writes/screenshots/reload after the morning boot; the "stream-setup" timing
was just when the capture came up). Likely shares the CD/ATAPI-completion subsystem with ddrsbm → re-check
powyakex AFTER the ddrsbm ATAPI fix (needs a ~10h run, so deferred). Details: [[powyakex-baseball-flash-stall]].

## Memory pointers
[[fabricore-573-digital-bringup]] (full ddrsbm trail), [[no-mask-fault-with-fake-data]] (binding rule),
[[powyakex-baseball-flash-stall]], [[fabricore-573-portrait-capture]] (de10 capture gotchas).
