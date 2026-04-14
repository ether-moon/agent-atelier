#!/usr/bin/env bash
# TaskCreated hook — validate task creation against per-WI orchestration budgets.
# Exit 0 = allow, Exit 2 = reject with feedback.
#
# Parses WI ID from task_subject (e.g., "WI-014: Checkout states").
# TaskCreated stdin provides task_subject but NOT metadata, so we rely on
# the "WI-NNN: <title>" subject convention set by wi upsert.
# Tasks without a WI prefix pass through unconditionally.

set -euo pipefail

# Parse stdin JSON
INPUT=$(cat)

# Extract WI ID from task_subject prefix (e.g., "WI-014: ..." → "WI-014")
TARGET_WI=$(echo "$INPUT" | python3 -c "
import sys, json, re
try:
    data = json.load(sys.stdin)
    subject = data.get('task_subject', '')
    m = re.match(r'^(WI-\d+)', subject)
    print(m.group(1) if m else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

# If no WI prefix, this isn't a WI-linked task — allow unconditionally
[[ -n "$TARGET_WI" ]] || exit 0

# Determine git root
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$ROOT/.agent-atelier"

# If orchestration is not initialized, allow (not our concern)
[[ -d "$STATE_DIR" ]] || exit 0

WI_FILE="$STATE_DIR/work-items.json"
WATCHDOG_FILE="$STATE_DIR/watchdog-jobs.json"

# Both files must exist for budget checks
[[ -f "$WI_FILE" ]] || exit 0
[[ -f "$WATCHDOG_FILE" ]] || exit 0

# Check budgets for the TARGET WI only
REJECTION=$(python3 - "$TARGET_WI" "$WI_FILE" "$WATCHDOG_FILE" <<'PY' 2>/dev/null || echo ""
import json, sys

target_wi = sys.argv[1]
wi_file = sys.argv[2]
watchdog_file = sys.argv[3]

with open(wi_file) as f:
    store = json.load(f)
with open(watchdog_file) as f:
    watchdog = json.load(f)

items = store.get("items", [])
budgets = watchdog.get("budgets", {})

max_attempts = budgets.get("max_attempts_per_wi", 5)
max_handoffs = budgets.get("max_handoffs_per_wi", 6)
max_interventions = budgets.get("max_watchdog_interventions_per_wi", 3)

# Find the specific WI
wi = next((w for w in items if w.get("id") == target_wi), None)
if wi is None:
    # WI not found in store — allow (might be a new WI being created)
    sys.exit(0)

violations = []
wi_id = wi.get("id", "unknown")
attempts = wi.get("attempt_count", 0)
handoffs = wi.get("handoff_count", 0)
requeues = wi.get("stale_requeue_count", 0)

if attempts >= max_attempts:
    violations.append(f"{wi_id}: {attempts}/{max_attempts} attempts exhausted")
if handoffs >= max_handoffs:
    violations.append(f"{wi_id}: {handoffs}/{max_handoffs} handoffs exhausted")
if requeues >= max_interventions:
    violations.append(f"{wi_id}: {requeues}/{max_interventions} watchdog interventions exhausted")

if violations:
    print(f"Budget limit reached for {target_wi}:\n" + "\n".join(f"  - {v}" for v in violations))
    print("\nEscalate to user before creating more tasks for this WI.")
PY
)

if [[ -n "$REJECTION" ]]; then
  echo "$REJECTION" >&2
  exit 2
fi

exit 0
