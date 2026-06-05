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
# the DVD-player core). Everything is namespaced by $DELL_PROJECT, and a COUNTING
# SEMAPHORE allows up to $DELL_MAX_BUILDS concurrent builds (default 2) so two
# sessions can fit at once without thrashing the box into swap:
#   - container name:  quartus-$PROJECT   (so --status / kill never touch another project)
#   - log:             /tmp/dellbuild-$PROJECT.log
#   - runner script:   /tmp/dell_build_run-$PROJECT.sh
#   - shared semaphore:/tmp/dell-build.lock/  (one slot dir per project; cap in .../cap)
#   - shared board:    /tmp/mister-dell-coord.log  (who built what, when -- both append)
# Admission claims a per-project slot, then checks occupancy (slot dirs UNION running
# quartus containers) <= cap; a RAM guard defers a build when dell is low on memory,
# and each build gets a fair docker --cpus share. Other sessions adopt the SAME paths.
#
# Tunables (env): DELL_MAX_BUILDS (default 2), DELL_MIN_FREE_MB (default 4096),
#                 DELL_BUILD_CPUS (default = nproc/cap).
#
# Usage:
#   DELL_PROJECT=573 tools/dell_build.sh [<branch|sha>]   # build (claims a slot; refuses if full)
#   tools/dell_build.sh --status                          # this project's build + log tail
#   tools/dell_build.sh --who                             # cross-project: slots + who's using dell
#
# Track live:  the dev-hub cockpit dashboard (cockpit/dashboard.py) -> http://localhost:8573
#              (one screen, all cores; discovered from registry/projects.md)
# =============================================================================
set -euo pipefail

PROJECT="${DELL_PROJECT:-573}"            # namespace; override for other cores (e.g. dvd)
TARGET="${DELL_TARGET:-Konami_System_573}" # Quartus project (revision) name to compile
IMAGE='raetro/quartus:17.0'
LOG="/tmp/dellbuild-$PROJECT.log"
RUNNER="/tmp/dell_build_run-$PROJECT.sh"
CNAME="quartus-$PROJECT"
LOCK='/tmp/dell-build.lock'               # SHARED counting semaphore (one slot dir per project)
BOARD='/tmp/mister-dell-coord.log'        # SHARED human/agent-readable build board
REPO="${DELL_REPO:-System573_MiSTer}"     # dir name under $HOME on dell
CAP="${DELL_MAX_BUILDS:-2}"               # max concurrent builds across ALL projects
MINFREE="${DELL_MIN_FREE_MB:-4096}"       # defer a new build if dell has less free RAM (MB) than this
CPUS_OVERRIDE="${DELL_BUILD_CPUS:-}"      # per-build docker --cpus; default = nproc/cap (fair share)
case "$CAP" in ''|*[!0-9]*) echo "DELL_MAX_BUILDS must be a positive integer" >&2; exit 2 ;; esac
[ "$CAP" -ge 1 ] || { echo "DELL_MAX_BUILDS must be >= 1" >&2; exit 2; }

if [ "${1:-}" = "--who" ]; then           # cross-project view of the shared box
  ssh dell "
    LOCK='$LOCK'
    cap=\$(cat \"\$LOCK/cap\" 2>/dev/null || echo '?')
    echo \"== build slots (up to \$cap concurrent) ==\"
    n=0; for d in \"\$LOCK\"/*/; do [ -d \"\$d\" ] || continue; n=\$((n+1)); echo \"  \$(basename \"\$d\"): \$(cat \"\$d/owner\" 2>/dev/null || echo '(claiming...)')\"; done
    [ \$n -eq 0 ] && echo '  (no slots in use -- box free)'
    echo '== running builds =='; docker ps --filter ancestor=$IMAGE --format '{{.Names}} {{.Status}}' 2>/dev/null || echo '(none)'
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

# --- Acquire a build SLOT from the cross-project counting semaphore. ---------
# The box runs up to $CAP concurrent builds. Reclaim stale slots (no live container,
# past the launch window), refuse if this project is already building, then claim our
# per-project slot and verify occupancy (slot dirs UNION running quartus containers)
# stays <= cap -- backing out if not, so we NEVER over-admit. A RAM guard defers the
# build when dell is low on memory. (Counting running containers makes this correct
# even across a tool upgrade: a legacy single-lock build still counts toward capacity.)
acq=$(ssh dell "
  LOCK='$LOCK'; IMAGE='$IMAGE'; CAP=$CAP; MINMB=$MINFREE; P='$PROJECT'
  mkdir -p \"\$LOCK\" 2>/dev/null; printf '%s\n' \"\$CAP\" > \"\$LOCK/cap\" 2>/dev/null || true
  now=\$(date +%s)
  for d in \"\$LOCK\"/*/; do
    [ -d \"\$d\" ] || continue
    q=\$(basename \"\$d\")
    if [ -z \"\$(docker ps --filter name=quartus-\$q -q 2>/dev/null)\" ]; then
      age=\$(( now - \$(stat -c %Y \"\$d\" 2>/dev/null || echo \$now) ))
      [ \$age -gt 120 ] && rm -rf \"\$d\"
    fi
  done
  if [ -n \"\$(docker ps --filter name=quartus-\$P -q 2>/dev/null)\" ] || [ -d \"\$LOCK/\$P\" ]; then echo SELFBUSY; exit 0; fi
  mkdir \"\$LOCK/\$P\" 2>/dev/null || { echo SELFBUSY; exit 0; }
  occ=\$({ for d in \"\$LOCK\"/*/; do [ -d \"\$d\" ] && basename \"\$d\"; done; docker ps --filter ancestor=\"\$IMAGE\" --format '{{.Names}}' 2>/dev/null | sed -n 's/^quartus-//p'; } | sort -u | grep -c .)
  if [ \"\$occ\" -gt \"\$CAP\" ]; then rmdir \"\$LOCK/\$P\" 2>/dev/null; echo \"FULL \$occ\"; exit 0; fi
  avail=\$(free -m 2>/dev/null | awk '/Mem:/{print \$7}')
  if [ -n \"\$avail\" ] && [ \"\$avail\" -lt \"\$MINMB\" ]; then rmdir \"\$LOCK/\$P\" 2>/dev/null; echo \"LOWRAM \$avail\"; exit 0; fi
  printf '%s\n' \"\$P pid=pending ref=${REF:-HEAD} \$(date -u +%FT%TZ)\" > \"\$LOCK/\$P/owner\"
  echo GOT")
case "$acq" in
  GOT)      : ;;
  SELFBUSY) echo "[$PROJECT] already has a build running/pending -- tools/dell_build.sh --status. Not starting another." >&2; exit 1 ;;
  FULL*)    echo "dell is at build capacity (${acq#FULL } / $CAP running). retry shortly, or:" >&2
            echo "  tools/dell_build.sh --who    (raise the cap with DELL_MAX_BUILDS=N if the box can take it)" >&2; exit 1 ;;
  LOWRAM*)  echo "dell low on RAM (${acq#LOWRAM } MB free < ${MINFREE} MB) -- deferring to avoid swap thrash. retry shortly." >&2; exit 1 ;;
  *)        echo "error: could not acquire a build slot ($acq) -- retry." >&2; exit 1 ;;
esac

# Send the runner verbatim (quoted values evaluate ON dell where escaped with \$).
# It RELEASES only OUR slot on exit (trap) and logs to the shared board, so a
# crash/kill frees this project's slot for the next build (plus the stale-reclaim above).
ssh dell "cat > '$RUNNER'" <<RUNNER
#!/usr/bin/env bash
set -uo pipefail
SLOT="$LOCK/$PROJECT"
trap 'rm -rf "\$SLOT"' EXIT                # free OUR slot only; other projects keep theirs
cd "\$HOME/$REPO" || { echo "[$PROJECT] no \$HOME/$REPO" ; exit 9; }
REF="\${1:-}"
printf '%s\n' "$PROJECT pid=\$\$ ref=\${REF:-HEAD} \$(date -u +%FT%TZ)" > "\$SLOT/owner" 2>/dev/null || true
CPUS="$CPUS_OVERRIDE"; [ -z "\$CPUS" ] && CPUS=\$(( \$(nproc) / $CAP )); [ "\$CPUS" -lt 1 ] && CPUS=1
echo "== dell build start \$(date -u +%FT%TZ)  (project $PROJECT, --cpus=\$CPUS, cap $CAP) =="
echo "\$(date -u +%FT%TZ) $PROJECT START \${REF:-HEAD}" >> "$BOARD"
if [ -n "\$REF" ]; then git fetch --all --tags -q && git checkout -q "\$REF" || exit 8; fi
git pull -q --ff-only 2>/dev/null || true
echo "== building \$(git rev-parse --abbrev-ref HEAD) \$(git rev-parse --short HEAD) =="
[ -x tools/apply_psx_patches.sh ] && { tools/apply_psx_patches.sh || exit 7; }
docker run --rm --name "$CNAME" --cpus="\$CPUS" -v "\$PWD":/work -w /work --entrypoint quartus_sh \
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
echo "  project=$PROJECT  container=$CNAME  (one of up to $CAP concurrent; semaphore $LOCK)"
echo "Track:   dev-hub cockpit dashboard -> http://localhost:8573 (all cores)"
echo "Status:  tools/dell_build.sh --status     Cross-project: tools/dell_build.sh --who"
