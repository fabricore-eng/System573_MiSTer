#!/usr/bin/env bash
# run_dma_ch5.sh - the S1 discriminator: NVC sim of the REAL patched psx/rtl/dma.vhd
# channel-5 (System 573 ATAPI) path against the implemented rtl/atapi.v contract.
#
# tb_cdboot.v validates atapi.v against a Verilog BFM *of* dma.vhd; this gate
# validates the real VHDL engine itself (BIOS arm replayed verbatim from
# local/cd_adjudication/atapi_trace.txt). See sim/nvc/tb_dma_ch5.vhd.
#
# Usage: sim/nvc/run_dma_ch5.sh     # exit !=0 on any contract violation
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSX="$ROOT/psx"; RTL="$PSX/rtl"; MEMSRC="$PSX/sim/system/src/mem"
WD="$HERE/build_dma_ch5"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -d "$RTL" ] || { echo "error: psx submodule missing. Run: git submodule update --init psx" >&2; exit 1; }

# Ensure the psx_patches (incl. 0023, the ch5 patch under test) are applied.
"$ROOT/tools/apply_psx_patches.sh" >/dev/null

rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"
NVC="nvc --std=2008"
analyze() { $NVC --work="$1:$WD/$1" -L "$WD" -a --relaxed "${@:2}"; }

# mem library: just the two fifos dma.vhd instantiates (+ their deps, none).
analyze mem "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd"

# work: the REAL patched dma.vhd + the testbench.
analyze work "$RTL/dma.vhd" "$HERE/tb_dma_ch5.vhd"

$NVC --work="work:$WD/work" -L "$WD" -e tb_dma_ch5

echo "== running tb_dma_ch5 =="
$NVC --work="work:$WD/work" -L "$WD" -r --exit-severity=failure tb_dma_ch5 2>&1 | tee "$WD/run.log"
grep -q "RESULT: PASS" "$WD/run.log" || { echo "tb_dma_ch5: FAIL"; exit 1; }
echo "OK: tb_dma_ch5 PASS"
