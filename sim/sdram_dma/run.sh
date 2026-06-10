#!/usr/bin/env bash
# =============================================================================
# Level-2 GP0-corruption experiment: directed iverilog test of the 573-patched
# psx/rtl/sdram.sv DMA read path (see tb_sdram_dma.v header).
#
# Runs TWO configs and prints both verdicts:
#   control : ch4 (flash channel) idle      -- stock-shaped traffic
#   stress  : ch4 line fills at max pressure -- the 573 interleave
#
# The vendored psx/rtl/sdram.sv declares `inout reg SDRAM_DQ` (Quartus accepts,
# iverilog rejects per LRM). We sed a SIM-ONLY COPY into build/ (net port +
# internal reg + continuous assign); the vendored file is never touched.
#
# Usage: sim/sdram_dma/run.sh [GAP] [EXTRA_PLUSARGS...]
#   GAP = inter-node clk1x gap (default 6; the PAUSING->OFF->retrigger window)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WD="$HERE/build"
GAP="${1:-6}"

command -v iverilog >/dev/null 2>&1 || { echo "error: iverilog not found" >&2; exit 1; }

mkdir -p "$WD"

# --- sim-only copy of the DUT, transformed for iverilog ----------------------
#  1. `inout reg SDRAM_DQ` (Quartus-ism) -> net port + internal reg + assign
#  2. iverilog rejects module-scope use-before-declaration: relocate the early
#     `assign SDRAM_*` lines and the clk_base always-block (which reference
#     regs declared further down) to after all declarations. Pure reordering
#     of module items -- zero semantic change in Verilog.
python3 - "$ROOT/psx/rtl/sdram.sv" "$WD/sdram_sim.sv" <<'EOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(keepends=True)

# 1. DQ port shim
out = []
renames = 0
for ln in lines:
    if 'inout  reg [15:0]  SDRAM_DQ' in ln:
        ln = ln.replace('inout  reg [15:0]  SDRAM_DQ', 'inout      [15:0]  SDRAM_DQ')
    ln2 = re.sub(r'SDRAM_DQ(\s*)<=', r'SDRAM_DQ_out\1<=', ln)
    if ln2 != ln:
        renames += 1
        ln = ln2
    out.append(ln)
    if ln.strip() == 'reg [15:0] dq_reg;':
        out.append('reg [15:0] SDRAM_DQ_out;\n')
        out.append('assign SDRAM_DQ = SDRAM_DQ_out;\n')
assert renames == 4, f"expected 4 DQ drive renames, got {renames}"
lines = out

# 2. extract the early assigns (use command/chip declared later)
moved, kept = [], []
for ln in lines:
    s = ln.strip()
    if s.startswith('assign SDRAM_n') or s.startswith('assign SDRAM_CKE') or \
       s.startswith('assign {SDRAM_DQMH'):
        moved.append(ln)
    else:
        kept.append(ln)
assert len(moved) == 6, f"expected 6 early assigns, got {len(moved)}"
lines = kept

# 3. extract the clk_base always block (brace-counted)
start = next(i for i, l in enumerate(lines) if 'always @(posedge clk_base)' in l)
depth, end = 0, None
for i in range(start, len(lines)):
    depth += len(re.findall(r'\bbegin\b', lines[i]))
    depth -= len(re.findall(r'\bend\b', lines[i]))
    if depth == 0 and i > start:
        end = i
        break
assert end is not None
block = lines[start:end+1]
lines = lines[:start] + lines[end+1:]

# 4. reinsert both before the main clk always block (all decls precede it)
ins = next(i for i, l in enumerate(lines) if 'always @(posedge clk)' in l)
lines = lines[:ins] + moved + ['\n'] + block + ['\n'] + lines[ins:]

open(dst, 'w').writelines(lines)
print(f"sdram_sim.sv: shimmed DQ ({renames} drives), moved {len(moved)} assigns + clk_base block ({len(block)} lines)")
EOF

echo "== compiling =="
iverilog -g2012 -o "$WD/tb_sdram_dma.vvp" "$WD/sdram_sim.sv" "$HERE/tb_sdram_dma.v"

echo
echo "== RUN 1: control (ch4 OFF, gap=$GAP) =="
vvp "$WD/tb_sdram_dma.vvp" +ch4=0 +gap="$GAP" "${@:2}" | tee "$WD/run_ch4off.log" | tail -15

echo
echo "== RUN 2: stress (ch4 max pressure, gap=$GAP) =="
vvp "$WD/tb_sdram_dma.vvp" +ch4=1 +gap="$GAP" "${@:2}" | tee "$WD/run_ch4on.log" | tail -15

echo
echo "== summary =="
for f in run_ch4off run_ch4on; do
  echo "--- $f: $(grep -m1 'VERDICT' "$WD/$f.log" || echo 'NO VERDICT (timeout/crash?)')"
done
