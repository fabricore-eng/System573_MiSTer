#!/usr/bin/env bash
# =============================================================================
# Level-1 GP0-corruption experiment: GPU DMA-PORT ingest (tb_gpu_dma_ingest).
#
# Streams the GP0 command words through the GPU's DMA write port (the path the
# real 573 uses for the garbled draw list) instead of the bus port, then diffs
# the words the GPU's command decoder CONSUMED against the words INJECTED, and
# classifies gpu_poly.rec_textPalY (silicon corruption: 0x1EB -> 0x1E0/0x1E1).
#
# Usage:
#   sim/gpu_replay/run_dma_ingest.sh [CMD_FILE] [VRAM_FILE] [SLOWTIMING] [DRAIN_MS]
#     CMD_FILE   : command stream (default cmd_dma_quads573.txt in this dir)
#     VRAM_FILE  : raw 1024x512x2 LE VRAM preload (default "" = none; not needed
#                  for the word-level verdict)
#     SLOWTIMING : ddrram_model VRAM read latency cycles (default 0)
#     DRAIN_MS   : drain time after the last word (default "1 ms")
# Env:
#   BUILD_DIR=dir  override build dir (default sim/gpu_replay/build_dma)
#   REUSE=1        re-run the cached elaboration (generics frozen)
#   SKIP_PATCH=1   (default 1) skip tools/apply_psx_patches.sh -- the tree is
#                  expected to be patched already; keeps parallel runs safe.
#
# NVC mechanics (heap flags, library layout, FIX_POLY_DIV) follow run.sh -- see
# its header comments.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"; RTL="$PSX/rtl"
MEMSRC="$PSX/sim/system/src/mem"; TBSRC="$PSX/sim/system/src/tb"
WD="${BUILD_DIR:-$HERE/build_dma}"

CMD_FILE_IN="${1:-$HERE/cmd_dma_quads573.txt}"
VRAM_FILE_IN="${2:-}"
SLOWTIMING="${3:-0}"
DRAIN_MS="${4:-1 ms}"
REUSE="${REUSE:-0}"
SKIP_PATCH="${SKIP_PATCH:-1}"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -d "$RTL" ] || { echo "error: psx submodule missing" >&2; exit 1; }
[ -f "$CMD_FILE_IN" ] || { echo "error: command file not found: $CMD_FILE_IN" >&2; exit 1; }

NVC="nvc --std=2008 --ieee-warnings=off --messages=compact"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }
# ddrram_model declares a 2**28-int VRAM array (~1 GB); raise NVC heap limits.
NVC_MEM="-M 3g -H 6g"

PRELOAD_VRAM="'0'"
VRAM_BASENAME="vram_init.bin"

if [ "$REUSE" = "1" ]; then
  ls "$WD"/*.elab >/dev/null 2>&1 || true
  cd "$WD"
  echo "== REUSE=1: re-running cached design in $WD =="
  cp "$CMD_FILE_IN" "$WD/cmd_stream.txt"
  [ -n "$VRAM_FILE_IN" ] && cp "$VRAM_FILE_IN" "$WD/$VRAM_BASENAME"
else
  if [ "$SKIP_PATCH" != "1" ]; then
    "$ROOT/tools/apply_psx_patches.sh" >/dev/null 2>&1 || true
  fi
  rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"

  cp "$CMD_FILE_IN" "$WD/cmd_stream.txt"
  if [ -n "$VRAM_FILE_IN" ]; then
    [ -f "$VRAM_FILE_IN" ] || { echo "error: VRAM file not found: $VRAM_FILE_IN" >&2; exit 1; }
    cp "$VRAM_FILE_IN" "$WD/$VRAM_BASENAME"
    PRELOAD_VRAM="'1'"
    echo "== VRAM preload: $VRAM_FILE_IN =="
  fi

  echo "== analyzing mem library =="
  analyze mem "$MEMSRC/dpram.vhd" "$MEMSRC/RamMLAB.vhd" \
              "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd" \
              "$RTL/SyncFifoFallThroughMLAB.vhd" "$RTL/SyncRam.vhd"

  echo "== analyzing psx GPU subset =="
  analyze psx "$MEMSRC/dpram.vhd"
  CORE=(export divider pGPU mul32u mul9s gpu_fillVram gpu_cpu2vram gpu_vram2vram \
        gpu_vram2cpu gpu_line gpu_rect gpu_poly gpu_pixelpipeline gpu_overlay \
        gpu_dither gpu_videoout_async gpu_videoout_sync gpu_crosshair \
        justifier_sensor gpu_videoout gpu)
  files=(); for f in "${CORE[@]}"; do files+=("$RTL/$f.vhd"); done
  analyze psx "${files[@]}"

  echo "== analyzing tb library (upstream pure-VHDL models) =="
  analyze tb "$TBSRC/globals.vhd" "$TBSRC/ddrram_model.vhd"

  echo "== analyzing tb_gpu_dma_ingest =="
  analyze tb "$HERE/tb_gpu_dma_ingest.vhd"

  echo "== elaborating tb_gpu_dma_ingest (PRELOAD_VRAM=$PRELOAD_VRAM SLOWTIMING=$SLOWTIMING) =="
  $NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -e tb_gpu_dma_ingest --stats --no-collapse \
       -gPRELOAD_VRAM="$PRELOAD_VRAM" -gVRAM_FILE="$VRAM_BASENAME" \
       -gCMD_FILE="cmd_stream.txt" -gSLOWTIMING=$SLOWTIMING \
       -gDRAIN_MS="$DRAIN_MS"
fi

echo "== running tb_gpu_dma_ingest =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -r tb_gpu_dma_ingest --stats

echo
echo "== VERDICT: injected vs fifo-written vs decoder-consumed =="
python3 - "$WD/cmd_stream.txt" "$WD/dma_ingest_tap.log" <<'EOF'
import sys
cmdf, tapf = sys.argv[1], sys.argv[2]

inj = []
for ln in open(cmdf):
    t = ln.split('#')[0].split()
    if len(t) == 3 and int(t[0], 16) % 16 == 0:
        inj.append(int(t[2], 16))

wr, rd, paly = [], [], []
for ln in open(tapf):
    t = ln.split()
    if not t: continue
    if t[0] == 'WR':   wr.append(int(t[1], 16))
    elif t[0] == 'RD': rd.append(int(t[1], 16))
    elif t[0] == 'PALY':
        # the log is chronological: a PALY line before the first fifo write is
        # the register's reset value (0x000), not a decode -- skip it
        if wr:
            paly.append((int(t[1], 16), int(t[3], 16)))

def diff(name, a, b):
    bad = 0
    n = max(len(a), len(b))
    for i in range(n):
        x = a[i] if i < len(a) else None
        y = b[i] if i < len(b) else None
        if x != y:
            bad += 1
            if bad <= 10:
                xs = f"{x:08X}" if x is not None else "--------"
                ys = f"{y:08X}" if y is not None else "--------"
                xor = f"{(x ^ y):08X}" if (x is not None and y is not None) else "n/a"
                print(f"  MISMATCH {name}[{i}]: {xs} vs {ys}  xor={xor}")
    return bad

print(f"injected GP0 words : {len(inj)}")
print(f"fifo writes (WR)   : {len(wr)}")
print(f"decoder reads (RD) : {len(rd)}")
bad  = diff("inj-vs-WR", inj, wr)
bad += diff("inj-vs-RD", inj, rd)

print(f"rec_textPalY values seen: {['0x%03X (%d)' % (y, y) for y, x in paly]}")
clean_y  = all(y == 0x1EB for y, x in paly)
sig      = [y for y, x in paly if y in (0x1E0, 0x1E1)]

if bad == 0 and clean_y and paly:
    print("VERDICT: CLEAN -- DMA-port ingest is word-exact and decodes CLUT row 0x1EB (491).")
    sys.exit(0)
elif bad == 0 and not paly:
    print("VERDICT: INCONCLUSIVE -- no PALY decode seen (poly never decoded; check stream/drain).")
    sys.exit(3)
else:
    if sig:
        print(f"VERDICT: REPRO -- silicon-signature corruption (rec_textPalY in 0x1E0/0x1E1 family): {sig}")
    else:
        print("VERDICT: MISMATCH -- words differ but NOT the silicon 480/481 signature; investigate.")
    sys.exit(2)
EOF
