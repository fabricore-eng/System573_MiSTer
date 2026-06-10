# BUILD #9 SignalTap plan — catch the mangled GP0 word AT the dma→gpu boundary

Companion to `docs/audits/2026-06-10-sdram-capture-audit.md`. This is a PLAN ONLY — no build
launched. All blocks below are copy-paste-ready edits to `clut_race_stp.tcl` +
`signaltap.qsf.snippet` on a debug branch (per the snippet's own workflow).

## 0. Goal and where the probe sits

Build #8 watched the *render-side* CLUT race. Build #9 moves the probe upstream to the
**dma→gpu handoff**: `DMA_GPU_write[31:0]` / `DMA_GPU_writeEna`, the registered nets driven
inside `dma.vhd` (line 699–700, clocked process on clk1x) and consumed by `gpu`. If the CLUT
halfword already reads `0x7800/0x7840` here, the corruption is upstream of the GPU (SDRAM
capture / dma path); if it reads `0x7AC0` here, the GPU-internal FIFO/decode is back on the
table.

Hierarchy (verified in source):
* `dma` instance: `psx_top.vhd:1259` → `idma : entity work.dma`
  full path `emu:emu|psx_mister:psx|psx_top:ipsx_top|dma:idma`
  (`psx_mister` instance `psx` at `rtl/emu.sv:1148-1149`; `ipsx_top` at `psx_mister.vhd:314`)
* `gpu_poly` (decode-side witness `rec_textPalY <= fifo_data(30 downto 22)`,
  gpu_poly.vhd:537): `gpu.vhd:1289` → `igpu_poly`
* pixelpipeline as before: `gpu.vhd:1397` → `igpu_pixelpipeline`

## 1. Clock-domain safety @ capture clock clk2x (67.7376 MHz)

| Signal group | Domain | Safe @ clk2x? |
|---|---|---|
| `dma:idma` DMA_GPU_write/writeEna | clk1x registers (dma.vhd has ONLY clk1x processes) | YES — exact 2:1 same-PLL in-phase → every clk1x state is sampled twice (each beat appears as 2 identical samples; dedup offline) |
| `gpu_poly`, `gpu_pixelpipeline`, `gpu` nets | clk2x | YES — native |
| `sdram:sdram` dma_data[31:0], dma_wr, dma_ack, ch*_ready, dma_reqprocessed | clk_base (= clk1x) registers | YES — oversampled (these are the OPTION-B adds) |
| **`sdram:sdram` dq_reg, data_ready_delay*, ch, ch*_rq, state, cas_addr** | **clk3x (101.6 MHz)** | **NO — undersampled at clk2x; single-cycle events WILL be missed/aliased. Do not add to this instance.** If clk3x visibility is ever needed, it requires a second SignalTap instance clocked on `emu:emu|clk_3x`. The safe alternative for "what did sdram hand to dma" is the clk1x-registered `dma_data`+`dma_wr` pair (Option B below). |
| `sdram` dma_done | clk3x reg (CDC flag) | NO — use dma_ack/dma_wr (clk1x) instead |

## 2. Channel plan (≤87; every node is a REGISTERED net unless marked)

### Option A (primary, task-literal): boundary + CLUT-fetch context — 76 bits

Replacement for the `set PP ...` / `set NODES` block in `clut_race_stp.tcl`:

```tcl
# Hierarchy prefixes (verified 2026-06-10):
set PP  "emu:emu|psx_mister:psx|psx_top:ipsx_top|gpu:igpu|gpu_pixelpipeline:igpu_pixelpipeline"
set GP  "emu:emu|psx_mister:psx|psx_top:ipsx_top|gpu:igpu"
set PY  "emu:emu|psx_mister:psx|psx_top:ipsx_top|gpu:igpu|gpu_poly:igpu_poly"
set DMA "emu:emu|psx_mister:psx|psx_top:ipsx_top|dma:idma"

set CLOCK_NODE "emu:emu|clk_2x"

# Storage qualifier: single node, conditional (same known-good schema shape as
# build #8) -- store ONLY dma->gpu write beats. 4096 samples / 2 (clk2x double-
# sample per clk1x beat) ~= 2048 GP0 words ~= 227 of the 320 quads' 9-word
# packets around the trigger: the buffer IS a GP0 stream dump at the boundary,
# directly diffable against the MAME GP0 oracle.
# (The kept CLUT/pixelpipeline signals are still sampled at every stored beat;
# textPalY/textPalFetched are multi-cycle-stable so beat-sampling shows their
# evolution across the chain.)
set QUAL_NODE "$DMA|DMA_GPU_writeEna"

set NODES [list \
    [list "$DMA|DMA_GPU_writeEna"   1] \
    [list "$DMA|DMA_GPU_write"     32] \
    [list "$PY|rec_textPalY"        9] \
    [list "$PP|stage1_valid"        1] \
    [list "$PP|stage1_palReqY"      9] \
    [list "$PP|textPalReq"          1] \
    [list "$PP|textPalReqY"         9] \
    [list "$PP|textPalY"            9] \
    [list "$PP|textPalFetched"      1] \
    [list "$PP|CLUTwrenA"           1] \
    [list "$PP|state.REQUESTPALETTE" 0] \
    [list "$PP|state.WAITPALETTE"    0] \
    [list "$PP|pipeline_busy"       1] \
]
# 1+32+9+1+9+1+9+9+1+1+1+1+1 = 76 bits (11 spare under the 87 cap).
```

**Removed vs build #8 (54 bits):** `$PP|drawMode[7]`, `$PP|drawMode[8]` (2),
`$PP|reqVRAMXPos` (10), `$PP|reqVRAMYPos` (9), `$PP|state.IDLE`,
`$PP|state.REQUESTMORETEXTURE`, `$PP|state.REQUESTTEXTURE`, `$PP|state.WAITTEXTURE` (4),
`$PP|pipeline_stall` (1), `$PP|CLUTaddrA` (6), `$GP|videoout_reqVRAMEnable`,
`$GP|pipeline_reqVRAMEnable`, `$GP|reqVRAMEnable` (3), `$GP|reqVRAMYPos` (9),
`$GP|vramState.IDLE/.WRITESECOND/.READSECOND/.READVRAM/.CLEARLINESTART/.CLEARLINE` (6),
`$GP|reqVRAMIdle`, `$GP|reqVRAMDone`, `$GP|vram_BUSY`, `$GP|vram_pause` (4).
(The scanout-collision question those answered is settled — render path capture-proven.)

**Added (43 bits):** `$DMA|DMA_GPU_write[31:0]` + `$DMA|DMA_GPU_writeEna` (33, clk1x regs,
dma.vhd:699-700), `$PY|rec_textPalY[8:0]` (9, clk2x reg, gpu_poly.vhd:151/537 — the CLUT row
as decoded from the post-FIFO word: brackets the GPU FIFO from the other side),
`$PP|textPalFetched` (1, clk2x reg, gpu_pixelpipeline.vhd:135).

Node-class notes (dangling-tap lesson):
* Every add is a register with live fanout (DMA_GPU_write feeds the gpu FIFO; rec_textPalY
  feeds textPalX/Y + the 0018 tags; textPalFetched gates the fetch FSM). No dangling nets.
* `CLUTwrenA` is COMBINATIONAL (concurrent assign, gpu_pixelpipeline.vhd:579) — it survived
  build #8 only because of its `IMPLEMENT_AS_OUTPUT_OF_LOGIC_CELL` QSF line; keep that line.
  Registered fallback if the node finder loses it: drop CLUTwrenA and rely on
  `state.WAITPALETTE` (the write happens only in WAITPALETTE with vram_DOUT_READY).

### Option B (recommended upgrade if the team accepts dropping render context): dual-boundary, exactly 87 bits

Single capture answers *sdram→dma* AND *dma→gpu* in one build. Swap, relative to Option A:
drop `$PP|stage1_palReqY` (9), `$PP|textPalY` (9), `$PP|CLUTwrenA` (1),
`$PP|state.REQUESTPALETTE` (1), `$PP|state.WAITPALETTE` (1), `$PP|pipeline_busy` (1) [−22]
and add the clk1x-registered sdram→dma handoff [+33]:

```tcl
set SDR "emu:emu|sdram:sdram"
    [list "$SDR|dma_wr"             1] \
    [list "$SDR|dma_data"          32] \
```

76 − 22 + 33 = 87. Still carries every task-required keep (stage1_valid, textPalReqY,
rec_textPalY, textPalFetched, textPalReq). `dma_wr`/`dma_data` are clk_base(=clk1x) registers
(sdram.sv:181-200) — safe @ clk2x. If the mangle shows at `dma_data` AND `DMA_GPU_write`,
the SDRAM read capture is confirmed on silicon; if `dma_data` is clean but `DMA_GPU_write`
mangled, dma.vhd's internal word path becomes the suspect (would contradict the sim — that
contradiction would itself be the finding).

## 3. Trigger design

### Bit mapping (verified against gpu_poly.vhd:536-537)

`DMA_GPU_write[31:16]` = CLUT attribute halfword of W2 in a 0x2C packet.
clutY[8:0] = word bits [30:22]; clutX[5:0] = word bits [21:16]; word bit 31 = halfword
bit 15 = always 0.

```
true  491: 0x7AC0  -> w[30:22] = 1 1 1 1 0 1 0 1 1   (w25=1, w23=1, w22=1)
mangled 480: 0x7800 -> w[30:22] = 1 1 1 1 0 0 0 0 0
mangled 481: 0x7840 -> w[30:22] = 1 1 1 1 0 0 0 0 1
family pattern:        w[30:22] = 1 1 1 1 0 0 0 0 x   (clutY[8:2]=1111000, clutY[1]=0, clutY[0]=x)
```

The family differs from true 491 at w25 (clutY[3]) and w23 (clutY[1]) — both LOW in the
mangled family, HIGH in 491 — so the pattern below can never fire on a correct word.

### Why the trigger does NOT include the 0x2C opcode term

The opcode byte (`0x2C-family`, bits[31:24]) is in W0; the CLUT halfword is in W2 — two
DIFFERENT beats. A single-level basic trigger ANDs conditions on ONE sample, so
`writeEna && w[31:24]==0x2C && clut-mangled` is unsatisfiable by construction. The opcode is
still captured (it's in the stored stream two beats earlier); sequencing is done offline.

### Main trigger — fire on a mangled CLUT beat (replacement `TRIGGER_TERMS` block)

```tcl
# writeEna && DMA_GPU_write[31:16] == 0111 1000 0x00 0000  (0x7800 / 0x7840:
# clutY in {480,481}, clutX=0, halfword bit15=0). w[22] (clutY[0]) is the only
# dont-care. Cannot fire on true 0x7AC0 (w25/w23 differ).
set TRIGGER_TERMS [list \
    [list "$DMA|DMA_GPU_writeEna"      high] \
    [list "$DMA|DMA_GPU_write\[31\]"   low ] \
    [list "$DMA|DMA_GPU_write\[30\]"   high] \
    [list "$DMA|DMA_GPU_write\[29\]"   high] \
    [list "$DMA|DMA_GPU_write\[28\]"   high] \
    [list "$DMA|DMA_GPU_write\[27\]"   high] \
    [list "$DMA|DMA_GPU_write\[26\]"   low ] \
    [list "$DMA|DMA_GPU_write\[25\]"   low ] \
    [list "$DMA|DMA_GPU_write\[24\]"   low ] \
    [list "$DMA|DMA_GPU_write\[23\]"   low ] \
    [list "$DMA|DMA_GPU_write\[21\]"   low ] \
    [list "$DMA|DMA_GPU_write\[20\]"   low ] \
    [list "$DMA|DMA_GPU_write\[19\]"   low ] \
    [list "$DMA|DMA_GPU_write\[18\]"   low ] \
    [list "$DMA|DMA_GPU_write\[17\]"   low ] \
    [list "$DMA|DMA_GPU_write\[16\]"   low ] \
]
```

Alias risk (a non-W2 beat with upper halfword 0x7800/0x7840): vertex words need
Y=0x780=1920 (offscreen for the panel quads, y∈~0..240 → upper half ≤0x00F0) and the
texpage halfword would need bits 14:11 = 1111 — neither occurs in this scene. If a stray
fire is suspected, the stored stream makes it obvious (no 0x2C two beats earlier) — re-arm.

**No-fire is informative:** with storage qualified on writeEna, a capture that never
triggers while garble is on screen = the mangled value does NOT exist at the dma→gpu
boundary → the fault is INSIDE the GPU after all (FIFO/decode), and the Option-B
`dma_data` taps become the next bisect. (Run the RECON capture below in the same session
to get the positive control stream.)

### RECON trigger mode (regenerate-only, NO rebuild — same node list)

Fires on the first 0x2C-family opcode beat and lets the qualified stream dump do the work
(offline diff vs the MAME GP0 oracle finds every mangled word, no trigger expressiveness
needed). 0x2C..0x2F = `001011xx` in bits[31:24]:

```tcl
set TRIGGER_TERMS [list \
    [list "$DMA|DMA_GPU_writeEna"      high] \
    [list "$DMA|DMA_GPU_write\[31\]"   low ] \
    [list "$DMA|DMA_GPU_write\[30\]"   low ] \
    [list "$DMA|DMA_GPU_write\[29\]"   high] \
    [list "$DMA|DMA_GPU_write\[28\]"   low ] \
    [list "$DMA|DMA_GPU_write\[27\]"   high] \
    [list "$DMA|DMA_GPU_write\[26\]"   high] \
]
```

A third regenerate-only variant for a positive control: trigger on the TRUE word
(terms as the main trigger but `w[25] high, w[23] high, w[22] high`) — proves clean 0x7AC0
beats also traverse the boundary and the tap itself isn't lying.

Keep `SAMPLE_DEPTH 4096`, `TRIGGER_POSITION "post"` (7/8 pre-history → ~1790 words before
the mangled beat: the whole preceding packet run), and the conditional-storage schema
unchanged — only `QUAL_NODE` moves to `$DMA|DMA_GPU_writeEna` (single node, identical
schema shape to build #8; zero new schema risk).

## 4. QSF additions (append to the debug branch's `Konami_System_573.qsf` via `signaltap.qsf.snippet`)

Edit the snippet as follows.

KEEP (still tapped): the `ENABLE_SIGNALTAP` / `USE_SIGNALTAP_FILE` lines (point the file at
the regenerated .stp, e.g. `tools/signaltap_573/build9_boundary.stp`), the
PRESERVE_REGISTER + PRESERVE_FANOUT_FREE_NODE pairs for `stage1_palReqY` (Option A taps it;
it has zero readers with CLUT_ROWLOCK='0' — the FANOUT_FREE line is what keeps it alive),
and the PRESERVE_REGISTER lines for `textPalY[*]`, `textPalReqY[*]`, `textPalReq`,
`stage1_valid`, plus the `IMPLEMENT_AS_OUTPUT_OF_LOGIC_CELL` lines for `CLUTwrenA` and
`pipeline_busy` (Option A) — these are combinational taps.

DELETE (taps removed; freeing the fitter): the stageS_palReqY/stage0_palReqY pairs, the
`CLUTaddrA[*]`, `reqVRAMXPos[*]`, `reqVRAMYPos[*]`, `drawMode[*]` PRESERVE lines, the
`pipeline_stall` IMPLEMENT line, and the whole "gpu-level VRAM arbiter" block
(`reqVRAMEnable`, `reqVRAMYPos`, `reqVRAMIdle`, `videoout_reqVRAMEnable`,
`pipeline_reqVRAMEnable`, `reqVRAMDone`).

ADD:

```tcl
# --- build #9: dma->gpu boundary (clk1x registers, dma.vhd:699-700) ----------
set_instance_assignment -name PRESERVE_REGISTER ON -to "*|dma:idma|DMA_GPU_write[*]"
set_instance_assignment -name PRESERVE_REGISTER ON -to "*|dma:idma|DMA_GPU_writeEna"

# --- build #9: gpu_poly decode-side CLUT row (clk2x reg, gpu_poly.vhd:151) ---
set_instance_assignment -name PRESERVE_REGISTER ON -to "*|gpu_poly:igpu_poly|rec_textPalY[*]"

# --- build #9: pixelpipeline fetch-complete flag (clk2x reg, :135) -----------
set_instance_assignment -name PRESERVE_REGISTER ON -to "*|gpu_pixelpipeline:igpu_pixelpipeline|textPalFetched"

# --- Option B only: sdram->dma handoff (clk_base=clk1x regs, sdram.sv:181-200)
set_instance_assignment -name PRESERVE_REGISTER ON -to "*|sdram:sdram|dma_data[*]"
set_instance_assignment -name PRESERVE_REGISTER ON -to "*|sdram:sdram|dma_wr"
```

After the instrumented synthesis, check `map.rpt` for SignalTap "node not found" warnings
and `fit.rpt` "Ignored Assignments" — same drill as the snippet documents.

## 5. Verdict matrix (decide BEFORE the capture, per the verification rule)

| dma_data (Opt B) | DMA_GPU_write | Meaning |
|---|---|---|
| mangled | mangled | SDRAM read capture confirmed on silicon → ship psx_patches/0020 (CL3) |
| clean | mangled | dma.vhd word path on silicon contradicts sim → STA/fit deep-dive on dma |
| clean | clean | mangle is GPU-internal (FIFO/decode) → re-aim at gpu fifo / gpu_poly |
| (n/a Opt A) | mangled | upstream of GPU confirmed; Option-B build bisects sdram vs dma |
| (n/a Opt A) | never fires + RECON stream clean | boundary is clean → GPU-internal |
