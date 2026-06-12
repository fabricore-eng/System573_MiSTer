#!/usr/bin/env bash
# =============================================================================
# 2MB-VRAM red/green proof driver (psx_patches/0021-gpu-2mb-vram-10bit-y).
#
# RED   : psx tree at the 0001-0020 stack (stock 1MB GPU, Y truncated to 9 bits)
#         -> the boot upload replay MUST reproduce the real-HW font-atlas wrap
#            signature (panels uploaded to y>=512 land on y-512 over the fonts).
# GREEN : the same stream through the 0001-0021 tree (2MB VRAM, 10-bit Y)
#         -> the atlas stays intact and the panels land in (and read back from)
#            the upper half.
# HARM  : cmd_fill_demo.txt (+ cmd_texrect.txt over ss_vram.bin when available)
#         on both trees -> gra_fb_out.gra must be BYTE-IDENTICAL (y<512 work is
#         untouched by the patch).
#
# The same numeric assertions (check_vram2mb.py) failing on 0020 and passing on
# 0021 is the proof. Requires the MAME ground-truth dump gh_vram_comic.bin
# (override GH_COMIC=...) and optionally the HW dump vram_run3.bin (HW_DUMP=).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"
P21="$ROOT/psx_patches/0021-gpu-2mb-vram-10bit-y.patch"

GH_COMIC="${GH_COMIC:-$ROOT/local/mame_gate_hunt/gh_vram_comic.bin}"
[ -f "$GH_COMIC" ] || GH_COMIC="$HOME/Dev/System573_MiSTer/local/mame_gate_hunt/gh_vram_comic.bin"
HW_DUMP="${HW_DUMP:-$ROOT/local/glyph_dma/vram_run3.bin}"
[ -f "$HW_DUMP" ] || HW_DUMP="$HOME/Dev/System573_MiSTer/local/glyph_dma/vram_run3.bin"
SS_VRAM="${SS_VRAM:-$ROOT/local/ss_vram.bin}"
[ -f "$SS_VRAM" ] || SS_VRAM="$HOME/Dev/System573_MiSTer/local/ss_vram.bin"

[ -f "$GH_COMIC" ] || { echo "error: gh_vram_comic.bin not found (set GH_COMIC=)" >&2; exit 1; }
[ -f "$P21" ] || { echo "error: $P21 missing" >&2; exit 1; }

CMD="$HERE/build_vram2mb_cmd.txt"   # generated; embeds game data -> never commit
python3 "$HERE/gen_vram2mb.py" "$GH_COMIC" "$CMD" || exit 1

apply_21()  { (cd "$PSX" && git apply --reverse --check "$P21" 2>/dev/null) || (cd "$PSX" && git apply "$P21"); }
revert_21() { (cd "$PSX" && git apply --reverse --check "$P21" 2>/dev/null) && (cd "$PSX" && git apply --reverse "$P21"); return 0; }

rc=0
RES_RED=1; RES_GREEN=1; RES_HARM=1

run_tree() { # $1=tag  $2=builddir-suffix  $3=cmd  $4=vram  $5=drain
   SKIP_PATCH=1 BUILD_DIR="$HERE/build_$2" "$HERE/run.sh" "$3" "$4" 0 "$5" \
      > "$HERE/build_$2.runlog" 2>&1
   local r=$?
   [ $r -ne 0 ] && { echo "[$1] run.sh FAILED (build_$2.runlog)"; rc=1; }
   return $r
}

echo "=================================================================="
echo "== RED: 0020 tree (1MB / 9-bit Y) -- must show the wrap signature"
echo "=================================================================="
revert_21
run_tree RED red "$CMD" "" "2 ms"
python3 "$HERE/check_vram2mb.py" --mode red --log "$HERE/build_red/vram2cpu_out.log" \
        --comic "$GH_COMIC" $( [ -f "$HW_DUMP" ] && echo --hw "$HW_DUMP" ) \
        | tee "$HERE/build_red/check.txt"
RES_RED=${PIPESTATUS[0]}

echo "=================================================================="
echo "== GREEN: 0021 tree (2MB / 10-bit Y) -- must place + read back right"
echo "=================================================================="
apply_21
run_tree GREEN green "$CMD" "" "2 ms"
python3 "$HERE/check_vram2mb.py" --mode green --log "$HERE/build_green/vram2cpu_out.log" \
        --comic "$GH_COMIC" \
        | tee "$HERE/build_green/check.txt"
RES_GREEN=${PIPESTATUS[0]}

echo "=================================================================="
echo "== DO-NO-HARM: y<512 streams must be BYTE-IDENTICAL on both trees"
echo "=================================================================="
revert_21
run_tree HARM-fill-0020 harm_fill_red "$HERE/cmd_fill_demo.txt" "" "4 ms"
if [ -f "$SS_VRAM" ] && [ -f "$HERE/cmd_texrect.txt" ]; then
   run_tree HARM-tex-0020 harm_tex_red "$HERE/cmd_texrect.txt" "$SS_VRAM" "2 ms"
fi
apply_21
run_tree HARM-fill-0021 harm_fill_green "$HERE/cmd_fill_demo.txt" "" "4 ms"
if [ -f "$SS_VRAM" ] && [ -f "$HERE/cmd_texrect.txt" ]; then
   run_tree HARM-tex-0021 harm_tex_green "$HERE/cmd_texrect.txt" "$SS_VRAM" "2 ms"
fi

RES_HARM=0
if cmp -s "$HERE/build_harm_fill_red/gra_fb_out.gra" "$HERE/build_harm_fill_green/gra_fb_out.gra"; then
   echo "  PASS  fill_demo gra_fb_out.gra byte-identical 0020 vs 0021"
else
   echo "  FAIL  fill_demo gra_fb_out.gra DIFFERS between trees"; RES_HARM=1
fi
if [ -f "$HERE/build_harm_tex_red/gra_fb_out.gra" ]; then
   if cmp -s "$HERE/build_harm_tex_red/gra_fb_out.gra" "$HERE/build_harm_tex_green/gra_fb_out.gra"; then
      echo "  PASS  texrect (4bpp CLUT over ss_vram) gra_fb_out.gra byte-identical"
   else
      echo "  FAIL  texrect gra_fb_out.gra DIFFERS between trees"; RES_HARM=1
   fi
else
   echo "  SKIP  texrect do-no-harm (ss_vram.bin or cmd_texrect.txt not available)"
fi

echo "=================================================================="
echo "== VERDICT"
echo "=================================================================="
[ "$RES_RED" = 0 ]   && echo "  RED   (0020 shows the HW wrap signature): PASS" || { echo "  RED: FAIL"; rc=1; }
[ "$RES_GREEN" = 0 ] && echo "  GREEN (0021 fixes placement + readback):  PASS" || { echo "  GREEN: FAIL"; rc=1; }
[ "$RES_HARM" = 0 ]  && echo "  DO-NO-HARM (y<512 bit-identical):          PASS" || { echo "  DO-NO-HARM: FAIL"; rc=1; }
exit $rc
