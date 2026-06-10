#!/usr/bin/env bash
# =============================================================================
# capture.sh -- ONE command from the Mac: arm the CLUT-race SignalTap trigger
# on the DE10 (via dell's USB-Blaster II, dockerized Quartus 17.0), wait,
# export CSV, copy results back to local/signaltap/<ts>/.
#
#   tools/signaltap_573/capture.sh [timeout_seconds]   (default 300)
#
# PREREQS (see RUNBOOK.md): the INSTRUMENTED .rbf is running on the DE10
# (warm-reboot + ONE load_core), the game is parked on the operator MAIN MENU,
# and the Heisenbug frame_diff check passed. This script touches ONLY JTAG --
# it never builds, never programs the FPGA, never touches the MiSTer.
#
# The .stp is copied to a scratch dir on dell first: close_session writes the
# captured data back into the .stp, and we keep the dell repo checkout clean.
# =============================================================================
set -euo pipefail

TIMEOUT="${1:-300}"
TS="$(date +%Y%m%d_%H%M%S)"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
OUT_DIR="$REPO_ROOT/local/signaltap/$TS"
IMG="raetro/quartus:17.0"
DELL_REPO='$HOME/System573_MiSTer'   # expanded ON dell
WORK="/tmp/stp_run_$TS"              # scratch ON dell

echo "== [1/4] preflight: JTAG chain on dell =="
if ! ssh dell "docker run --rm --privileged -v /dev/bus/usb:/dev/bus/usb $IMG jtagconfig" | grep -q "DE-SoC"; then
    echo "FATAL: no DE-SoC JTAG chain visible on dell (USB-Blaster II unplugged or container/USB issue)."
    exit 1
fi

echo "== [2/4] staging scratch .stp on dell ($WORK) =="
ssh dell "mkdir -p $WORK && cp $DELL_REPO/tools/signaltap_573/clut_race.stp $WORK/run.stp"

echo "== [3/4] arming trigger (timeout ${TIMEOUT}s) -- press R/Test on the menu scene if not already there =="
# repo mounted read-only (script source); scratch dir read-write (stp + csv)
set +e
ssh dell "docker run --rm --privileged \
    -v /dev/bus/usb:/dev/bus/usb \
    -v \$HOME/System573_MiSTer:/build:ro \
    -v $WORK:/work \
    $IMG quartus_stp -t /build/tools/signaltap_573/capture_headless.tcl \
        -stp /work/run.stp -csv /work/clut_race_$TS.csv -timeout $TIMEOUT"
RC=$?
set -e

echo "== [4/4] retrieving results =="
mkdir -p "$OUT_DIR"
scp -q "dell:$WORK/clut_race_$TS.csv" "$OUT_DIR/" 2>/dev/null || true
scp -q "dell:$WORK/run.stp"           "$OUT_DIR/clut_race_${TS}_with_log.stp" 2>/dev/null || true
ssh dell "rm -rf $WORK" || true

case $RC in
  0)  echo "CAPTURE OK -> $OUT_DIR/clut_race_$TS.csv"
      echo "Interpretation guide: RUNBOOK.md section 'Reading the CSV'." ;;
  2)  echo "NO TRIGGER within ${TIMEOUT}s."
      echo " - Is the garbled menu actually on screen? (the trigger needs stage1_palReqY==491 pixels drawing)"
      echo " - Wrong-row cube may not match: do the RECON pass (clut_race_stp.tcl header) and retune textPalY bit terms."
      exit 2 ;;
  *)  echo "CAPTURE FAILED (rc=$RC). 'Trigger not compatible with device' => the running .rbf is NOT the instrumented build (or the .stp was regenerated with a changed node list/depth since that build)."
      exit 1 ;;
esac
