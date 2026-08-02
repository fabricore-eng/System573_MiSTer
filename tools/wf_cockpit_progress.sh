#!/usr/bin/env bash
# wf_cockpit_progress.sh -- mirror a Claude Code Workflow's overall progress + ETA
# into the dev-hub cockpit progress bar (dell:~/mister-shared/state/progress/<key>,
# the SAME file + format the iverilog sim suite uses, so the dashboard renders it
# with no cockpit-side change).
#
# The workflow journal (subagents/workflows/<runid>/journal.jsonl) logs one
# {"type":"started"...} per agent spawn and one {"type":"result"...} per completion
# (no timestamps, no phase markers) -- so this bridge times itself and uses
# agents-done / agents-total for the bar. Pass the EXPECTED total agent count (you
# know it when you author the workflow); the bridge auto-grows the total if more
# agents start than expected, so an underestimate never pins the bar at 100% early.
#
# Run it in the BACKGROUND right after launching a Workflow:
#   tools/wf_cockpit_progress.sh 573 <transcript-dir>/journal.jsonl 5 "DDR grounding" &
# It writes the bar every few seconds, then clears it ~8s after the workflow finishes.
#
# Usage: wf_cockpit_progress.sh <key> <journal.jsonl> <total-agents> <label> [poll_s]
set -uo pipefail

KEY="${1:?usage: wf_cockpit_progress.sh <key> <journal> <total> <label> [poll_s]}"
JOURNAL="${2:?journal path}"
TOTAL="${3:?total agents}"
LABEL="${4:?label}"
POLL="${5:-6}"

START_ISO="$(date -u +%FT%TZ)"
t0="$(date +%s)"
DELL="ssh -o BatchMode=yes -o ConnectTimeout=5 dell"
PF="mister-shared/state/progress/$KEY"

write() {  # pct eta_s done eff_total note
  printf '%s\t%s\t%s\t%s\t%s/%s last=%s\n' \
    "$START_ISO" "$LABEL" "$1" "$2" "$3" "$4" "$5" \
    | $DELL "mkdir -p ~/mister-shared/state/progress && cat > ~/$PF" >/dev/null 2>&1 || true
}

stable=0
while :; do
  if [ -f "$JOURNAL" ]; then
    started=$(grep -c '"type":"started"' "$JOURNAL" 2>/dev/null || echo 0)
    done_n=$(grep -c '"type":"result"' "$JOURNAL" 2>/dev/null || echo 0)
  else
    started=0; done_n=0
  fi
  eff_total="$TOTAL"; [ "$started" -gt "$eff_total" ] && eff_total="$started"
  [ "$eff_total" -lt 1 ] && eff_total=1
  el=$(( $(date +%s) - t0 ))
  pct=$(( 100 * done_n / eff_total )); [ "$pct" -gt 100 ] && pct=100
  if [ "$done_n" -gt 0 ]; then eta=$(( el * (eff_total - done_n) / done_n )); else eta=0; fi
  [ "$eta" -lt 0 ] && eta=0
  write "$pct" "$eta" "$done_n" "$eff_total" "${done_n}done/${started}started"

  # "done" = every started agent has a result AND at least one ran; hold 2 polls to confirm.
  if [ "$done_n" -ge "$eff_total" ] && [ "$done_n" -gt 0 ] && [ "$started" -eq "$done_n" ]; then
    stable=$((stable + 1))
  else
    stable=0
  fi
  [ "$stable" -ge 2 ] && break
  sleep "$POLL"
done

write 100 0 "$done_n" "$done_n" "complete"
sleep 8
$DELL "rm -f ~/$PF" >/dev/null 2>&1 || true
