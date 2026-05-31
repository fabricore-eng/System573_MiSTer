#!/usr/bin/env bash
# SessionStart hook for the Konami System 573 core.
# Ensures the RTL simulation toolchain (Icarus Verilog) is available and runs
# the unit-test suite so a web session starts from a known-good baseline.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "[session-start] installing iverilog..."
    if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -qq  >/dev/null 2>&1
        sudo apt-get install -y -qq iverilog >/dev/null 2>&1
    else
        apt-get update -qq  >/dev/null 2>&1
        apt-get install -y -qq iverilog >/dev/null 2>&1
    fi
fi

if command -v iverilog >/dev/null 2>&1; then
    echo "[session-start] iverilog: $(iverilog -V 2>&1 | head -1)"
    echo "[session-start] running RTL test suite (make -C sim)..."
    make -C "$repo_root/sim" 2>&1 | sed 's/^/[sim] /'
else
    echo "[session-start] iverilog unavailable; skipping RTL test suite." >&2
fi

exit 0
