#!/usr/bin/env bash
# TaskCompleted hook — reject completion without minimum role artifacts.
# Exit 0 = accept, Exit 2 = reject with feedback.
# Loose v1: check minimum artifacts, not perfection.

set -euo pipefail

TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"

# Determine git root
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$ROOT/.agent-atelier"

# If orchestration is not initialized, allow (not our concern)
[[ -d "$STATE_DIR" ]] || exit 0

# Check if work-items.json exists
WI_FILE="$STATE_DIR/work-items.json"
[[ -f "$WI_FILE" ]] || exit 0

# Look for work items in 'implementing' status with active leases
# If any implementing WI has no attempt recorded and no self-test evidence, warn
IMPLEMENTING_WITHOUT_TESTS=$(python3 - "$WI_FILE" <<'PY' 2>/dev/null || echo ""
import json, sys
with open(sys.argv[1]) as f:
    store = json.load(f)
warnings = []
for wi in store.get("items", []):
    if wi.get("status") == "implementing":
        if wi.get("attempt_count", 0) == 0 and not wi.get("verify"):
            warnings.append(wi.get("id", "unknown"))
if warnings:
    print(", ".join(warnings))
PY
)

if [[ -n "$IMPLEMENTING_WITHOUT_TESTS" ]]; then
  echo "WARNING: Work items $IMPLEMENTING_WITHOUT_TESTS are implementing with no verify checks defined."
  echo "Consider adding verify checks to ensure testable completion criteria."
  # Warn but don't block — loose v1
fi

# Check for validation manifests if any WI is in reviewing/done status
REVIEWING_WITHOUT_EVIDENCE=$(python3 - "$WI_FILE" "$STATE_DIR" <<'PY' 2>/dev/null || echo ""
import json, os, sys
wi_file, state_dir = sys.argv[1], sys.argv[2]
with open(wi_file) as f:
    store = json.load(f)
warnings = []
for wi in store.get("items", []):
    if wi.get("status") in ("reviewing", "done"):
        completion = wi.get("completion")
        if wi.get("status") == "done" and not completion:
            warnings.append(f"{wi.get('id')}: done without completion record")
if warnings:
    print("; ".join(warnings))
PY
)

if [[ -n "$REVIEWING_WITHOUT_EVIDENCE" ]]; then
  echo "BLOCKED: Completion without evidence: $REVIEWING_WITHOUT_EVIDENCE"
  echo "Use '/agent-atelier:execute complete' with validation manifest and evidence refs."
  exit 2
fi

exit 0
