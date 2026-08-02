# ★ SESSION HANDOFF — ddrsbm BOOT CHECK: atapi.v EXONERATED; fault localized to the game's IRQ-chain predicate (2026-07-01)

Read this FIRST to resume. Self-contained resume-critical state + the next steps. Full verified verdict:
`docs/2026-06-30-ddrsbm-capx-verdict.md`. Memory: `[[fabricore-573-digital-bringup]]` (banner is current).
Prior verdicts (SUPERSEDED, for history): `docs/2026-06-30-ddrsbm-drain-capture-finding.md` (over/under moot),
`docs/2026-06-30-ddrsbm-signaltap-drain-handoff.md`, `docs/2026-06-30-ddrsbm-bootcheck-tracedig.md` (§1-14).

---

## 1. ONE-LINE STATE
ddrsbm (digital DDR) freezes at BOOT CHECK because its IDENTIFY-completion IRQ is delivered + latched
correctly, the CPU takes the exception, the BIOS dispatch runs, and the game's own **IRQ-chain predicate
`0x803c7bf0` DECLINES the interrupt** — it reads its handler-descriptor `@*(0x803cf4fc)`, finds the enable
bit ([ptr+4]&1) SET but the **pending/owned bit ([ptr+0]&1) CLEAR**, and returns "not mine" — so the drain
ISR (`0x803cb2dc`) never runs, the 512-byte IDENTIFY block never drains (`ridx` stays 0), the IRQ is never
acked, and the CPU falls into the BIOS ReturnFromException loop. **`atapi.v`, the PSX I_STATUS latch, and the
BIOS dispatcher are ALL proven healthy and EXONERATED — do NOT touch them.**

## 2. VERIFIED (adversarially, workflow `w6ych2a91` — do NOT re-litigate)
- **atapi.v EXONERATED.** It raises INTRQ on S_DATAIN entry, latches cleanly (irq_pending↑ / irq_out↑ /
  I_STATUS[10]↑, one staged edge, ce=1 throughout), holds DRQ (r_status=0x48) + byte-count 0x0200, waits to
  be read. No device-side change can fix a hang whose cause is the CPU never accessing the device.
- **The drain ISR (`0x803cb2dc`) NEVER runs.** All drain PCs = 0 post-trigger samples (0x803cb284 PIO drain,
  0x803cb884/8b4 self-drain, 0x803cb4b8 completion-wait). `ridx` flat 0; ALL bus strobes flat 0 (no ATAPI
  access of any kind).
- **DMA path RULED OUT** (candidate b): `dbg_dma_rd`=0, `dbg_dma_req`=0 the whole window.
- **BIOS dispatch is HEALTHY** (§13 confirmed): the CPU takes the exception once (`0x80000080`, no re-vector
  storm), the dispatcher (`0x80000c80`) runs, and it DOES invoke the game predicate `0x803c7bf0` — which
  declines. §12's suspected AREA (0x80000000 dispatcher) is where the CPU lives, but its MECHANISM (ce-gated
  dropped edge) is REFUTED (the edge is delivered/latched perfectly).
- **IDENT_SETTLE fix CONFIRMED DEAD** (the 2048-clk settle ran; block still didn't drain). **Do NOT re-tune it.**
- **Candidate (c) survives:** the CPU never issues any ATAPI read (nor the reg7 ack). (a) driver-issues-no-reads
  and (b) DMA are refuted.
- I_MASK[10]=1 (IRQ10 unmasked at the controller); so "masked / never delivered to software" is disfavored.

## 3. THE PREDICATE (capstone-disassembled, `local/tracedig/ddrsbm_full_code.asm`)
```
0x803c7bf0  lui  $v1,0x803d ; lw $v1,-0xb04($v1)   ; v1 = *(0x803cf4fc) = descriptor ptr
0x803c7bfc  lw   $v0,4($v1)  ; andi $v0,1 ; beqz -> ret 0   ; enable bit [ptr+4]&1  (SET here)
0x803c7c10  lw   $v0,($v1)   ; andi $v0,1 ; bnez -> ret 1    ; pending bit [ptr+0]&1 (CLEAR here) -> ret 0
```
Returns MINE(1) only if enable AND pending are both set. Here pending is clear → declines.

## 4. THE OPEN QUESTION + NEXT STEP (build-FREE first; NO atapi.v rebuild)
Why is `*(0x803cf4fc)+0` (pending/owned) clear when the completion IRQ fires? Two readings:
- **(1) Never-armed:** the driver's ATAPI command-issue/handler-arm path never sets that bit on our core.
- **(2) Armed-late RACE:** the completion IRQ arrives before the driver marks the descriptor pending. *(This
  is the SAME race IDENT_SETTLE=2048 targeted — dead → settle insufficient, or the bit isn't what it assumed.)*

**Do this next (FREE trace-dig — the top LESSON of this saga is oracle-first, not another build):**
1. **MAME oracle** (ddrsbm boots fine, Gate −1 satisfied): trace MAME's writes to the descriptor vs the
   IDENTIFY IRQ. `mame_dell.sh` / `-debug`. Find: does MAME set `[desc+0]` bit0 BEFORE the IRQ? What's the
   runtime descriptor address (`*(0x803cf4fc)`)? Compare arm-vs-IRQ ordering to our core's IRQ timing.
2. **Disasm the driver's IDENTIFY command-issue path** (`0x803cb7c4` region + wherever it writes `@0x803cf4fc`
   / the descriptor). Where/when does it set the pending bit relative to the 0xA1 command write?
3. **Only if the trace-dig is inconclusive → capture-Y (rebuild):** a PC+DATA SignalTap that taps the runtime
   words the predicate reads — `*(0x803cf4fc)` `+0`/`+4` at the predicate's loads (`~0x803c7bf0/bfc`), OR a
   memory-WRITE tap on `@0x803cf4fc`, to see arm-vs-IRQ timing directly. **DOWNGRADED / NOT needed:** CP0
   Cause/EPC + I_MASK[10] (I_MASK[10]=1 already; the exception/dispatch/predicate all provably ran).

If it's the RACE → the fix is a correct settle/handshake (in atapi.v's IRQ *timing* only, or the transport),
NOT the device data path. If NEVER-armed → a driver/data/state difference our core presents that makes the
driver skip arming; likely needs the MAME diff to pinpoint. Either way, confirm BEFORE building.

## 5. STATE OF THE WORLD
- **Git — `feat-digital-bringup`** (main WIP, trunk-bound): HEAD **`c4abadb`** = capex verdict doc, IN SYNC
  with `origin` (private). Chain: c4abadb(capx verdict) → 65bf225(drain verdict) → 02b36f3(drain handoff) →
  621c36f(§14) → … . `rtl/atapi.v` here has the (dead, benign) IDENT_SETTLE fix; leave it.
- **Git — `dbg-signaltap-atapi-wedge`** (⚠️ DEBUG, NEVER MERGE): HEAD **`487f488`** = capture-X probe
  (PC[23:2] + `dbg_dma_rd/req` taps in atapi.v's dbg block, DRQ-entry trigger, depth 4096, SLD-expanded QSF).
  Pushed to `origin`. Generator `tools/signaltap_573/atapi_irq_capx_stp.tcl`.
- **dell:** `~/System573_MiSTer` on **`487f488`** (capture-X). origin=private (read-only deploy key → CANNOT
  push from dell; push dbg-branch changes from the Mac: `git fetch dell:System573_MiSTer <branch>` →
  `git push origin FETCH_HEAD:refs/heads/<branch>`). rbf `output_files/Konami_System_573.rbf` = capture-X
  `cd46fd77`. **`git reset --hard` dell's tree before any launcher build** (dirty QSF from `--enable` aborts checkout).
- **de10:** devlock **FREE**. Running the capture-X instrumented core (rbf `cd46fd77`, CORENAME=System573,
  parked at BOOT CHECK). ddrsbm staged: `/media/fat/games/System573/ddrsbm.{chd,u1,u6}` + BIOS; `.mgl` =
  `/media/fat/_Console/DDR Solo Bass Mix (573).mgl`. **Shared with `dvd` — coordinate the devlock via chat.**
- **Hub `LESSONS.md`** (`~/Dev/fabricore/tools`): 4 cross-core silicon-debug lessons added + pushed (`1275162`)
  — PC-first, let-measurement-pick-hypothesis, MAME full-system oracle, observe-before-fix. Reaches all cores.

## 6. KEY ARTIFACTS & PATHS (all PERSISTENT — local/ survives sessions, docs/ committed)
- Capture-X CSV: `local/signaltap/20260630_223849/atapi_irq_20260630_223849.csv` (74 cols incl PC[2..23] +
  dbg_dma_rd/req; clean, DRQ-triggered, BOOT CHECK confirmed). Prior: `…/20260630_204524/` (irqout, 8192).
- Decoders (persisted from scratchpad → here): `local/tracedig/decode_capx.py` (capture-X, authoritative),
  `local/tracedig/decode_drain2.py` (name-mapped drain decoder).
- Capture/deploy recipes: `local/tracedig/deploy_capx.sh` (deploy rbf + de-confounded DRQ capture),
  `local/tracedig/reboot_load_capture_v2.sh` (de-confounded capture w/ MENU-ready gate),
  `local/tracedig/measure_bootcheck_timing.sh` (boot→BOOT-CHECK timing, ~46s).
- BOOT CHECK evidence: `local/tracedig/ddrsbm_de10_bootcheck_capx.png`.
- Disasm: `local/tracedig/ddrsbm_full_code.asm` (game, base 0x803c0000), `ddrsbm_code_b000_e000.asm`
  (0x803cb000-e000). BIOS RAM image: `local/tracedig/573bios.bin` (capstone 5.0.7; file off = addr−0x80000000).
- Capture on dell (passive JTAG on dell's USB-Blaster): `tools/signaltap_573/capture_atapi.sh <timeout>`
  (reads the committed `atapi_irq.stp` from dell's checkout → dell must be on `487f488` at capture time).
- Verify workflows (this session): `w055yphmp` (drain decode), `w6ych2a91` (capture-X verdict).
- Key addrs: predicate `0x803c7bf0`, descriptor ptr `@0x803cf4fc` (= `[0x803d0000-0xb04]`), drain-ISR
  `0x803cb2dc`, ISR PIO drain `0x803cb284`, self-drain `0x803cb884/8b4`, completion-wait `0x803cb4b8`,
  IDENTIFY driver `0x803cb7c4`, exception vector `0x80000080`, BIOS dispatcher `0x80000c80`, RFE loop
  `0x80001bb8-c30`.

## 7. NON-NEGOTIABLES / GOTCHAS
- **Do NOT touch `atapi.v`, the PSX I_STATUS latch, or the BIOS dispatch — all EXONERATED.** A device fix
  can't cure a CPU-never-accesses-the-device hang. Do NOT re-tune IDENT_SETTLE; do NOT ship the
  edge-qualify-consume fix (that was for an over-count this evidence rules out).
- Build ONLY via `~/Dev/fabricore/tools/tools/dell_build.sh` (`DELL_REPO`=bare `System573_MiSTer`). A hook
  blocks off-protocol builds. The launcher resets branch refs to ORIGIN — push the dbg branch from the Mac
  first, then build by branch name (or it builds the stale origin ref). `git reset --hard` dell before it.
- De-confound EVERY HW verdict: warm-reboot via `devlock … reboot`, **wait for CORENAME=MENU before
  `load_core`** (loading too early → the .mgl's delayed CHD/save mounts fail → drops to menu → SLD mismatch →
  Error 12852), then ONE `load_core`. Arm SignalTap IMMEDIATELY after load_core (the IDENTIFY DRQ+IRQ is at
  ~uptime 60-65s / ~40-46s post-load; the boot→BOOT-CHECK is ~46s). Verify with a NUMBER **and LOOK** at the frame.
- Lock the de10 devlock before use, release after; it's SHARED with `dvd` — coordinate via
  `~/Dev/fabricore/tools/tools/dell_coord.sh chat` (post as `573`).
- SignalTap `state`/FSM taps are UNRELIABLE (Quartus re-encodes state machines → "Lost fanout" → constant 0);
  infer FSM phase from `r_status` (a plain reg). `ridx`/`r_status`/`dbg_*`/`PC` are plain regs/counters → reliable.
- The `dbg-signaltap-atapi-wedge` branch is **NEVER merged**. `psx/` stays pristine (patches). Commit as
  **Fabricore**, push PRIVATE (`origin`) by default.

## 8. THE ARC (so the reasoning isn't lost)
IN1/DIO value theories (wrong turn) → CD/ATAPI drive-check pinned → IDENTIFY-content ruled out → ATA-decode
ruled out → completion-IRQ path → IDENT_SETTLE fix (dead) → trace-dig ("no race") → sim clean → SignalTap
wedge (delivery clean, drain-never-completes) → drain analysis (over/under suspect) → **drain-anchored capture
(over/under MOOT; IDENTIFY 0xA1 block never drains; state-tap dead)** → **capture-X w/ PC+dma (atapi.v
EXONERATED; DMA out; the game's IRQ-chain predicate declines because its pending bit is clear)**. Every step
adversarially verified; the verify passes repeatedly CORRECTED over-reads (incl. two of mine) — keep that
discipline: PC-first + MAME-oracle-first, observe before you build (see hub `LESSONS.md` +
`[[silicon-hang-debug-heuristics]]`).
