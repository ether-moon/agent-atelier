#!/usr/bin/env bash
# TaskCompleted hook — enforce BUILD_PLAN gates and reject completion without evidence.
# Exit 0 = accept, Exit 2 = reject with feedback.

set -euo pipefail

# Determine git root
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$ROOT/.agent-atelier"

# If orchestration is not initialized, allow (not our concern)
[[ -d "$STATE_DIR" ]] || exit 0

# Check if work-items.json exists
WI_FILE="$STATE_DIR/work-items.json"
[[ -f "$WI_FILE" ]] || exit 0

LOOP_FILE="$STATE_DIR/loop-state.json"
[[ -f "$LOOP_FILE" ]] || exit 0

# Enforce BUILD_PLAN -> IMPLEMENT gate on executable state, not on active builders.
BUILD_PLAN_BLOCKERS=$(python3 - "$WI_FILE" "$LOOP_FILE" <<'PY' 2>/dev/null || echo ""
import json, sys
wi_file, loop_file = sys.argv[1], sys.argv[2]
with open(wi_file) as f:
    store = json.load(f)
with open(loop_file) as f:
    loop = json.load(f)

if loop.get("mode") != "BUILD_PLAN":
    raise SystemExit(0)

missing_verify = []
missing_complexity = []
for wi in store.get("items", []):
    if wi.get("status") != "ready":
        continue
    if not wi.get("verify"):
        missing_verify.append(wi.get("id", "unknown"))
    if wi.get("complexity") is None:
        missing_complexity.append(wi.get("id", "unknown"))

messages = []
if missing_verify:
    messages.append("missing verify: " + ", ".join(missing_verify))
if missing_complexity:
    messages.append("missing complexity: " + ", ".join(missing_complexity))
if messages:
    print("; ".join(messages))
PY
)

if [[ -n "$BUILD_PLAN_BLOCKERS" ]]; then
  echo "BLOCKED: BUILD_PLAN cannot advance. $BUILD_PLAN_BLOCKERS"
  echo "Every ready WI must define at least one verify check and a non-null complexity before implementation."
  exit 2
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
