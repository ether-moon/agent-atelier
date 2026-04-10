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

echo ""
echo "Schema validation: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
