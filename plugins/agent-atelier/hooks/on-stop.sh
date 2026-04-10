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

exit 0
