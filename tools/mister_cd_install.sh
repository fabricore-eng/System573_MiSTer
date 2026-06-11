#!/usr/bin/env bash
# =============================================================================
# mister_cd_install.sh -- headless hypbbc2p CD-install runner for the DE10.
#
# TEMPLATE for the orchestrator: written 2026-06-11 ahead of the first real
# CD-install attempt. Review/edit the poll patterns + budgets after the build
# lands, then run under a held devlock. DO NOT run casually -- it kills the
# running MiSTer Main on the target and reboots the board.
#
# FLOW (each step is a function; see main() at the bottom):
#   1. require_devlock      caller must ALREADY hold the device lock (we verify,
#                           we never acquire for you -- the orchestrator owns it)
#   2. set_cfg_cd           cp config/System573.CFG.cd -> System573.CFG on the
#                           board (bit 93 = 1 -> "573 Boot Device" = CD-ROM)
#   3. reboot_fresh         lock-checked reboot via the hub devlock tool, wait
#                           for ssh back, RE-ACQUIRE the lock (reboot wipes it),
#                           verify /proc/uptime < 60 s (de-confounded bridge)
#   4. launch_mgl           killall MiSTer; relaunch Main with the 573 rbf + the
#                           hypbbc2p install .mgl, stdout/err -> /tmp/mgl.log
#   5. poll_load_lines      wait until /tmp/mgl.log shows the deterministic load
#                           lines (Selected file / 16777216 / hypbbc2p.chd /
#                           index-251 cdinfo traffic)
#   6. install_watch        screenshot every WATCH_IVAL s + size/luma/pixel-hash
#                           log, until the screen is STATIC > STATIC_SECS or the
#                           BUDGET_SECS cap; all frames + metrics -> ART_DIR
#   7. post_install_stop    STOP. Capture a final evidence tail and exit with
#                           the board UNTOUCHED. See OPEN QUESTION below.
#   8. artifacts            everything under local/cd_install_<ts>/ (frames,
#                           metrics.tsv, mgl.log pulled from the board, notes)
#
# =============================================================================
# *** OPEN QUESTION -- POST-INSTALL BOOT STRATEGY (deliberately NOT solved) ***
# =============================================================================
# Real-HW install flow: DIP SW4 = CD-boot, install runs, then the operator flips
# the DIP and the 573 warm-resets into the now-programmed onboard flash. Our
# headless equivalent is NOT a restart+relaunch:
#
#   - The .mgl loads flash16m_blank.bin on EVERY launch (F-index 2). After the
#     install, the programmed flash image lives ONLY in SDRAM on the board. A
#     devlock-restart + relaunch of the same .mgl would re-blank it and (with
#     NVRAM re-blanked too) just re-enter the installer. The naive step-7
#     "swap System573.CFG.flash in and relaunch" DESTROYS the install.
#   - The core reads the boot-device DIP from status[93] LIVE (rtl/emu.sv:1864
#     wires status[93] straight in), but Main only pushes status changes from
#     the OSD; rewriting config/System573.CFG on disk does NOT update a running
#     core. There is no headless OSD-flip primitive today.
#   - Candidate strategies for the orchestrator to pick (NOT implemented here):
#       (a) let the installer's own end-of-install reset re-enter the BIOS with
#           NVRAM now holding the installed signature -- observe whether the
#           BIOS then boots flash even with DIP=CD (some 573 BIOSes re-enter
#           install; evidence will tell);
#       (b) a /dev/MiSTer_cmd or user_io status-poke primitive (needs Main-side
#           support -- investigate before the next session);
#       (c) accept one re-blank: save the SDRAM flash back to SD first (needs a
#           core-side dump path that does not exist yet), then relaunch with a
#           REAL flash image (hbb2pflash.bin) via an edited .mgl -- the
#           hyperbbc-style direct-flash boot we already know works.
#   - THEREFORE step 7 here only: swaps NOTHING, restarts NOTHING, keeps
#     capturing evidence, and prints:
#         "install completed; post-install boot strategy TBD by orchestrator"
#     The board is left exactly as the installer finished -- SDRAM state intact.
# =============================================================================
#
# CONFIG FILES (staged 2026-06-11, source-grounded against Main user_io.cpp):
#   de10:/media/fat/config/System573.CFG.cd     16 bytes, byte[11]=0x20 (bit 93=1)
#   de10:/media/fat/config/System573.CFG.flash  16 bytes, all zero     (bit 93=0)
# Format: the .CFG is the raw 16-byte cur_status array (user_io.cpp:481
# `static char cur_status[16]`), bit N -> byte N/8, bit N%8 LSB-first
# (user_io.cpp:536). No size gate on load (FileLoad reads up to 16). Main
# force-sets bit 0 (reset) after load, so the file's bit 0 is ignored.
# Verified identical layout in the de10's installed Main (250828, commit
# 3d14fe8) and master.
#
# USAGE:
#   tools/dell_coord.sh devlock de10 acquire 573        # orchestrator holds it
#   tools/mister_cd_install.sh [--host de10] [--who 573] [--budget 720]
#                              [--ival 20] [--static 60] [--allow-partial]
#
# Requires: ssh alias for the target board, the hub checkout at
# ~/Dev/mister-dev-hub (devlock reboot), python3 (PIL optional -- luma falls
# back to file-size-only metrics without it).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
HUB="${HUB:-$HOME/Dev/mister-dev-hub}"
COORD="$HUB/tools/dell_coord.sh"

# ---------------------------------------------------------------- parameters
HOST="de10"                 # ssh alias of the target board (NOT the SuperStation)
WHO="573"                   # devlock owner key the caller acquired with
BUDGET_SECS=720             # step-6 hard cap (12 min)
WATCH_IVAL=20               # seconds between install-watch screenshots
STATIC_SECS=60              # consecutive-identical-frames window => "static"
ALLOW_PARTIAL=0             # 1 = step 5 warns instead of failing on missing patterns
RBF="/media/fat/_Console/Konami_System_573.rbf"
MGL="/media/fat/_Console/Hyper Bishi Bashi Champ 2P (573).mgl"
CFG_DIR="/media/fat/config"
CFG_LIVE="$CFG_DIR/System573.CFG"
CFG_CD="$CFG_DIR/System573.CFG.cd"
CFG_FLASH="$CFG_DIR/System573.CFG.flash"   # staged; NOT used by step 7 (see header)
MGL_LOG="/tmp/mgl.log"
SHOT_DIR="/media/fat/screenshots"

while [ $# -gt 0 ]; do case "$1" in
  --host)   HOST="$2"; shift 2;;
  --who)    WHO="$2"; shift 2;;
  --budget) BUDGET_SECS="$2"; shift 2;;
  --ival)   WATCH_IVAL="$2"; shift 2;;
  --static) STATIC_SECS="$2"; shift 2;;
  --allow-partial) ALLOW_PARTIAL=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

TS="$(date +%Y%m%d_%H%M%S)"
ART_DIR="$ROOT/local/cd_install_$TS"
mkdir -p "$ART_DIR"
RUNLOG="$ART_DIR/runner.log"
METRICS="$ART_DIR/metrics.tsv"

# ---------------------------------------------------------------- helpers
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$RUNLOG"; }
die() { log "FATAL: $*"; exit 1; }

# ssh with the banner noise filtered from stderr (keeps real errors).
sshq() {
  ssh "$HOST" "$@" \
    2> >(grep -viE "quantum|upgraded|vulnerable|store now|openssh" >&2 || true)
}

# mean luma + decoded-pixel hash of a PNG; falls back to file size + byte md5
# when PIL is unavailable. Output: "<luma|NA>\t<hash>"
frame_metric() {
  python3 - "$1" <<'PY'
import sys, hashlib
p = sys.argv[1]
try:
    from PIL import Image
    im = Image.open(p).convert("L")
    px = im.tobytes()
    luma = sum(px) / len(px)
    print(f"{luma:.2f}\t{hashlib.md5(px).hexdigest()}")
except Exception:
    b = open(p, "rb").read()
    print(f"NA\t{hashlib.md5(b).hexdigest()}")
PY
}

# trigger one screenshot on the board and pull the newest PNG to $1.
# Tracks the remote filename in PULL_SHOT_REMOTE: if the board stops honoring
# the screenshot trigger, the "newest" file never changes and we'd re-pull a
# STALE frame -- the caller must treat an unchanged remote name as no-new-frame
# (otherwise a dead trigger masquerades as a static screen).
PULL_SHOT_REMOTE=""
pull_shot() {
  local out="$1"
  sshq "echo screenshot > /dev/MiSTer_cmd 2>/dev/null || true; sleep 2" || true
  local newest
  newest="$(sshq "ls -t $SHOT_DIR/*/*.png $SHOT_DIR/*.png 2>/dev/null | head -1" || true)"
  [ -n "$newest" ] || return 1
  PULL_SHOT_REMOTE="$newest"
  sshq "cat '$newest'" > "$out" 2>/dev/null || return 1
  [ -s "$out" ]
}

# ---------------------------------------------------------------- step 1
require_devlock() {
  log "step 1: verifying devlock on $HOST is held by '$WHO' (we never acquire it for you)"
  local owner
  owner="$(sshq "cat /tmp/devtest.lock/owner 2>/dev/null" || true)"
  [ -n "$owner" ] || die "devlock on $HOST is FREE. Acquire it first: $COORD devlock $HOST acquire $WHO"
  case "$owner" in
    "$WHO "*|"$WHO") log "step 1: OK -- lock owner: $owner" ;;
    *) die "devlock on $HOST held by someone else: '$owner' (expected '$WHO'). Coordinate in chat." ;;
  esac
}

# ---------------------------------------------------------------- step 2
set_cfg_cd() {
  log "step 2: installing CD-boot config ($CFG_CD -> $CFG_LIVE)"
  sshq "test -f '$CFG_CD'" || die "$CFG_CD missing on $HOST (stage it first)"
  sshq "cp '$CFG_CD' '$CFG_LIVE' && od -A d -t x1 '$CFG_LIVE'" | tee -a "$RUNLOG"
  # byte 11 == 0x20 <=> status bit 93 = 1 (CD-ROM). Verify, don't trust.
  local b11
  b11="$(sshq "od -A n -t x1 -j 11 -N 1 '$CFG_LIVE'" | tr -d ' \n')"
  [ "$b11" = "20" ] || die "live CFG byte[11] = '$b11', expected 20 (bit 93 set)"
  log "step 2: OK -- System573.CFG live with bit 93 = 1 (Boot Device = CD-ROM)"
}

# ---------------------------------------------------------------- step 3
reboot_fresh() {
  log "step 3: lock-checked reboot of $HOST via hub devlock tool"
  [ -x "$COORD" ] || die "hub tool not found: $COORD"
  "$COORD" devlock "$HOST" reboot "$WHO" | tee -a "$RUNLOG"
  log "step 3: waiting for $HOST to come back (up to 240 s)..."
  local up="" t=0
  sleep 30
  while [ $t -lt 240 ]; do
    if up="$(sshq -o ConnectTimeout=5 "cut -d' ' -f1 /proc/uptime" 2>/dev/null)" && [ -n "$up" ]; then
      break
    fi
    sleep 10; t=$((t+10))
  done
  [ -n "$up" ] || die "$HOST did not come back within 240 s"
  # the reboot WIPED the on-board lock -- re-acquire it as the caller's key
  "$COORD" devlock "$HOST" acquire "$WHO" | tee -a "$RUNLOG" \
    || die "could not re-acquire devlock after reboot"
  up="$(sshq "cut -d. -f1 /proc/uptime")"
  log "step 3: $HOST uptime = ${up}s"
  [ "$up" -lt 60 ] || die "uptime ${up}s >= 60 -- NOT a fresh boot; bridge state suspect. Re-run."
  log "step 3: OK -- fresh boot, clean f2sdram bridge window"
}

# ---------------------------------------------------------------- step 4
launch_mgl() {
  log "step 4: killall MiSTer + headless launch of the install .mgl (log -> $MGL_LOG)"
  sshq "test -f '$RBF'" || die "$RBF missing on $HOST"
  sshq "test -f '$MGL'" || die "$MGL missing on $HOST"
  # nohup + background so Main survives the ssh session closing.
  sshq "killall MiSTer 2>/dev/null; sleep 1; nohup /media/fat/MiSTer '$RBF' '$MGL' >$MGL_LOG 2>&1 & sleep 2; echo launched pid \$!" \
    | tee -a "$RUNLOG"
  log "step 4: OK -- Main relaunched with $RBF + $(basename "$MGL")"
}

# ---------------------------------------------------------------- step 5
poll_load_lines() {
  log "step 5: polling $MGL_LOG for the deterministic load lines (120 s window)"
  # Patterns from the .mgl's four file loads + the CD mount:
  #   - 'Selected file' lines for the F-slots
  #   - 16777216 = flash16m_blank.bin byte size
  #   - the chd filename hitting the S1 (CUECHD) slot
  #   - index-251 cdinfo traffic (Main<->core CD geometry exchange)
  # NOTE for the orchestrator: exact wording varies slightly across Main
  # versions -- if a pattern never matches but the install visibly proceeds,
  # rerun with --allow-partial and fix the pattern from the pulled mgl.log.
  local -a pats=("Selected file" "16777216" "hypbbc2p.chd" "(index.*251|251.*index|cdinfo)")
  local t=0 missing=""
  while [ $t -lt 120 ]; do
    missing=""
    for p in "${pats[@]}"; do
      sshq "grep -qiE '$p' $MGL_LOG 2>/dev/null" || missing+="[$p] "
    done
    [ -z "$missing" ] && break
    sleep 5; t=$((t+5))
  done
  sshq "cat $MGL_LOG 2>/dev/null" > "$ART_DIR/mgl_early.log" || true
  if [ -n "$missing" ]; then
    log "step 5: MISSING patterns after 120 s: $missing"
    log "step 5: --- mgl.log tail ---"; tail -30 "$ART_DIR/mgl_early.log" | tee -a "$RUNLOG"
    [ "$ALLOW_PARTIAL" = "1" ] || die "load lines incomplete (use --allow-partial to continue anyway)"
    log "step 5: continuing despite missing patterns (--allow-partial)"
  else
    log "step 5: OK -- all load patterns present in $MGL_LOG"
  fi
}

# ---------------------------------------------------------------- step 6
install_watch() {
  log "step 6: install watch -- shot every ${WATCH_IVAL}s, static>${STATIC_SECS}s or ${BUDGET_SECS}s budget"
  printf 't_sec\tframe\tbytes\tluma\tpixhash\tnote\n' > "$METRICS"
  local need_static=$(( (STATIC_SECS + WATCH_IVAL - 1) / WATCH_IVAL + 1 ))
  local t0 now el=0 n=0 same=0 last_hash="" last_remote="" verdict="budget"
  t0=$(date +%s)
  while :; do
    now=$(date +%s); el=$((now - t0))
    if [ $el -ge "$BUDGET_SECS" ]; then verdict="budget"; break; fi
    n=$((n+1))
    local f; f="$(printf '%s/frame_%03d.png' "$ART_DIR" "$n")"
    local note="" bytes=0 luma="NA" hash="PULL_FAIL"
    if pull_shot "$f"; then
      bytes=$(wc -c < "$f" | tr -d ' ')
      IFS=$'\t' read -r luma hash < <(frame_metric "$f") || { luma="NA"; hash="METRIC_ERR"; }
      if [ "$PULL_SHOT_REMOTE" = "$last_remote" ] && [ -n "$last_remote" ]; then
        # the screenshot trigger produced NO new file -- this is a re-pull of a
        # stale frame, not evidence of a static screen. Don't advance `same`.
        note="stale_shot_no_new_file"
      elif [ "$hash" = "$last_hash" ]; then
        same=$((same+1)); note="static_x$same"
      else
        same=0; note="changed"
      fi
      last_hash="$hash"; last_remote="$PULL_SHOT_REMOTE"
    else
      note="screenshot_pull_failed"
    fi
    printf '%s\tframe_%03d.png\t%s\t%s\t%s\t%s\n' "$el" "$n" "$bytes" "$luma" "$hash" "$note" \
      | tee -a "$METRICS" | tee -a "$RUNLOG" >/dev/null
    log "step 6: t=${el}s frame_$(printf %03d "$n") bytes=$bytes luma=$luma $note"
    if [ $same -ge $((need_static - 1)) ] && [ $same -ge 1 ]; then
      verdict="static"; break
    fi
    sleep "$WATCH_IVAL"
  done
  log "step 6: watch ended after ${el}s, $n frames, verdict=$verdict"
  echo "$verdict" > "$ART_DIR/watch_verdict.txt"
}

# ---------------------------------------------------------------- step 7
post_install_stop() {
  log "step 7: install watch finished -- capturing the evidence tail, then STOPPING."
  # Deliberately NO config swap, NO reboot, NO relaunch -- see the OPEN QUESTION
  # block in the header. The installed flash image lives only in SDRAM; any
  # restart/reload via the blank-flash .mgl would destroy it.
  sshq "cat $MGL_LOG 2>/dev/null" > "$ART_DIR/mgl_final.log" || true
  pull_shot "$ART_DIR/final_evidence.png" || true
  {
    echo "run: $TS  host: $HOST  budget: ${BUDGET_SECS}s  ival: ${WATCH_IVAL}s"
    echo "verdict: $(cat "$ART_DIR/watch_verdict.txt" 2>/dev/null || echo unknown)"
    echo "board state: LEFT RUNNING, SDRAM install state INTACT, devlock still held by $WHO"
    echo "next: orchestrator decides the post-install boot strategy (see script header)"
  } > "$ART_DIR/NOTES.txt"
  log "step 7: install completed; post-install boot strategy TBD by orchestrator"
  log "step 7: board left untouched (core still running, devlock still held by $WHO)"
}

# ---------------------------------------------------------------- main
main() {
  log "=== hypbbc2p headless CD-install runner ==="
  log "host=$HOST who=$WHO budget=${BUDGET_SECS}s ival=${WATCH_IVAL}s static=${STATIC_SECS}s"
  log "artifacts -> $ART_DIR"
  require_devlock
  set_cfg_cd
  reboot_fresh
  launch_mgl
  poll_load_lines
  install_watch
  post_install_stop
  log "=== done. Review $ART_DIR (metrics.tsv, frames, mgl_final.log, NOTES.txt) ==="
  log "Verify with NUMBERS (frame_diff.py vs MAME install/boot refs), never vision."
}
main "$@"
