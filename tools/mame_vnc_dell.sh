#!/usr/bin/env bash
# mame_vnc_dell.sh <romset> [secs] -- run a MAME romset on a TigerVNC virtual
# display on dell (headless) and serve it over VNC at localhost:5900 for an
# SSH-tunneled Mac viewer. Xvnc = virtual X display + VNC server in one (reliable
# with macOS Screen Sharing, unlike the Xvfb+x11vnc combo).
set -uo pipefail
ROM="${1:-powyakex}"
SECS="${2:-0}"
RP="dumps/mame573;dumps"
DISP=":99"
export DISPLAY="$DISP"

pkill -f "Xvnc ${DISP}"   2>/dev/null || true
pkill -f "x11vnc"          2>/dev/null || true
pkill -f "[m]ame ${ROM}"  2>/dev/null || true
pkill -f "Xvfb ${DISP}"   2>/dev/null || true
sleep 1

cd "$HOME/System573_MiSTer" || { echo "no repo dir"; exit 2; }

Xvnc "$DISP" -geometry 960x720 -depth 24 \
     -SecurityTypes VncAuth -PasswordFile "$HOME/.vnc/passwd" \
     -rfbport 5900 -AlwaysShared -desktop mame573 \
     >/tmp/mame_xvnc.log 2>&1 &
sleep 2

SECFLAG=""
[ "$SECS" != "0" ] && SECFLAG="-seconds_to_run $SECS"
nohup mame "$ROM" -rompath "$RP" -skip_gameinfo -video soft -window -nomaximize \
      -nofilter $SECFLAG >/tmp/mame_stream.log 2>&1 &
sleep 4

echo "=== status ==="
echo -n "Xvnc: "; pgrep -af "Xvnc ${DISP}" | head -1
echo -n "mame: "; pgrep -af "[m]ame ${ROM}" | head -1
echo "--- 5900 listener ---"; ss -ltn 2>/dev/null | grep 5900 || echo "NONE"
echo "--- xvnc log tail ---"; tail -4 /tmp/mame_xvnc.log 2>/dev/null
echo "--- mame log tail ---"; tail -3 /tmp/mame_stream.log 2>/dev/null
