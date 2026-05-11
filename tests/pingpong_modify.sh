#!/usr/bin/env bash
# Scenario: gate "수정" feedback routes back to phase, mode reverts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/agent-atelier"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP=$(mktemp -d); cd "$TMP"; git init -q
"$PLUGIN_ROOT/scripts/init-helpers.sh" --root "$TMP" >/dev/null

LS_PATH="$TMP/.agent-atelier/loop-state.json"

# Setup: mode at BUILD_PLAN with plan_gate.phase = FINAL_REVIEW
python3 -c "
import json
ls = json.load(open('$LS_PATH'))
ls['mode'] = 'BUILD_PLAN'
ls['active_plan_cycle_id'] = 'cycle-modify'
ls['plan_gate'] = {
  'opened_at': '2026-05-08T10:00:00Z',
  'phase': 'FINAL_REVIEW',
  'gate_id': 'PLAN-GATE-001'
}
json.dump(ls, open('$LS_PATH', 'w'), indent=2)
"

# Sanity check
PHASE_BEFORE=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['plan_gate']['phase'])")
if [ "$PHASE_BEFORE" = "FINAL_REVIEW" ]; then
  pass "initial plan_gate.phase = FINAL_REVIEW"
else
  fail "expected FINAL_REVIEW, got: $PHASE_BEFORE"
fi

# Action: simulate "수정" routing → revert to SPEC_DRAFT phase, plan_approval stays null
TX=$(python3 -c "
import json
ls = json.load(open('$LS_PATH'))
new_content = dict(ls)
new_content['revision'] = ls['revision'] + 1
new_content['updated_at'] = '2026-05-08T10:01:00Z'
new_content['mode'] = 'SPEC_DRAFT'
new_content['plan_gate'] = {
  'opened_at': '2026-05-08T10:00:00Z',
  'phase': 'SPEC_DRAFT',
  'gate_id': 'PLAN-GATE-001',
  'feedback': '수정'
}
new_content['plan_approval'] = None
tx = {
  'writes': [{
    'path': '.agent-atelier/loop-state.json',
    'expected_revision': ls['revision'],
    'content': new_content
  }]
}
print(json.dumps(tx))
")

RESULT=$(echo "$TX" | "$PLUGIN_ROOT/scripts/state-commit" --root "$TMP" 2>&1)

if echo "$RESULT" | grep -q '"committed": true'; then
  pass "state-commit accepted modify-routing transaction"
else
  fail "state-commit rejected: $RESULT"
fi

MODE_AFTER=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['mode'])")
if [ "$MODE_AFTER" = "SPEC_DRAFT" ]; then
  pass "mode reverted to SPEC_DRAFT"
else
  fail "mode should be SPEC_DRAFT, got: $MODE_AFTER"
fi

PHASE_AFTER=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['plan_gate']['phase'])")
if [ "$PHASE_AFTER" = "SPEC_DRAFT" ]; then
  pass "plan_gate.phase updated to SPEC_DRAFT"
else
  fail "plan_gate.phase should be SPEC_DRAFT, got: $PHASE_AFTER"
fi

PA_AFTER=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['plan_approval'])")
if [ "$PA_AFTER" = "None" ]; then
  pass "plan_approval remains null (no approval on modify)"
else
  fail "plan_approval should be null, got: $PA_AFTER"
fi

rm -rf "$TMP"
echo ""
echo "pingpong_modify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
