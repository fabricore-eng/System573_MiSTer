#!/usr/bin/env bash
# =============================================================================
# dell_build.sh -- launch a Quartus .rbf build on the `dell` box, DETACHED.
#
# Runs the build under `setsid nohup` on dell so it is fully decoupled from this
# SSH session: it survives a Mac reboot, sleep, network drop, or closing the
# terminal. (A plain `ssh dell '... quartus_sh ...'` dies on SIGHUP when the Mac
# reboots -- that's the footgun this replaces.) Output goes to dell:/tmp/dellbuild.log,
# which local/build_dashboard.py reads.
#
# Usage:
#   tools/dell_build.sh                # build whatever branch/commit dell has
#   tools/dell_build.sh <branch|sha>   # fetch + checkout that ref on dell, then build
#   tools/dell_build.sh --status       # is a build running on dell? + log tail
#
# Track live:  python3 local/build_dashboard.py   ->  http://localhost:8573
# Fetch + deploy the result:
#   scp dell:'~/System573_MiSTer/output_files/Konami_System_573.rbf' output_files/
#   tools/mister_boot573.sh
# =============================================================================
set -euo pipefail
LOG='/tmp/dellbuild.log'
# The build IS a `docker run` of the Quartus image, so a running build == a running
# container from that image. (pgrep on quartus_* is unreliable: the binaries run inside
# the container's PID namespace, and `pgrep -f` would also self-match its own pattern.)
RUNNING='docker ps --filter ancestor=raetro/quartus:17.0 --format "{{.ID}} {{.Status}}" 2>/dev/null'

if [ "${1:-}" = "--status" ]; then
  ssh dell "
    r=\$($RUNNING)
    if [ -n \"\$r\" ]; then echo \"BUILD RUNNING: \$r\"; else echo 'no build running on dell.'; fi
    echo '--- $LOG (tail) ---'; tail -n 8 '$LOG' 2>/dev/null || echo '(no log)'
  "
  exit 0
fi

REF="${1:-}"

# Refuse to stomp a build that's already running.
if [ -n "$(ssh dell "$RUNNING")" ]; then
  echo "error: a Quartus build is already running on dell -- not launching another." >&2
  echo "       (tools/dell_build.sh --status to see it)" >&2
  exit 1
fi

# Send the runner verbatim (quoted heredoc => nothing expands locally; $HOME, $1,
# $(date), $rc all evaluate ON dell), then setsid-launch it detached.
ssh dell "cat > /tmp/dell_build_run.sh" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
cd "$HOME/System573_MiSTer" || exit 9
REF="${1:-}"
echo "== dell build start $(date -u +%FT%TZ) =="
if [ -n "$REF" ]; then git fetch --all --tags -q && git checkout -q "$REF" || exit 8; fi
git pull -q --ff-only 2>/dev/null || true
echo "== building $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD) =="
tools/apply_psx_patches.sh || exit 7
docker run --rm -v "$PWD":/work -w /work --entrypoint quartus_sh \
  raetro/quartus:17.0 --flow compile Konami_System_573
rc=$?
echo "== dell build DONE $(date -u +%FT%TZ) rc=$rc =="
RUNNER

# rm (not just truncate) the log first: `>` keeps the inode, so its birth time (stat %W)
# would stay frozen at the first-ever build and any %W-based elapsed timer runs away.
ssh dell "rm -f '$LOG'; chmod +x /tmp/dell_build_run.sh; \
  setsid nohup bash /tmp/dell_build_run.sh '$REF' > '$LOG' 2>&1 < /dev/null & \
  echo \"launched detached: pid \$!\""

echo
echo "Build launched DETACHED on dell -> dell:$LOG (survives a Mac reboot / SSH drop)."
echo "Track live:  python3 local/build_dashboard.py    (http://localhost:8573)"
echo "Status:      tools/dell_build.sh --status"
