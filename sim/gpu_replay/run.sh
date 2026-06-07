#!/usr/bin/env bash
# =============================================================================
# GPU-replay NVC rig: analyze + elaborate + run tb_gpu_replay, then render the
# captured framebuffer .gra dumps to PNG via tools/gra2png.py.
#
# Stands the vendored psx.gpu up standalone and replays a GP0/GP1 command stream
# into it (no CPU / BIOS / full system), capturing:
#   build/gra_fb_out.gra      raw VRAM-as-drawn, 1024x512  (the direct render)
#   build/gra_fb_out_vga.gra  displayed video,    640x480  (post display crop)
# Both are rendered to build/*.png.
#
# Usage:
#   sim/gpu_replay/run.sh [CMD_FILE] [VRAM_FILE] [SLOWTIMING] [DRAIN_MS]
#     CMD_FILE   : command-stream text file (default cmd_fill_demo.txt in this dir)
#     VRAM_FILE  : raw 1024x512x2 LE VRAM image to preload (default ""=none)
#     SLOWTIMING : ddrram_model VRAM read latency in cycles (default 0 = ideal)
#     DRAIN_MS   : drain time after last command, NVC time literal (default "4 ms")
#
# Env:
#   REUSE=1   re-run the already-elaborated design (skip analyze/elaborate); the
#             CMD/VRAM/SLOWTIMING generics are FIXED at the cached build values.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"; RTL="$PSX/rtl"
MEMSRC="$PSX/sim/system/src/mem"; TBSRC="$PSX/sim/system/src/tb"
NVCDIR="$ROOT/sim/nvc"
WD="$HERE/build"

CMD_FILE_IN="${1:-$HERE/cmd_fill_demo.txt}"
VRAM_FILE_IN="${2:-}"
SLOWTIMING="${3:-0}"
DRAIN_MS="${4:-4 ms}"
REUSE="${REUSE:-0}"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -d "$RTL" ] || { echo "error: psx submodule missing. Run: git submodule update --init psx" >&2; exit 1; }
[ -f "$CMD_FILE_IN" ] || { echo "error: command file not found: $CMD_FILE_IN" >&2; exit 1; }

NVC="nvc --std=2008 --ieee-warnings=off --messages=compact"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }
# ddrram_model declares a 2**28-int VRAM array (~1 GB); raise NVC heap limits.
NVC_MEM="-M 3g -H 6g"

PRELOAD_VRAM="'0'"
VRAM_BASENAME="vram_init.bin"

if [ "$REUSE" = "1" ]; then
  [ -f "$WD/TB_GPU_REPLAY.elab" ] || ls "$WD"/*.elab >/dev/null 2>&1 || {
    echo "error: REUSE=1 but no elaborated design in $WD; run once without REUSE first" >&2; exit 1; }
  cd "$WD"
  echo "== REUSE=1: re-running cached design in $WD =="
  # still stage the (possibly new) command/VRAM files
  cp "$CMD_FILE_IN" "$WD/cmd_stream.txt"
  [ -n "$VRAM_FILE_IN" ] && cp "$VRAM_FILE_IN" "$WD/$VRAM_BASENAME"
else
  "$ROOT/tools/apply_psx_patches.sh" >/dev/null 2>&1 || true
  rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"

  cp "$CMD_FILE_IN" "$WD/cmd_stream.txt"
  if [ -n "$VRAM_FILE_IN" ]; then
    [ -f "$VRAM_FILE_IN" ] || { echo "error: VRAM file not found: $VRAM_FILE_IN" >&2; exit 1; }
    cp "$VRAM_FILE_IN" "$WD/$VRAM_BASENAME"
    PRELOAD_VRAM="'1'"
    echo "== VRAM preload: $VRAM_FILE_IN ($(wc -c < "$VRAM_FILE_IN") bytes) =="
  fi

  echo "== analyzing mem library =="
  analyze mem "$MEMSRC/dpram.vhd" "$MEMSRC/RamMLAB.vhd" \
              "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd" \
              "$RTL/SyncFifoFallThroughMLAB.vhd" "$RTL/SyncRam.vhd"

  echo "== analyzing psx GPU subset =="
  analyze psx "$MEMSRC/dpram.vhd"
  # Minimal slice of the core needed by psx.gpu (the GPU + its sub-drawers +
  # videoout + the small helpers they reference). Order = upstream dependency.
  CORE=(export divider pGPU mul32u mul9s gpu_fillVram gpu_cpu2vram gpu_vram2vram \
        gpu_vram2cpu gpu_line gpu_rect gpu_poly gpu_pixelpipeline gpu_overlay \
        gpu_dither gpu_videoout_async gpu_videoout_sync gpu_crosshair \
        justifier_sensor gpu_videoout gpu)
  files=(); for f in "${CORE[@]}"; do files+=("$RTL/$f.vhd"); done
  analyze psx "${files[@]}"

  echo "== analyzing tb library (upstream pure-VHDL models) =="
  analyze tb "$TBSRC/globals.vhd" "$TBSRC/ddrram_model.vhd" "$TBSRC/framebuffer.vhd"

  echo "== analyzing tb_gpu_replay =="
  analyze tb "$HERE/tb_gpu_replay.vhd"

  echo "== elaborating tb_gpu_replay (PRELOAD_VRAM=$PRELOAD_VRAM SLOWTIMING=$SLOWTIMING) =="
  # NB: NVC string generics take the BARE value (no VHDL quotes); quoting the
  # value embeds literal '"' chars into the string and the file open then fails.
  # --no-collapse: keep combinational signals (e.g. texdata_raw / CLUTaddrB /
  # CLUTDataB / texdata_palette, which NVC would otherwise collapse away) NAMEABLE
  # so the DBG_TAP8 external-name taps can reach them.
  $NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -e tb_gpu_replay --stats --no-collapse \
       -gPRELOAD_VRAM="$PRELOAD_VRAM" -gVRAM_FILE="$VRAM_BASENAME" \
       -gCMD_FILE="cmd_stream.txt" -gSLOWTIMING=$SLOWTIMING \
       -gDRAIN_MS="$DRAIN_MS"
fi

echo "== running tb_gpu_replay (SLOWTIMING=$SLOWTIMING) =="
$NVC $NVC_MEM --work="tb:$WD/tb" -L "$WD" -r tb_gpu_replay --stats

echo
echo "== rendering .gra -> PNG =="
for g in gra_fb_out gra_fb_out_vga; do
  if [ -s "$WD/$g.gra" ]; then
    python3 "$ROOT/tools/gra2png.py" "$WD/$g.gra" "$WD/$g.png" || true
  fi
done

echo
echo "== outputs in $WD =="
ls -la "$WD"/*.gra "$WD"/*.png 2>/dev/null || true
