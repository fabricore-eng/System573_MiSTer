#!/bin/bash
# =============================================================================
# mister_press.sh -- Mac-side wrapper: headless button press on the de10 board.
#
# Usage: tools/mister_press.sh <test|service|coin|start|b1..b4|0xNNN> [extra args]
# Extra args pass through to mister_press.py (--hold MS --pre S --post S).
#
# Pushes tools/mister_press.py to the board if missing/stale, then runs it.
# Host alias `de10` must exist in ~/.ssh/config (root, key auth).
# =============================================================================
set -euo pipefail
HOST=de10
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PY="$HERE/mister_press.py"
REMOTE_PY=/tmp/mister_press.py

[ $# -ge 1 ] || { echo "usage: $0 <test|service|coin|start|b1..b4|0xNNN> [--hold MS --pre S --post S]" >&2; exit 2; }

# push if missing or different
LOCAL_SUM=$(shasum -a 256 "$LOCAL_PY" | cut -d' ' -f1)
REMOTE_SUM=$(ssh "$HOST" "sha256sum $REMOTE_PY 2>/dev/null | cut -d' ' -f1" || true)
if [ "$LOCAL_SUM" != "$REMOTE_SUM" ]; then
    scp -q "$LOCAL_PY" "$HOST:$REMOTE_PY"
fi

ssh "$HOST" "python3 $REMOTE_PY $*"
