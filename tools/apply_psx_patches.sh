#!/usr/bin/env bash
# Apply the System 573's local modifications to the vendored PSX_MiSTer submodule.
#
# psx/ is a git submodule pinned to an upstream SHA we cannot push to, but the 573
# integration must edit the PlayStation core (EXP1 routing, later 2 MB VRAM, DMA ch5).
# Those GPL-2.0 edits are kept as isolated, offer-back-able patch files under
# psx_patches/ and (re)applied to the submodule working tree before any sim or Quartus
# build. The submodule pointer itself never moves.
#
# Safe + idempotent: uses reverse-apply checks so it never re-applies an applied patch,
# and only ever resets the FILES A PATCH TOUCHES (never your unrelated psx/ edits), and
# only when a hunk is in a conflicted/partial state. --check never writes.
#
# Usage:  tools/apply_psx_patches.sh            # apply (idempotent)
#         tools/apply_psx_patches.sh --check     # report apply-ability, write nothing
#         tools/apply_psx_patches.sh --revert    # remove our patches (reverse-apply)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSX="$ROOT/psx"
PIN=67153439fbb8e85e4108b9f0ff474d37aa6f7f5b
PATCHES=( "$ROOT/psx_patches/0001-s573-exp1-widening.patch" \
          "$ROOT/psx_patches/0002-s573-nvc-cd-positionInIndex-init.patch" \
          "$ROOT/psx_patches/0003-s573-nvc-gpu-videoout-linemax-clamp.patch" \
          "$ROOT/psx_patches/0004-s573-cpu-icache-redirect-fix.patch" )

if [ ! -e "$PSX/.git" ]; then
  echo "error: psx submodule not initialised. Run: git submodule update --init psx" >&2
  exit 1
fi
cd "$PSX"
mode="${1:-apply}"

# files a patch touches (relative to psx/), for scoped resets only
touched_files() { for p in "${PATCHES[@]}"; do sed -n 's#^+++ b/##p' "$p"; done | sort -u; }

case "$mode" in
  --check)
    rc=0
    for p in "${PATCHES[@]}"; do
      [ -f "$p" ] || { echo "error: missing patch $p" >&2; exit 1; }
      if   git apply --reverse --check "$p" 2>/dev/null; then echo "already applied:  $(basename "$p")"
      elif git apply           --check "$p" 2>/dev/null; then echo "applies cleanly:  $(basename "$p")"
      else echo "WILL NOT APPLY:   $(basename "$p")"; git apply --check "$p" || true; rc=1
      fi
    done
    exit $rc
    ;;
  --revert)
    for ((i=${#PATCHES[@]}-1; i>=0; i--)); do
      p="${PATCHES[$i]}"
      if git apply --reverse --check "$p" 2>/dev/null; then git apply --reverse "$p"; fi
    done
    echo "psx: reverted local patches (pristine pinned core)."
    exit 0
    ;;
  apply|"")
    head="$(git rev-parse HEAD)"
    [ "$head" = "$PIN" ] || echo "warning: psx at $head, expected pinned $PIN; patches may not apply cleanly." >&2
    for p in "${PATCHES[@]}"; do
      [ -f "$p" ] || { echo "error: missing patch $p" >&2; exit 1; }
      if git apply --reverse --check "$p" 2>/dev/null; then
        echo "already applied: $(basename "$p")"
      elif git apply --check "$p" 2>/dev/null; then
        git apply "$p"; echo "applied: $(basename "$p")"
      else
        # partial/conflicted: reset ONLY this patch's files to the pinned state, then apply
        echo "note: resetting patch-touched files to pinned state, then applying $(basename "$p")" >&2
        # shellcheck disable=SC2046
        git checkout -- $(touched_files)
        git apply "$p"; echo "applied (after reset): $(basename "$p")"
      fi
    done
    exit 0
    ;;
  *)
    echo "usage: $0 [apply|--check|--revert]" >&2; exit 2
    ;;
esac
