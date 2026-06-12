#!/usr/bin/env bash
# run_sio_dsr.sh - red/green NVC gate for psx_patches/0024 (SIO1 DSR cassette presence).
#
# Analyzes the CURRENT psx/rtl/sio.vhd plus tb_sio_dsr.vhd and runs the testbench.
# It deliberately does NOT auto-apply psx_patches/ (unlike elaborate.sh) so the
# pre-0024 RED baseline stays reproducible:
#
#   tools/apply_psx_patches.sh                                  # full stack
#   sim/nvc/run_sio_dsr.sh                                      # -> GREEN (0x00000085)
#   git -C psx apply -R psx_patches/0024-s573-sio1-dsr-presence.patch
#   sim/nvc/run_sio_dsr.sh                                      # -> RED   (0x00000005)
#   git -C psx apply    psx_patches/0024-s573-sio1-dsr-presence.patch
#
# The TB instantiates sio WITHOUT binding dsr_in (the 0024 port is defaulted), so
# the identical TB elaborates on both trees. Exit 0 iff "RESULT: PASS" is reported.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WD="$HERE/build/sio_dsr"

command -v nvc >/dev/null 2>&1 || { echo "error: nvc not found (brew install nvc)" >&2; exit 1; }
[ -f "$ROOT/psx/rtl/sio.vhd" ] || { echo "error: psx submodule missing. Run: git submodule update --init psx" >&2; exit 1; }

rm -rf "$WD"; mkdir -p "$WD"
NVC="nvc --std=2008 --work=work:$WD/work"

$NVC -a --relaxed "$ROOT/psx/rtl/sio.vhd" "$HERE/tb_sio_dsr.vhd"
$NVC -e tb_sio_dsr

out="$($NVC -r --exit-severity=failure tb_sio_dsr 2>&1)" || true
echo "$out"
if echo "$out" | grep -q "RESULT: PASS"; then
  echo "OK: sio_dsr GREEN (DSR presence visible + survives the CTRL-reset re-force)."
  exit 0
else
  echo "sio_dsr RED (the BIOS presence poll reads bit7=0 -> the -12 no-cassette path)." >&2
  exit 1
fi
