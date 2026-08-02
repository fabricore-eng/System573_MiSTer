# ★ VERDICT — ddrsbm BOOT CHECK root cause: the k573dio MAS3507D I2C stub (ATAPI/CD path PASSES) — 2026-07-01

**Read this FIRST to resume.** Supersedes the conclusions (not the raw data) of
`docs/2026-06-30-ddrsbm-capx-verdict.md` and `docs/2026-07-01-ddrsbm-capx-handoff.md` §1/§4.
Memory: `[[fabricore-573-digital-bringup]]` (banner updated).

## 1. ONE-LINE VERDICT

ddrsbm's CD/ATAPI drive check **PASSES on silicon** — IDENTIFY completes end-to-end (device,
IRQ dispatch, ISR, drain, success return), the PACKET phase runs, and the **main game loads
from CD into RAM and executes**. The BOOT CHECK freeze is the main game spinning forever at
`0x800aaf68` on the **DIGITAL I/O BOARD**: it writes `0x3000` to `0x1f6400ac` (k573dio
MAS3507D **I2C** register: bit13=SCL, bit12=SDA) and polls for SCL (bit `0x2000`) to read
back high — `rtl/k573dio.v` is a stub whose read mux has **no `0xac` case → returns 0x0000
forever** → infinite spin → BOOT CHECK. This is the DDR-bringup plan's P3 "k573dio de-stub"
gate, now with a precise, evidence-backed first target.

## 2. WHAT WAS OVERTURNED (and by what evidence)

The prior verdict chain ("IDENTIFY block never drains → game IRQ predicate declines → ISR
never runs") was built on **two artifacts**, both now proven false on the SAME rbf
(capture-X build `cd46fd77`, dell `487f488`):

1. **"The game's IRQ predicate 0x803c7bf0 declines the ATAPI IRQ" — MISREAD.**
   `*(0x803cf4fc)` is not a driver descriptor: it is a **static constant = 0x1f801070
   (I_STAT)** in a libapi MMIO-pointer table (sibling cell `0x803cf4f8` = 0x1f801040
   JOY base). The "predicate" is the **PAD library's VBLANK verifier** (SysEnqIntRP prio-1
   element `0x803d1060`); it checks I_MASK bit0/I_STAT bit0 and *correctly* declines a
   non-vblank IRQ. Its decline does not terminate dispatch — the kernel chain-walk
   continues (verified: BIOS walk at RAM `0x800108f8` calls every element's `+8` verifier).
   Evidence: MAME trace of the ptr cell (written once by the image copy loop with
   0x1f801070), static bin content at offset 0xf4fc, adversarial workflow `wjru2dbhq`
   (3 analyst lanes + refuters, converged independently).

2. **"No ATA access / block never drains (all bus strobes flat 0)" — DEAD-TAP ARTIFACT.**
   The SignalTap `dbg_sel/dbg_re/dbg_we/dbg_pio_rd/...` taps in this build are dead
   (constant 0 — same "Lost fanout" disease as the state tap). Two proofs on silicon:
   (a) deep capture `20260630_204524`: `irq_pending` (a live reg) DROPS at t=7687 — per
   `rtl/atapi.v` that clears ONLY on a command write (would change r_status; it didn't) or
   a **reg7 status READ** = the drain ISR's first ATA read; I_STATUS[10] was acked at
   t=7543 by the game dispatcher (`sh ~(1<<10)`, the only bit10-ack in the system).
   (b) NEW capture `20260701_163054` (PC-trigger at the IDENTIFY epilogue `0x803cb934`):
   at trigger, **ridx=510** (= last word of the 512-byte block consumed; ridx is a
   byte-index of the current word, ALWAYS EVEN), `r_status=0x50` (DRDY|DSC, post-completion
   idle), `irq_pending=0`, and the pre-trigger PC window shows the IDENTIFY **byte-swap
   loop** (`0x803cb904-30`, words 0x17-0x2e of the drained buffer — success-path-only code)
   falling into `move v0, zero` = **IDENTIFY returned SUCCESS**.

## 3. THE FULL VERIFIED DISPATCH CHAIN (silicon, all on rbf cd46fd77)

IDENTIFY 0xA1 → S_PREP settle → S_DATAIN (r_status 0x80→0x48), INTRQ, I_STATUS[10] latched
→ CPU exception 0x80000080 → BIOS dispatcher 0x80000c80 → priority chains walk (prio0
0x19f4; prio1: game vblank verifier 0x803c7bf0 + kernel 0x18b0/0x184c/0x17e8/0x1788; prio2
0x4a4c; prio3 0x2458) — all decline (CORRECT; none is the ATAPI handler) → prio3 verifier =
the kernel IRQ→event broadcaster: saw `I_STAT & I_MASK & 0x400` set (branch at 0x80002524
fell through — cancelled-prefetch signatures prove it) → DeliverEvent(0xf000000a, 0x1000) →
no matching EvCB entry (same in MAME — the event path is vestigial) → kernel epilogue loads
jmp_buf ptr from `*(0x800075c0)` = `0x803cf5c4` (game-installed) → **longjmp into the game's
IRQ manager** (`buf.ra=0x803c8300` → `jal 0x803c8370` dispatcher) → dispatcher reads
`lhu I_STAT & lhu I_MASK & soft-mask [0x803cf5bc]=0x409`, sees bit10 → **acks I_STAT**
(observed t=7543) → `jalr cb[10]` (callback table `0x803cf590`, slot `0x803cf5b8` =
**0x803cb2dc**, registered via vtable `*(0x803d0614)`→`[+8]`=0x803c8540 for irq 0xa at
orchestrator `0x803c22e4`) → **drain ISR runs** (counter++ @0x803d2280; reg7 read observed
t=7687 clearing INTRQ; state byte 0=self-drain → skips ISR drain BY DESIGN) → completion-wait
`0x803cb4b8` (polls counter vs snapshot, hblank-tick bounded 0xf690≈4s, kicks watchdog)
returns 0 → saved-status DRQ ok, bc=0x0200 ok → **self-drain loop 0x803cb8ac-d4 reads all
256 words** (ridx→510) → completion INTRQ fires on last consume → second ISR → ERR clear →
byte-swap → **return 0**. PACKET phase follows (MAME: ~10 packets, f141) → **main game loads
from CD** → runs at 0x800aaxxx → **parks in the DIO MAS3507D I2C poll** (steady-state
capture `20260701_164129`, armed at BOOT CHECK+75s: 14 unique PCs, all in
0x800aae6c-88/0x800aaf68-7c).

## 4. THE TERMINAL LOOP (decoded from MAME RAM dump @f4800, `local/ddrsbm_gwait.bin`)

```
0x800aaf40  sh 0x3000 -> 0x1f6400ac        ; k573dio MAS I2C: SCL=1 (bit13), SDA=1 (bit12)
0x800aaf68  jal 0x800aae6c                 ; leaf: lhu 0x1f6400ac; andi 0x2000; return !=0
0x800aaf74  beqz v0 -> 0x800aaf68          ; spin until SCL reads back HIGH  <-- STUCK HERE
```
(Neighbors: `0x800aae88` writes 0xffff→`0x1f6400ba`; `0x800aaeb0` reads `0x1f6400ae`&0x1000
(fpga_ctrl is_streaming); `0x800aaecc` composes SCL/SDA writes; `0x800aaf18/2c` read
`0x1f6400ce/cc`.) MAME 0.285 ground truth (`k573dio.cpp`/`k573fpga.cpp`):
`mas_i2c_r = (mas3507d->i2c_scl_r()<<13) | (mas3507d->i2c_sda_r()<<12)`;
`mas_i2c_w: scl=data&0x2000, sda=data&0x1000`; `fpga_ctrl_r = is_streaming<<12`.

`rtl/k573dio.v` (163-line stub): write case has `default:` for 0xac ("stub/unhandled"),
read mux has NO 0xac case → 0x0000. Even the trivial line-echo fails, so the very first
poll spins forever.

## 5. THE FIX (BUILD GATE — awaiting go; do NOT build without it)

De-stub the MAS3507D I2C endpoint in `rtl/k573dio.v` (DDR plan P3, first slice):
1. Latch reg 0xac writes → `scl_out`(bit13), `sda_out`(bit12).
2. Read 0xac → `{scl_rb, sda_rb} << 12` where `scl_rb = scl_out` (no clock-stretch model)
   and `sda_rb = sda_out & sda_slave` (open-drain AND).
3. A minimal MAS3507D I2C SLAVE FSM (new small module or inline): START/STOP detect,
   device address (MAS3507D: 0x3A write / 0x3B read), ACK (drive sda_slave low on the 9th
   clock), and the subaddress/register read path enough for the boot check's version/ID
   read (check what the game asks for AFTER the line-echo works — expect address 0x3A,
   subcommand read of the version register; MAME's mas3507d.cpp `i2c_device_got_*` is the
   reference). **No fake data** ([[no-mask-fault-with-fake-data]]): model the real chip's
   protocol; if the game then wants real MP3 DATA, that's the known HPS-minimp3 lane, NOT
   this gate.
4. Likely also needed within the same check: `0xae` fpga_ctrl (streaming bit) — present
   already as `fpga_ctrl_rb` (bit12) — verify semantics against k573fpga (is_streaming
   only when start<cur<end), and the `0xcc/0xce` mp3 counters (stub reads 0 today —
   acceptable until the check demands them; observe first).
Verification path: MAME oracle first (its boot check passes with the same data), then ONE
build → steady-state PC snapshot (the `ce==high` trick, §6) must show the loop GONE, then
frame evidence (mister_vram_dump for portrait) + the boot check screen listing.

## 6. TOOLING LESSONS (cost: ~2 sessions of false verdicts — encode these)

- **Verify TAP LIVENESS before trusting absence-of-signal.** The dbg_* taps read constant 0
  for weeks. A tap that never fires across windows where a live reg (irq_pending) proves
  activity = dead tap. Cross-check every "X never happens" against an independent live reg.
- **`ridx` is a byte-index advancing by 2 — `ridx[0]` NEVER rises.** Bit-level trigger
  choices must respect signal semantics (use ridx[1] for "first consume").
- **The .stp trigger condition lives in the `<level name="condition1" type="basic">`
  expression** — NOT in the per-node `level-0` display attributes. Runtime trigger retune =
  edit that expression; needs NO rebuild (same node set). PC-equality triggers: AND all 22
  `PC[23:2]` bits.
- **Steady-state snapshot trick:** trigger `ce == high` (always true) armed once the fault
  state is on screen → instant window of exactly where the CPU parks. Cheapest possible
  "where is it stuck" probe; should be the FIRST silicon probe of any hang, not the last.
- **MAME 0.285 + write-taps on RAM crashes/hangs mid-drive-check** (v1 died f140, v6/v7
  f141, prior session f165 — always the PACKET/DMA phase). Dump-only Lua (no taps) survives.
  Also: MAME Lua address-space API is `read_u32/read_u8` (NOT read_dword); tap callbacks
  receive the ABSOLUTE address; `-seconds_to_run` with `-video none` exits without firing
  stop notifiers (logs truncate mid-line — benign).
- **BIOS memtest spoofs RAM-value triggers** (writes address patterns everywhere at f38) —
  gate any Lua RAM-value trigger on the writer PC or on post-boot frames.
- The IRQ dispatch enters the game NOT via SysEnqIntRP handlers but via the kernel's
  **custom-exit-from-exception longjmp** (`*(0x800075c0)` → jmp_buf) — PSX-kernel lore that
  applies to every Konami 573 title; keep `local/ddrsbm_kram.bin` (runtime kernel dump).

## 7. ARTIFACTS (all persistent)

- Captures: `local/signaltap/20260701_162025` (stale-trigger control), `…_163054`
  (IDENTIFY-success PC window, ridx=510), `…_164129` (steady-state DIO spin);
  prior: `20260630_204524` (deep, irq ack/reg7 timeline), `20260630_223849` (capture-X).
- MAME dumps: `local/ddrsbm_kram.bin` (kernel 0-32K, runtime@f141), `local/ddrsbm_bss.bin`
  (0x803d0000+192K), `local/ddrsbm_gimg.bin` (game image 0x803c0000+64K runtime),
  `local/ddrsbm_gwait.bin` (0x800a8000+32K @f4800 — the DIO-poll code), `ddrsbm_gmain.bin`.
- MAME traces: `local/ddrsbm_desc_arm.log` (ATA + ptr-cell + ISR-book ordering, f140),
  `local/ddrsbm_desc_arm3.log` (chain topology + vtable + EvCB dump at drive-check).
- Lua tools: `tools/trace/ddrsbm_desc_arm.lua` (taps+ordering), `tools/trace/
  ddrsbm_dump_late.lua` (tap-free late RAM dump); iterations in `local/tracedig/lua_iterations/`.
- Recipes: `local/tracedig/steady_state_capture.sh` (BOOT-CHECK steady-state snapshot),
  `local/tracedig/reboot_load_capture_v2.sh` (de-confounded trigger capture).
- Key addresses: game IRQ manager struct `0x803cf58c` (cb table +4 = 0x803cf590, cb[10]
  slot 0x803cf5b8, soft mask 0x803cf5bc, jmp_buf 0x803cf5c4); manager dispatcher
  `0x803c8370/0x803c83c8`, registrar `0x803c8540`, vtable ptr `0x803d0614`; kernel
  custom-exit cell `0x800075c0`; DIO poll `0x800aaf40/0x800aaf68`, leaf `0x800aae6c`.
- Workflow: `wjru2dbhq` (3-lane disasm + adversarial verify).

## 8. STATE OF THE WORLD (unchanged unless noted)

- Git `feat-digital-bringup` @ this commit (doc + lua tools). `dbg-signaltap-atapi-wedge`
  @487f488 unchanged (NEVER merge). dell tree restored clean on 487f488 (rbf cd46fd77
  intact); the scratch `.stp` trigger edits were reverted (`git checkout`).
- de10: devlock RELEASED; board left at BOOT CHECK on the capture-X core (harmless).
  Warm-reboot + MENU-wait + ONE load_core before any next verdict, as always.
- `atapi.v` (incl. IDENT_SETTLE) needs NO changes for this gate. Do not touch it.
