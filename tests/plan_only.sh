#!/usr/bin/env bash
# Scenario: /plan happy path lands plan_approval, mode stays BUILD_PLAN.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/agent-atelier"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP=$(mktemp -d); cd "$TMP"; git init -q
"$PLUGIN_ROOT/scripts/init-helpers.sh" --root "$TMP" >/dev/null

# Setup: write a behavior-spec.md
mkdir -p "$TMP/docs/product"
cat > "$TMP/docs/product/behavior-spec.md" <<'SPEC_EOF'
# Behavior Spec
Sample content for plan_only scenario.
SPEC_EOF

# Compute hashes for empty work-items + the spec file
EXPECTED_PLAN_HASH=$(python3 -c "
import sys, json
sys.path.insert(0, '$PLUGIN_ROOT/scripts')
from _plan_hash import wi_plan_hash
print(wi_plan_hash([]))
")
EXPECTED_SPEC_HASH=$(python3 -c "
import sys
sys.path.insert(0, '$PLUGIN_ROOT/scripts')
from _plan_hash import spec_hash
print(spec_hash('$TMP/docs/product/behavior-spec.md'))
")

# Action: /plan happy path → set plan_approval, mode stays BUILD_PLAN, clear cycle/gate
TX=$(python3 -c "
import json
tx = {
  'writes': [{
    'path': '.agent-atelier/loop-state.json',
    'expected_revision': 1,
    'content': {
      'revision': 2,
      'updated_at': '2026-05-08T10:00:00Z',
      'mode': 'BUILD_PLAN',
      'active_spec': 'docs/product/behavior-spec.md',
      'active_spec_revision': 1,
      'open_gates': [],
      'active_candidate_set': None,
      'candidate_queue': [],
      'team_name': None,
      'next_action': {'owner': 'orchestrator', 'type': 'draft_first_work_item', 'target': None},
      'plan_approval': {
        'approved_at': '2026-05-08T10:00:00Z',
        'wi_plan_hash': '$EXPECTED_PLAN_HASH',
        'spec_hash': '$EXPECTED_SPEC_HASH',
        'approved_by': 'user'
      },
      'active_plan_cycle_id': None,
      'plan_gate': None
    }
  }]
}
print(json.dumps(tx))
")

RESULT=$(echo "$TX" | "$PLUGIN_ROOT/scripts/state-commit" --root "$TMP" 2>&1)

if echo "$RESULT" | grep -q '"committed": true'; then
  pass "state-commit accepted plan_only transaction"
else
  fail "state-commit rejected plan_only transaction: $RESULT"
fi

# Assertions
LS_PATH="$TMP/.agent-atelier/loop-state.json"
PA=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['plan_approval'])")
if [ "$PA" != "None" ]; then
  pass "plan_approval is set"
else
  fail "plan_approval should be set, got: $PA"
fi

MODE=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['mode'])")
if [ "$MODE" = "BUILD_PLAN" ]; then
  pass "mode stays BUILD_PLAN"
else
  fail "mode should be BUILD_PLAN, got: $MODE"
fi

ACTIVE_CYCLE=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['active_plan_cycle_id'])")
if [ "$ACTIVE_CYCLE" = "None" ]; then
  pass "active_plan_cycle_id is null"
else
  fail "active_plan_cycle_id should be null, got: $ACTIVE_CYCLE"
fi

rm -rf "$TMP"
echo ""
echo "plan_only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
