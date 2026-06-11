#!/usr/bin/env python3
"""PostToolUse(Agent|Workflow) hook: auto-start a control-room progress stripe.

Background agents/workflows have no scrapeable process AND do not fire stop-hooks
(SubagentStop only fires for FOREGROUND subagents) — so the cockpit can't see them.
This fires at LAUNCH (PostToolUse returns immediately for run_in_background with
status async_launched) and starts a heartbeating progress marker labeled from the
agent's description. The stripe shows the most-recently-launched phase; because each
launch overwrites the shared 573 marker, it naturally chains as the pipeline advances.
The session clears it on completion (or it self-expires via the 10-min heartbeat).

Best-effort by construction: any error exits 0, and the dell write is detached so it
never slows or blocks a tool call.
"""
import sys, json, subprocess, os

def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    tool = d.get("tool_name", "")
    if tool not in ("Agent", "Workflow", "Task"):
        return
    ti = d.get("tool_input", {}) or {}
    tr = d.get("tool_response", {}) or {}
    # Only background launches: a foreground agent has already FINISHED by the time
    # PostToolUse fires, so a stripe then would be instantly stale.
    status = str(tr.get("status", "")).lower()
    bg = ti.get("run_in_background") is True or status in ("async_launched", "launched", "running")
    if not bg:
        return
    label = ti.get("description") or ti.get("title") or ("workflow" if tool == "Workflow" else "agent")
    label = str(label)[:60]
    coord = os.path.expanduser("~/Dev/mister-dev-hub/tools/dell_coord.sh")
    if not os.access(coord, os.X_OK):
        return
    try:
        # detached: return instantly, never block the tool
        subprocess.Popen(
            [coord, "progress", "573", "start", label, "--detail", f"{tool.lower()} (auto): {label}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        pass

if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
