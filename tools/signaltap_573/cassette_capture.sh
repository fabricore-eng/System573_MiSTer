#!/usr/bin/env bash
# =============================================================================
# cassette_capture.sh -- ONE command from the Mac: arm the X76F100 cassette-read
# SignalTap trigger on the DE10 (via dell's USB-Blaster II, dockerized Quartus
# 17.0), wait, export CSV, copy results back to local/signaltap/<ts>/.
#
#   tools/signaltap_573/cassette_capture.sh [timeout_seconds]   (default 300)
#
# This is the cassette analogue of capture.sh (the CLUT probe). It touches ONLY
# JTAG -- never builds, never programs the FPGA, never touches the MiSTer.
#
# PREREQS (see RUNBOOK section "Cassette capture"): the INSTRUMENTED .rbf from
# the dbg-signaltap-cassette branch is running on the DE10 (warm-reboot + ONE
# load via the hypbbc2p install .mgl), and the installer is at / approaching its
# security-cassette read (the -11N wall). The cassette read fires once early in
# the installer, so ARM AT T0+5s right after the load (the boot-window flow in
# RUNBOOK) -- ROM streaming delays the game's first cassette poke, the race is
# easily won, no input injection needed.
#
# The .stp is copied to a scratch dir on dell first (close_session writes the
# captured log back into the .stp; keep the dell checkout clean).
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

# Cassette signal-set / trigger names (from cassette_read_stp.tcl).
SIGNAL_SET="ss_cassette_read"
TRIGGER="trig_cassette_read"

echo "== [1/4] preflight: JTAG chain on dell =="
if ! ssh dell "docker run --rm --name jtag-573 --privileged -v /dev/bus/usb:/dev/bus/usb $IMG jtagconfig" | grep -q "DE-SoC"; then
    echo "FATAL: no DE-SoC JTAG chain visible on dell (USB-Blaster II unplugged or container/USB issue)."
    exit 1
fi

echo "== [2/4] staging scratch .stp on dell ($WORK) =="
ssh dell "mkdir -p $WORK && cp $DELL_REPO/tools/signaltap_573/cassette_read.stp $WORK/run.stp"

echo "== [3/4] arming '$TRIGGER' (timeout ${TIMEOUT}s) -- the installer's cassette read fires early; arm right after load =="
set +e
mkdir -p "$OUT_DIR"
ssh dell "docker run --rm --name jtag-573 --privileged \
    -v /dev/bus/usb:/dev/bus/usb \
    -v \$HOME/System573_MiSTer:/build:ro \
    -v $WORK:/work \
    $IMG quartus_stp -t /build/tools/signaltap_573/capture_headless.tcl \
        -stp /work/run.stp -csv /work/cassette_$TS.csv -timeout $TIMEOUT \
        -signal_set $SIGNAL_SET -trigger $TRIGGER" \
  2>&1 | tee "$OUT_DIR/quartus_stp_$TS.log"
RC=${PIPESTATUS[0]}
set -e

# Arm failures PRINT without throwing (RUNBOOK CRC gate). Grade from the full log.
if grep -q 'Error (261009)' "$OUT_DIR/quartus_stp_$TS.log"; then
    echo "VERDICT: ARM FAILED (261009 stp/device CRC mismatch) -- the analyzer never armed."
    echo " - device crc[] ties must match the .stp CRC attr (RUNBOOK 'CRC gate')."
    exit 3
fi
if grep -q 'Internal Error' "$OUT_DIR/quartus_stp_$TS.log"; then
    echo "VERDICT: quartus_stp CRASHED (Internal Error) -- see $OUT_DIR/quartus_stp_$TS.log"
    exit 4
fi

echo "== [4/4] retrieving results =="
scp -q "dell:$WORK/cassette_$TS.csv" "$OUT_DIR/" 2>/dev/null || true
scp -q "dell:$WORK/run.stp"          "$OUT_DIR/cassette_${TS}_with_log.stp" 2>/dev/null || true
ssh dell "rm -rf $WORK" || true

case $RC in
  0)  echo "CAPTURE OK -> $OUT_DIR/cassette_$TS.csv"
      echo "DECODE:  python3 tools/signaltap_573/read_stp_csv.py $OUT_DIR/cassette_$TS.csv info"
      echo "         python3 tools/signaltap_573/read_stp_csv.py $OUT_DIR/cassette_$TS.csv \\"
      echo "             dump --signals state,bytec,rd_addr,data_rdata,sda_o,shift,d_q --range <trig-200>:<trig+10>"
      echo "Interpretation: RUNBOOK section 'Reading the cassette CSV'." ;;
  2)  echo "NO TRIGGER within ${TIMEOUT}s."
      echo " - Did the installer actually run + reach the cassette read? (-11N wall, or just before it.)"
      echo " - The read fires ONCE early; re-arm right after a fresh de-confounded load_core."
      echo " - Localize with RECON: regen the .stp with RECON=anyread (state==ST_READ, any bitc)"
      echo "   or RECON=rtr (response-to-reset). NO rebuild needed -- all nodes are trigger inputs."
      exit 2 ;;
  *)  echo "CAPTURE FAILED (rc=$RC). 'Trigger not compatible with device' => the running .rbf is NOT the"
      echo "instrumented cassette build (or the .stp node list/depth changed since that build)."
      exit 1 ;;
esac
