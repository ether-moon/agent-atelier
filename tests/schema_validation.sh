#!/usr/bin/env bash
# Validates that the state-defaults.md reference contains well-formed JSON
# blocks that can be used to initialize the orchestration workspace.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULTS_FILE="$ROOT/plugins/agent-atelier/references/state-defaults.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== State Default Schema Tests ==="

# Extract JSON blocks from state-defaults.md and validate them
extract_and_validate() {
  local label="$1"
  local search_after="$2"

  # Extract the first JSON block (```json ... ```) after the search string
  local json_block
  json_block=$(awk -v pat="$search_after" '
    BEGIN { found=0; injson=0 }
    $0 ~ pat { found=1; next }
    found && /^```json/ { injson=1; next }
    injson && /^```/ { exit }
    injson { print }
  ' "$DEFAULTS_FILE")

  if [ -z "$json_block" ]; then
    fail "$label: JSON block not found"
    return
  fi

  # Replace <now> placeholders for validation
  json_block=$(echo "$json_block" | sed 's/"<now>"/"2026-04-08T00:00:00Z"/g')

  if echo "$json_block" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    pass "$label: valid JSON structure"
  else
    fail "$label: invalid JSON"
  fi
}

extract_and_validate "loop-state.json" "## loop-state.json"
extract_and_validate "work-items.json" "## work-items.json"
extract_and_validate "watchdog-jobs.json" "## watchdog-jobs.json"
extract_and_validate "human-decision-request.json" "## human-decision-request.json"

# Validate wi-schema.md canonical fields
WI_SCHEMA="$ROOT/plugins/agent-atelier/references/wi-schema.md"
if [ -f "$WI_SCHEMA" ]; then
  json_block=$(awk '
    BEGIN { injson=0 }
    /## Canonical Fields/ { found=1; next }
    found && /^```json/ { injson=1; next }
    injson && /^```/ { exit }
    injson { print }
  ' "$WI_SCHEMA")

  if echo "$json_block" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'id' in d; assert 'status' in d; assert 'promotion' in d" 2>/dev/null; then
    pass "wi-schema canonical fields: valid JSON with required keys"
  else
    fail "wi-schema canonical fields: invalid JSON or missing required keys"
  fi
else
  fail "wi-schema.md not found"
fi

# Validate new plan_approval / active_plan_cycle_id / plan_gate fields exist in loop-state defaults
LS_BLOCK=$(awk '
  BEGIN { found=0; injson=0 }
  /^## loop-state.json/ { found=1; next }
  found && /^```json/ { injson=1; next }
  injson && /^```/ { exit }
  injson { print }
' "$DEFAULTS_FILE" | sed 's/"<now>"/"2026-04-08T00:00:00Z"/g')

if echo "$LS_BLOCK" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'plan_approval' in d and 'active_plan_cycle_id' in d and 'plan_gate' in d" 2>/dev/null; then
  pass "loop-state.json includes plan_approval, active_plan_cycle_id, plan_gate"
else
  fail "loop-state.json missing one or more of plan_approval/active_plan_cycle_id/plan_gate"
fi

# Validate new watchdog plan_* budgets
WD_BLOCK=$(awk '
  BEGIN { found=0; injson=0 }
  /^## watchdog-jobs.json/ { found=1; next }
  found && /^```json/ { injson=1; next }
  injson && /^```/ { exit }
  injson { print }
' "$DEFAULTS_FILE" | sed 's/"<now>"/"2026-04-08T00:00:00Z"/g')

if echo "$WD_BLOCK" | python3 -c "import json,sys; d=json.load(sys.stdin)['defaults']; assert 'plan_question_budget' in d and 'plan_question_warn_at' in d and 'plan_user_response_timeout_hours' in d" 2>/dev/null; then
  pass "watchdog-jobs defaults include plan_question_budget/warn_at/timeout_hours"
else
  fail "watchdog-jobs defaults missing one or more plan_* fields"
fi

# Validate new schema files
for schema in clarifying-question.schema.json plan-conversation-entry.schema.json; do
  schema_path="$ROOT/plugins/agent-atelier/schema/$schema"
  if [ -f "$schema_path" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$schema_path" 2>/dev/null; then
    pass "$schema is valid JSON Schema"
  else
    fail "$schema not found or invalid"
  fi
done

echo ""
echo "Schema validation: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
