#!/usr/bin/env bash
# Generate the security-cart $readmemh fixtures for tb_s573_seccart.v from the
# (gitignored, copyrighted) game dumps. Writes one hex byte per line:
#   sim/secdata/pnchmn2_u1.hex   (548 bytes,  X76F041 EEPROM image, pnchmn2)
#   sim/secdata/pnchmn2_u6.hex   (8 bytes,    DS2401 serial image, pnchmn2)
#   sim/secdata/gtrfrk5m_u1.hex  (4116 bytes, ZS01 NVRAM image, gtrfrk5m)
#   sim/secdata/gtrfrk5m_u6.hex  (8 bytes,    DS2401 serial image, gtrfrk5m)
#
# Source preference: dumps/mame573/<game>.zip else /tmp/secA/*.
# If a dump is absent this exits 0 WITHOUT writing its fixtures -- the testbench then
# detects the missing fixtures and SKIPS that real-data part (so `make` stays green on
# machines without the dumps; the real assertions run wherever the dump exists).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/secdata"; mkdir -p "$OUT"

emit() { # emit <bytes-file> <out.hex>
  python3 - "$1" "$2" <<'PY'
import sys
data = open(sys.argv[1],'rb').read()
with open(sys.argv[2],'w') as f:
    for b in data: f.write(f"{b:02x}\n")
PY
}

# extract <zip> <u1name> <u6name> <out-prefix> <label>
extract() {
  local zip="$1" u1="$2" u6="$3" pfx="$4" label="$5"
  local tmp; tmp="$(mktemp -d)"
  local got=0
  if [ -f "$zip" ] && command -v unzip >/dev/null 2>&1; then
    if unzip -o -q "$zip" "$u1" "$u6" -d "$tmp" 2>/dev/null; then
      emit "$tmp/$u1" "$OUT/${pfx}_u1.hex"; emit "$tmp/$u6" "$OUT/${pfx}_u6.hex"; got=1
    fi
  fi
  if [ "$got" = 0 ] && [ -f "/tmp/secA/$u1" ] && [ -f "/tmp/secA/$u6" ]; then
    emit "/tmp/secA/$u1" "$OUT/${pfx}_u1.hex"; emit "/tmp/secA/$u6" "$OUT/${pfx}_u6.hex"; got=1
  fi
  rm -rf "$tmp"
  if [ "$got" = 1 ]; then
    echo "gen_secdata: wrote $OUT/${pfx}_u1.hex + ${pfx}_u6.hex ($label)"
  else
    echo "gen_secdata: $label dump not found -- that real-data part will SKIP"
  fi
}

extract "$ROOT/dumps/mame573/pnchmn2.zip"  gqa09ja.u1 gqa09ja.u6 pnchmn2  "pnchmn2 X76F041"
extract "$ROOT/dumps/mame573/gtrfrk5m.zip" gea26jaa.u1 gea26jaa.u6 gtrfrk5m "gtrfrk5m ZS01"
