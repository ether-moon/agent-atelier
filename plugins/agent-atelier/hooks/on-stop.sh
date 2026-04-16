#!/usr/bin/env bash
# Stop/SubagentStop hook — block exit when critical obligations remain.
# Exit 0 = allow, Exit 2 = block with feedback.
# Loose v1: warn first, block only on dangling obligations.

set -euo pipefail

# Determine git root
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$ROOT/.agent-atelier"

# If orchestration is not initialized, allow exit
[[ -d "$STATE_DIR" ]] || exit 0

WI_FILE="$STATE_DIR/work-items.json"
[[ -f "$WI_FILE" ]] || exit 0

# Check for implementing WIs with active (non-expired) leases
DANGLING=$(python3 - "$WI_FILE" <<'PY' 2>/dev/null || echo ""
import json, sys
from datetime import datetime, timezone

with open(sys.argv[1]) as f:
    store = json.load(f)

now = datetime.now(timezone.utc)
dangling = []

for wi in store.get("items", []):
    if wi.get("status") != "implementing":
        continue
    lease_str = wi.get("lease_expires_at")
    if not lease_str:
        continue
    try:
        lease = datetime.fromisoformat(lease_str.replace("Z", "+00:00"))
        if lease > now:
            dangling.append(f"{wi['id']} (lease expires {lease_str})")
    except (ValueError, TypeError):
        pass

if dangling:
    print("; ".join(dangling))
PY
)

if [[ -n "$DANGLING" ]]; then
  echo "WARNING: Active leases will become stale if you exit: $DANGLING"
  echo "Consider running '/agent-atelier:execute requeue' first, or the watchdog will recover them on next tick."
  # Warn but don't hard-block — the watchdog will clean up stale leases
fi

# Check for pending WAL (interrupted transaction)
WAL_FILE="$STATE_DIR/.pending-tx.json"
if [[ -f "$WAL_FILE" ]]; then
  echo "WARNING: Pending transaction exists at $WAL_FILE"
  echo "Run '/agent-atelier:init' or '/agent-atelier:watchdog tick' to replay it before exiting."
fi

# Check for leaked team resources (Agent Teams cleanup not run)
# Resolve team name: loop-state.json team_name → prefix search fallback
TEAM_NAME=""
LOOP_STATE="$STATE_DIR/loop-state.json"
if [[ -f "$LOOP_STATE" ]]; then
  TEAM_NAME=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f).get('team_name') or '')
" "$LOOP_STATE" 2>/dev/null || echo "")
fi

# Fallback: search for any atelier-* team directory (session-scoped naming)
if [[ -z "$TEAM_NAME" ]]; then
  TEAMS_BASE="$HOME/.claude/teams"
  if [[ -d "$TEAMS_BASE" ]]; then
    shopt -s nullglob
    for d in "$TEAMS_BASE"/atelier-*; do
      if [[ -d "$d" ]]; then
        TEAM_NAME=$(basename "$d")
        break
      fi
    done
    shopt -u nullglob
  fi
fi

if [[ -n "$TEAM_NAME" ]]; then
  TEAM_DIR="$HOME/.claude/teams/$TEAM_NAME"
  if [[ -d "$TEAM_DIR" ]]; then
    TEAM_MEMBERS=$(python3 - "$TEAM_DIR/config.json" <<'PY' 2>/dev/null || echo ""
import json, sys, os
config_path = sys.argv[1]
if not os.path.isfile(config_path):
    sys.exit(0)
with open(config_path) as f:
    config = json.load(f)
members = config.get("members", [])
if members:
    names = [m.get("name", "unknown") for m in members]
    print("; ".join(names))
PY
)

    if [[ -n "$TEAM_MEMBERS" ]]; then
      echo "WARNING: Agent team '$TEAM_NAME' still has active members: $TEAM_MEMBERS"
      echo "Run the DONE cleanup checklist: shutdown teammates -> clean up team -> verify."
    else
      echo "WARNING: Agent team directory exists at $TEAM_DIR but has no members."
      echo "Consider running team cleanup to remove stale resources."
    fi
  fi
fi

exit 0
