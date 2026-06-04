#!/usr/bin/env bash
# =============================================================================
# dell_build.sh -- launch a Quartus .rbf build on the shared `dell` box, DETACHED.
#
# Runs the build under `setsid nohup` on dell so it is fully decoupled from this
# SSH session: it survives a Mac reboot, sleep, network drop, or closing the
# terminal. (A plain `ssh dell '... quartus_sh ...'` dies on SIGHUP when the Mac
# reboots -- that's the footgun this replaces.)
#
# MULTI-PROJECT COORDINATION (dell is shared with other MiSTer-core sessions, e.g.
# the DVD-player core). Everything is namespaced by $DELL_PROJECT and serialized by
# a cross-project lock so two sessions don't collide on the single-thread box:
#   - container name:  quartus-$PROJECT   (so --status / kill never touch another project)
#   - log:             /tmp/dellbuild-$PROJECT.log
#   - runner script:   /tmp/dell_build_run-$PROJECT.sh
#   - shared lock:     /tmp/dell-build.lock  (atomic; only ONE build runs at a time)
#   - shared board:    /tmp/mister-dell-coord.log  (who built what, when -- both append)
# Other sessions adopt the SAME lock + board paths (see docs/MISTER_DEV_NOTES.md).
#
# Usage:
#   DELL_PROJECT=573 tools/dell_build.sh [<branch|sha>]   # build (queues behind the lock)
#   tools/dell_build.sh --status                          # this project's build + log tail
#   tools/dell_build.sh --who                             # cross-project: who's using dell
#
# Track live:  python3 local/build_dashboard.py   ->  http://localhost:8573
# =============================================================================
set -euo pipefail

PROJECT="${DELL_PROJECT:-573}"            # namespace; override for other cores (e.g. dvd)
TARGET="${DELL_TARGET:-Konami_System_573}" # Quartus project (revision) name to compile
IMAGE='raetro/quartus:17.0'
LOG="/tmp/dellbuild-$PROJECT.log"
RUNNER="/tmp/dell_build_run-$PROJECT.sh"
CNAME="quartus-$PROJECT"
LOCK='/tmp/dell-build.lock'               # SHARED across all projects -- one build at a time
BOARD='/tmp/mister-dell-coord.log'        # SHARED human/agent-readable build board
REPO="${DELL_REPO:-System573_MiSTer}"     # dir name under $HOME on dell

# Any project's running build (to detect a busy box). Names look like quartus-<project>.
ANYRUN="docker ps --filter ancestor=$IMAGE --format '{{.Names}} {{.Status}}' 2>/dev/null"

if [ "${1:-}" = "--who" ]; then           # cross-project view of the shared box
  ssh dell "echo '== running builds =='; $ANYRUN || echo '(none)'; \
            echo '== lock =='; cat $LOCK/owner 2>/dev/null || echo '(free)'; \
            echo '== recent board =='; tail -n 8 $BOARD 2>/dev/null || echo '(empty)'"
  exit 0
fi
if [ "${1:-}" = "--status" ]; then        # THIS project only
  ssh dell "
    r=\$(docker ps --filter name=$CNAME --format '{{.Status}}' 2>/dev/null)
    if [ -n \"\$r\" ]; then echo \"[$PROJECT] BUILD RUNNING: \$r\"; else echo '[$PROJECT] no build running.'; fi
    echo '--- $LOG (tail) ---'; tail -n 8 '$LOG' 2>/dev/null || echo '(no log)'
  "
  exit 0
fi

REF="${1:-}"

# --- Acquire the shared cross-project build lock (atomic mkdir). -------------
# If held by a live build -> refuse (the box is busy). If the holder died (no
# quartus container running) -> steal the stale lock. This serializes 573 vs dvd
# vs any other session so the single-thread box isn't thrashed by 2 fits at once.
acq=$(ssh dell "
  if mkdir '$LOCK' 2>/dev/null; then echo ACQUIRED; else
    if [ -z \"\$(docker ps --filter ancestor=$IMAGE -q 2>/dev/null)\" ]; then
      rm -rf '$LOCK'; mkdir '$LOCK' 2>/dev/null && echo STOLE || echo RACE
    else echo \"BUSY \$(cat '$LOCK/owner' 2>/dev/null)\"; fi
  fi")
case "$acq" in
  ACQUIRED|STOLE) : ;;
  BUSY*) echo "dell is busy: ${acq#BUSY }" >&2
         echo "  the box runs ONE build at a time across projects. retry shortly, or:" >&2
         echo "  tools/dell_build.sh --who    (see the shared board)" >&2
         exit 1 ;;
  *)     echo "error: could not acquire dell build lock ($acq) -- retry." >&2; exit 1 ;;
esac
ssh dell "echo '$PROJECT pid=pending ref=${REF:-HEAD} $(date -u +%FT%TZ)' > '$LOCK/owner'"

# Send the runner verbatim (quoted heredoc => $HOME/$1/$(date)/$rc evaluate ON dell).
# It RELEASES the shared lock on exit (trap) and logs to the shared board, so a
# crash/kill still frees the box for the other project (plus the stale-steal above).
ssh dell "cat > '$RUNNER'" <<RUNNER
#!/usr/bin/env bash
set -uo pipefail
trap 'rm -rf "$LOCK"' EXIT                 # always free the shared box for the next project
cd "\$HOME/$REPO" || { echo "[$PROJECT] no \$HOME/$REPO" ; exit 9; }
REF="\${1:-}"
echo "$PROJECT pid=\$\$ ref=\${REF:-HEAD} \$(date -u +%FT%TZ)" > "$LOCK/owner"
echo "== dell build start \$(date -u +%FT%TZ) =="
echo "\$(date -u +%FT%TZ) $PROJECT START \${REF:-HEAD}" >> "$BOARD"
if [ -n "\$REF" ]; then git fetch --all --tags -q && git checkout -q "\$REF" || exit 8; fi
git pull -q --ff-only 2>/dev/null || true
echo "== building \$(git rev-parse --abbrev-ref HEAD) \$(git rev-parse --short HEAD) =="
[ -x tools/apply_psx_patches.sh ] && { tools/apply_psx_patches.sh || exit 7; }
docker run --rm --name "$CNAME" -v "\$PWD":/work -w /work --entrypoint quartus_sh \
  "$IMAGE" --flow compile "$TARGET"
rc=\$?
echo "== dell build DONE \$(date -u +%FT%TZ) rc=\$rc =="
echo "\$(date -u +%FT%TZ) $PROJECT DONE rc=\$rc \$(git rev-parse --short HEAD)" >> "$BOARD"
RUNNER

ssh dell "rm -f '$LOG'; chmod +x '$RUNNER'; \
  setsid nohup bash '$RUNNER' '$REF' > '$LOG' 2>&1 < /dev/null & \
  echo \"[$PROJECT] launched detached: pid \$!\""

echo
echo "Build launched DETACHED on dell -> dell:$LOG (survives a Mac reboot / SSH drop)."
echo "  project=$PROJECT  container=$CNAME  (serialized via $LOCK)"
echo "Track:   python3 local/build_dashboard.py   (http://localhost:8573)"
echo "Status:  tools/dell_build.sh --status     Cross-project: tools/dell_build.sh --who"
