#!/usr/bin/env bash
# Generate the security-cart $readmemh fixtures for tb_s573_seccart.v from the
# (gitignored, copyrighted) pnchmn2 dump. Writes one hex byte per line:
#   sim/secdata/pnchmn2_u1.hex  (548 bytes, X76F041 EEPROM image)
#   sim/secdata/pnchmn2_u6.hex  (8 bytes,  DS2401 serial image)
#
# Source preference: dumps/mame573/pnchmn2.zip (gqa09ja.u1/.u6) else /tmp/secA/*.
# If neither is present this exits 0 WITHOUT writing -- the testbench then detects the
# missing fixtures and SKIPS the real-data Part 2 (so `make` stays green on machines
# without the dumps; the real assertions run wherever the dump exists).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/secdata"; mkdir -p "$OUT"
ZIP="$ROOT/dumps/mame573/pnchmn2.zip"

emit() { # emit <bytes-file> <out.hex>
  python3 - "$1" "$2" <<'PY'
import sys
data = open(sys.argv[1],'rb').read()
with open(sys.argv[2],'w') as f:
    for b in data: f.write(f"{b:02x}\n")
PY
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
got=0
if [ -f "$ZIP" ] && command -v unzip >/dev/null 2>&1; then
  if unzip -o -q "$ZIP" gqa09ja.u1 gqa09ja.u6 -d "$TMP" 2>/dev/null; then
    emit "$TMP/gqa09ja.u1" "$OUT/pnchmn2_u1.hex"
    emit "$TMP/gqa09ja.u6" "$OUT/pnchmn2_u6.hex"
    got=1
  fi
fi
if [ "$got" = 0 ] && [ -f /tmp/secA/gqa09ja.u1 ] && [ -f /tmp/secA/gqa09ja.u6 ]; then
  emit /tmp/secA/gqa09ja.u1 "$OUT/pnchmn2_u1.hex"
  emit /tmp/secA/gqa09ja.u6 "$OUT/pnchmn2_u6.hex"
  got=1
fi

if [ "$got" = 1 ]; then
  echo "gen_secdata: wrote $OUT/pnchmn2_u1.hex (548 B) + pnchmn2_u6.hex (8 B)"
else
  echo "gen_secdata: pnchmn2 dump not found -- tb_s573_seccart Part 2 will SKIP"
fi
