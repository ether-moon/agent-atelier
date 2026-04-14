#!/usr/bin/env bash
# TeammateIdle hook — keep teammates working when assignable work exists.
# Exit 0 = allow idle, Exit 2 = send feedback to keep working.
#
# Reads teammate_name from stdin JSON, resolves role via team config
# (agentType from members[]), then checks work-items.json for
# role-appropriate work and feeds back the next assignable WI.

set -euo pipefail

# Parse stdin JSON
INPUT=$(cat)
TEAMMATE_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teammate_name',''))" 2>/dev/null || echo "")

# If no teammate name, allow idle
[[ -n "$TEAMMATE_NAME" ]] || exit 0

# Determine git root
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$ROOT/.agent-atelier"

# If orchestration is not initialized, allow idle
[[ -d "$STATE_DIR" ]] || exit 0

WI_FILE="$STATE_DIR/work-items.json"
[[ -f "$WI_FILE" ]] || exit 0

LOOP_FILE="$STATE_DIR/loop-state.json"
[[ -f "$LOOP_FILE" ]] || exit 0

# Resolve role from team config, fall back to substring matching
FEEDBACK=$(python3 - "$TEAMMATE_NAME" "$WI_FILE" "$LOOP_FILE" <<'PY' 2>/dev/null || echo ""
import json, sys, os

teammate = sys.argv[1]
wi_file = sys.argv[2]
loop_file = sys.argv[3]

with open(wi_file) as f:
    store = json.load(f)
with open(loop_file) as f:
    loop = json.load(f)

items = store.get("items", [])
mode = loop.get("mode", "")
candidate_queue = loop.get("candidate_queue", [])
active_candidate = loop.get("active_candidate")

# --- Role resolution ---
# Primary: read agentType from team config via loop-state team_name
# Fallback: substring matching on teammate name
role = ""
team_name = loop.get("team_name") or ""
if team_name:
    config_path = os.path.expanduser(f"~/.claude/teams/{team_name}/config.json")
    if os.path.isfile(config_path):
        try:
            with open(config_path) as f:
                config = json.load(f)
            for member in config.get("members", []):
                if member.get("name") == teammate:
                    role = member.get("agentType", "")
                    break
        except (json.JSONDecodeError, IOError):
            pass

# Fallback: substring matching if config lookup failed
if not role:
    name_lower = teammate.lower()
    for keyword in ("builder", "vrm", "validator", "qa-reviewer", "ux-reviewer",
                     "state-manager", "pm", "architect"):
        if keyword in name_lower:
            role = keyword
            break

if not role:
    # Unknown role — allow idle
    sys.exit(0)

# --- Work assignment by role ---
if role in ("builder",):
    ready = [wi for wi in items if wi.get("status") == "ready"]
    if ready:
        wi = ready[0]
        print(f"There is a ready work item to claim: {wi['id']} — {wi.get('title', 'untitled')}. "
              f"Use '/agent-atelier:execute claim {wi['id']}' to start implementing.")
    elif mode == "AUTOFIX":
        reviewing = [wi for wi in items if wi.get("status") == "reviewing"]
        if reviewing:
            print(f"AUTOFIX mode active. Check with the Orchestrator for bug fixes on {reviewing[0]['id']}.")

elif role in ("vrm", "validator"):
    if active_candidate and mode in ("VALIDATE", "IMPLEMENT"):
        print(f"Active candidate exists: {active_candidate}. "
              f"Begin validation using the evidence from build-vrm-prompt.")
    elif candidate_queue:
        print(f"Candidates in queue: {len(candidate_queue)}. "
              f"Ask the Orchestrator to activate the next candidate.")

elif role in ("qa-reviewer", "ux-reviewer"):
    reviewing = [wi for wi in items if wi.get("status") == "reviewing"]
    if reviewing and mode == "REVIEW_SYNTHESIS":
        wi = reviewing[0]
        print(f"Work item {wi['id']} is in review. Submit your independent findings "
              f"before reading other reviewers' output.")

elif role in ("state-manager",):
    if mode != "DONE":
        pending_count = sum(1 for wi in items if wi.get("status") != "done")
        if pending_count > 0:
            print(f"Orchestration is still active ({mode} mode, {pending_count} unfinished WIs). "
                  f"Remain available for state commit requests.")

elif role in ("pm",):
    if mode in ("DISCOVER", "SPEC_DRAFT", "SPEC_HARDEN", "REVIEW_SYNTHESIS"):
        print(f"Orchestration is in {mode} mode — your input is needed. "
              f"Continue spec work or feedback classification.")

elif role in ("architect",):
    if mode in ("SPEC_HARDEN", "BUILD_PLAN", "IMPLEMENT", "AUTOFIX"):
        ready = [wi for wi in items if wi.get("status") == "ready"]
        implementing = [wi for wi in items if wi.get("status") == "implementing"]
        if ready or implementing:
            print(f"Orchestration is in {mode} mode with {len(ready)} ready and "
                  f"{len(implementing)} implementing WIs. Remain available for "
                  f"Builder support and coordination.")
PY
)

if [[ -n "$FEEDBACK" ]]; then
  echo "$FEEDBACK" >&2
  exit 2
fi

exit 0
