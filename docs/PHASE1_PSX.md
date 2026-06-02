# Phase 1 — sitting the 573 on a real PlayStation core

This is the plan for the one piece this repository deliberately does **not**
implement from scratch: the PlayStation 1 itself (R3000A + GTE + DMA + GPU + SPU).
Everything else in the core is built and unit-tested around the EXP1 master
contract that this PS1 core must drive. This document is the concrete integration
plan; see **Implementation status (2026-06-02)** below — it is now implemented
(`rtl/emu.sv` is a clone of `psx/PSX.sv` with the 573 EXP1 deltas; `ps1_stub` is
replaced).

## What we're integrating

Target core: **MiSTer-devel/PSX_MiSTer** (`rtl/` PSX core by Robert Peip / "FPGAzumSpass").
It is a mature, accuracy-focused PS1 core already running on the same DE10-Nano
hardware, which is exactly why the 573 is a reachable target.

Bring it in as a **git submodule** under `psx/` (or vendor a pinned snapshot),
keeping its GPL headers intact and recording the upstream commit. Add its file
list to `files.qip`.

## The hook point: EXP1

The 573's peripherals live in the PlayStation **EXP1** region (physical
`0x1f000000`–`0x1f6fffff`). The whole core in this repo hangs off a single master
interface, already brought out by `system573_top`:

```
exp1_addr[23:0]   // offset within the 0x1f000000 page
exp1_wdata[15:0]
exp1_we, exp1_re
exp1_rdata[15:0]  // returned by the 573 fabric (s573_bus + peripherals)
```

In PSX_MiSTer the CPU's loads/stores flow through its memory/bus module. The
integration work is to **detect accesses to the EXP1 window there and route them
to `system573_top`** instead of (or in addition to) the stock EXP1/parallel-port
handling:

1. Find the address-decode in the PSX memory controller that classifies a
   physical address (the region select for SPU/EXP/scratchpad/BIOS).
2. Add an EXP1 (`0x1f000000`-page) branch that asserts `exp1_re`/`exp1_we` with
   `exp1_addr = paddr[23:0]` and stalls the CPU read until `exp1_rdata` is
   presented (the 573 peripherals here answer combinationally / next-cycle, so a
   fixed small wait-state is enough — match the PSX EXP1 access timing registers).
3. Feed `exp1_rdata` back as the load result for EXP1 reads.

Byte vs halfword: 573 software touches most registers 16-bit (and the RTC/NVRAM
via the low byte). Keep the existing 16-bit `exp1_*` contract and handle 8/32-bit
CPU accesses by lane-steering in the adapter.

## 573-specific deviations from a retail PS1

| Item | Retail PS1 | System 573 | Action |
|------|-----------|------------|--------|
| BIOS | 512 KB SCPH | 512 KB **Konami** BIOS | swap the BIOS ROM image/init |
| Main RAM | 2 MB | **4 MB** | widen the RAM region + mirroring/decode |
| VRAM | 1 MB | **2 MB** | widen GPU VRAM + the GP1 framebuffer wrap |
| EXP1 | parallel I/O | **573 peripherals** | route to `system573_top` (above) |

The 4 MB RAM and 2 MB VRAM are the riskiest core edits — they touch address
decode and mirroring inside PSX_MiSTer. Do them as small, reviewable diffs against
upstream and keep them isolated so the submodule can still be updated.

## Interrupts and DMA

- **IRQ10** (`cdrom_irq` out of `system573_top`, from `atapi`) must be wired into
  the PSX interrupt controller's external/IRQ10 line.
- **DMA channel 5** is used for ATAPI block transfers (manual/sync mode). Hook the
  PSX DMA ch5 to drive `exp1_*` reads from the IDE data register into main RAM.
  Until then, PIO data-in (already modeled in `atapi.v`) is the fallback path.

## Video / audio / controls out to MiSTer

- Route the PSX core's video and audio to the MiSTer `sys/` framework in `emu.sv`
  (the placeholder ports on `ps1_stub` mirror what the real core provides).
- `s573_io` already exposes JAMMA inputs; map MiSTer `joystick_0/1` and keyboard
  to `p1_ctrl`/`p2_ctrl`/coin/service/test in `emu.sv`.

## Backing stores in DDR3

- CD image: back `atapi`'s disc store with a real CD image in DDR3 (the model's
  `disc[]` becomes a DDR3-backed reader); wire to the HPS file interface.
- Flash / PCMCIA: back `s573_flash` with DDR3 and use `flash_nor` as the per-chip
  command engine so saves/installs persist (HPS save support).

## Bring-up / verification order

1. Elaborate PSX_MiSTer + `system573_top` together; EXP1 reads return real
   peripheral values (watch the BIOS poll the watchdog, ASIC I/O, RTC).
2. Konami BIOS **POST**: reaches the security-cart / RTC checks — these now have
   real devices answering (`s573_seccart`, `m48t58`).
3. BIOS reaches the **CD boot**: `atapi` answers IDENTIFY/INQUIRY/READ, the BIOS
   reads the boot sectors.
4. First title boots from a CD image; then per-game security (X76/ZS01) and, for
   BEMANI, the Digital I/O board + MP3 path.

Steps 1–4 are validated on hardware / full-system simulation, not the unit-test
suite — which is why this phase is tracked separately from the green `make -C sim`
peripheral tests.

## Risks / unknowns

- Exact EXP1 access timing the Konami BIOS expects (wait states).
- The 4 MB/2 MB widenings interacting with PSX_MiSTer's mirroring assumptions.
- Whether DMA ch5 needs cycle-accurate behavior for the BIOS CD reader or whether
  PIO suffices for initial boot.

## Implementation status (2026-06-02)

**Implemented:** `rtl/emu.sv` is a clone of `psx/PSX.sv` with the 573 EXP1 deltas
(`ps1_stub` replaced). Two CPU i-cache fixes — `psx_patches/` 0004 (redirect) + 0005
(BIOS-uncached) — fixed the color-bar crash, and the 18E (H8/3644) I/O-MCU self-test
fix (`rtl/s573_io.v`, PR #16) lets the BIOS pass POST. The BIOS now boots to the GX700
power-on self-test on real hardware (next gate: the CDR / CD-ROM check). See
`docs/ROADMAP.md` for the i-cache-crash analysis.

The simulation strategy is settled empirically: the PSX core is VHDL-2008 and is
simulated under **NVC** (Verilator cannot consume it; mixed VHDL+Verilog co-sim of the
real fabric needs an NVC↔Verilator FFI bridge or hardware). See the `sim-toolchain`
notes in `docs/DEPENDENCIES.md` / project memory.

**Done (EXP1 contract + widening):**
- `system573_top.exp1_rdata` is now a **registered** read (latched on `exp1_re`, held
  otherwise) so it satisfies the PSX external-bus FSM, which samples read data one
  cycle after the strobe in `EXT_READ`. A combinational read would return 0 → POST
  hang. HOLD (not exp2-style clear-to-0) survives the PSX core's `ce` gaps since this
  fabric runs free on `clk1x`. (rtl/, merged.)
- EXP1 path widened in `psx/` (via `psx_patches/0001-s573-exp1-widening.patch`,
  `tools/apply_psx_patches.sh`): from the upstream read-only **8-bit / 13-bit-address
  stub** to a full **16-bit master** (24-bit byte address, 16-bit read+write) routed to
  `system573_top`; 16-bit halfword read assembly; `irq_LIGHTPEN`←573 ATAPI INTRQ
  (IRQ10). The patched core elaborates clean under NVC; the fabric's stepped-address
  decode is covered by a multi-beat 32-bit read test in `tb_system573_top`.

**Deferred (off the BIOS-POST / gchgchmp critical path — tracked, to address at the CD/ATAPI phase):**
- **EXP1 8-bit (width=0) accesses:** the read assembly assumes the 573's normal 16-bit
  bus (`ex1_memctrl(12)=1`). The full-system sim must monitor for any EXP1 access while
  width=0 (the unverified assumption that the BIOS programs width=16 *before* the first
  peripheral access — MF-5). Add this assertion to the Phase-2 harness.
- **IRQ10 edge vs level:** `irq.vhd` rising-edge-latches; the 573 `cdrom_irq` is a level
  held until the ATA status read. Verify `atapi.v` de-asserts INTRQ on status read so
  each event makes a clean edge (else lost interrupts).
- **ATAPI 32-bit data-port reads + autoinc:** confirm the IDE data FIFO is read
  correctly when `exp1_addr[1]` steps (data port must not alias to a different taskfile
  register on the 2nd halfword).
- **DMA channel 5:** dead upstream (`dma.vhd`); PIO fallback assumed for boot — verify
  the 573 BIOS CD path polls DRQ rather than waiting on a DMA5 completion IRQ.
- **`ce` gating of the fabric for side-effecting reads** (ATAPI FIFO pops), **2 MB VRAM**
  (`gpu.vhd`), and the Konami **512 KB BIOS load** + **4 MB RAM (`ram8mb=1`)** wiring —
  the last two land with the `emu.sv` integration + build-wiring PR.
