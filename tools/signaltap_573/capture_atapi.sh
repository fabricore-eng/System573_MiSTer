#!/usr/bin/env bash
# =============================================================================
# capture_atapi.sh -- arm the ATAPI completion-IRQ SignalTap trigger on the
# DE10 (via dell's USB-Blaster II, dockerized Quartus 17.0), wait, export CSV,
# copy results back to local/signaltap/<ts>/.
#
#   tools/signaltap_573/capture_atapi.sh [timeout_seconds]   (default 180)
#
# PREREQS: the INSTRUMENTED .rbf (dbg-signaltap-atapi-irq) is running on the
# DE10 (warm-reboot + ONE load_core of the ddrsbm .mgl), and the drive check is
# active/retrying (arm within a few s of load_core to catch it during boot).
# PASSIVE JTAG ONLY -- never builds, never programs the FPGA, never touches the
# MiSTer config. Mirrors capture.sh but for the ss_atapi_irq / trig_atapi_irq
# signal-set + trigger (passed explicitly; capture_headless.tcl defaults are clut).
# Trigger retune (RECON modes) is regenerate-the-.stp only -- NO rebuild; restage
# the .stp on dell (this script copies whatever atapi_irq.stp is in the repo).
# =============================================================================
set -euo pipefail

TIMEOUT="${1:-180}"
TS="$(date +%Y%m%d_%H%M%S)"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
OUT_DIR="$REPO_ROOT/local/signaltap/$TS"
IMG="raetro/quartus:17.0"
DELL_REPO='$HOME/System573_MiSTer'
WORK="/tmp/stp_run_atapi_$TS"

echo "== [1/4] preflight: JTAG chain on dell =="
if ! ssh dell "docker run --rm --name jtag-573 --privileged -v /dev/bus/usb:/dev/bus/usb $IMG jtagconfig" 2>/dev/null | grep -q "DE-SoC"; then
    echo "FATAL: no DE-SoC JTAG chain visible on dell (USB-Blaster II unplugged or container/USB issue)."
    exit 1
fi

echo "== [2/4] staging scratch .stp on dell ($WORK) =="
ssh dell "mkdir -p $WORK && cp $DELL_REPO/tools/signaltap_573/atapi_irq.stp $WORK/run.stp"

echo "== [3/4] arming trigger (timeout ${TIMEOUT}s) =="
set +e
mkdir -p "$OUT_DIR"
ssh dell "docker run --rm --name jtag-573 --privileged \
    -v /dev/bus/usb:/dev/bus/usb \
    -v \$HOME/System573_MiSTer:/build:ro \
    -v $WORK:/work \
    $IMG quartus_stp -t /build/tools/signaltap_573/capture_headless.tcl \
        -stp /work/run.stp -csv /work/atapi_irq_$TS.csv -timeout $TIMEOUT \
        -signal_set ss_atapi_irq -trigger trig_atapi_irq" \
  2>&1 | tee "$OUT_DIR/quartus_stp_$TS.log"
RC=${PIPESTATUS[0]}
set -e

if grep -q 'Error (261009)' "$OUT_DIR/quartus_stp_$TS.log"; then
    echo "VERDICT: ARM FAILED (261009 stp/device CRC mismatch) -- analyzer never armed (RUNBOOK CRC gate)."
    exit 3
fi
if grep -q 'Internal Error' "$OUT_DIR/quartus_stp_$TS.log"; then
    echo "VERDICT: quartus_stp CRASHED (Internal Error) -- see $OUT_DIR/quartus_stp_$TS.log"
    exit 4
fi

echo "== [4/4] retrieving results =="
scp -q "dell:$WORK/atapi_irq_$TS.csv" "$OUT_DIR/" 2>/dev/null || true
scp -q "dell:$WORK/run.stp"           "$OUT_DIR/atapi_irq_${TS}_with_log.stp" 2>/dev/null || true
ssh dell "rm -rf $WORK" || true

case $RC in
  0)  echo "CAPTURE OK -> $OUT_DIR/atapi_irq_$TS.csv"
      echo "Decode: tools/signaltap_573/read_atapi_csv.py $OUT_DIR/atapi_irq_$TS.csv" ;;
  2)  echo "NO TRIGGER within ${TIMEOUT}s."
      echo " - Is ddrsbm at/looping the BOOT CHECK drive check? Arm within a few s of load_core."
      echo " - The drive check may have STOPPED retrying (static BOOT CHECK). Re-warm-reboot, load_core,"
      echo "   and re-arm IMMEDIATELY; or retune trigger: RECON=any (irq_event), RECON=pktdispatch."
      exit 2 ;;
  *)  echo "CAPTURE FAILED (rc=$RC). 'Trigger not compatible with device' => the running .rbf is NOT this"
      echo "   instrumented build, or the .stp node list/depth changed since the build."
      exit 1 ;;
esac
