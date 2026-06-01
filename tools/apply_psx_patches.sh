#!/usr/bin/env bash
# Apply the System 573's local modifications to the vendored PSX_MiSTer submodule.
#
# psx/ is a git submodule pinned to an upstream SHA we cannot push to. Our edits to
# the PlayStation core (GPL-2.0, kept as isolated, offer-back-able diffs) therefore
# live as patch files under psx_patches/ and are (re)applied to the submodule working
# tree before any sim or Quartus build. The submodule pointer itself never moves.
#
# Idempotent: resets the patched files to the pinned revision, then re-applies, so it
# is safe to run repeatedly and after a fresh `git submodule update`.
#
# Usage:  tools/apply_psx_patches.sh           # apply
#         tools/apply_psx_patches.sh --check    # verify they apply cleanly, don't write
#         tools/apply_psx_patches.sh --revert    # restore the pristine pinned core
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSX="$ROOT/psx"
PIN=67153439fbb8e85e4108b9f0ff474d37aa6f7f5b
PATCHES=( "$ROOT/psx_patches/0001-s573-exp1-widening.patch" )

if [ ! -e "$PSX/.git" ]; then
  echo "error: psx submodule not initialised. Run: git submodule update --init psx" >&2
  exit 1
fi
cd "$PSX"

mode="${1:-apply}"

# Restore tracked files to the pinned revision so patches always apply against a known base.
git checkout -q -- . 2>/dev/null || true

if [ "$mode" = "--revert" ]; then
  echo "psx: reverted to pristine pinned core ($PIN)."
  exit 0
fi

head="$(git rev-parse HEAD)"
if [ "$head" != "$PIN" ]; then
  echo "warning: psx submodule at $head, expected pinned $PIN; patches may not apply cleanly." >&2
fi

for p in "${PATCHES[@]}"; do
  if [ ! -f "$p" ]; then echo "error: missing patch $p" >&2; exit 1; fi
  if ! git apply --check "$p" 2>/dev/null; then
    echo "error: patch does not apply cleanly: $p" >&2
    git apply --check "$p"   # re-run to surface the reason
    exit 1
  fi
done

if [ "$mode" = "--check" ]; then
  echo "psx patches apply cleanly (not written)."
  exit 0
fi

for p in "${PATCHES[@]}"; do git apply "$p"; done
echo "psx patches applied (${#PATCHES[@]}): EXP1 widening for the System 573 fabric."
