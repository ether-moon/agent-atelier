#!/usr/bin/env bash
# Scenario: /execute with valid plan_approval skips plan flow.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/agent-atelier"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP=$(mktemp -d); cd "$TMP"; git init -q
"$PLUGIN_ROOT/scripts/init-helpers.sh" --root "$TMP" >/dev/null

# Setup: behavior-spec.md + work-items.json with one WI + valid plan_approval
mkdir -p "$TMP/docs/product"
cat > "$TMP/docs/product/behavior-spec.md" <<'SPEC_EOF'
# Behavior Spec
execute_with_valid_plan scenario.
SPEC_EOF

# Pre-populate work-items with one WI
cat > "$TMP/.agent-atelier/work-items.json" <<'WI_EOF'
{
  "revision": 1,
  "updated_at": "2026-05-08T10:00:00Z",
  "items": [
    {
      "id": "WI-001",
      "title": "Sample WI",
      "description": "Test work item",
      "depends_on": [],
      "owned_paths": ["src/foo.ts"],
      "verify": ["bash tests/foo.sh"],
      "complexity": "simple",
      "status": "ready",
      "revision": 1
    }
  ]
}
WI_EOF

# Compute expected hashes
EXPECTED_PLAN_HASH=$(python3 -c "
import sys, json
sys.path.insert(0, '$PLUGIN_ROOT/scripts')
from _plan_hash import wi_plan_hash
print(wi_plan_hash(json.load(open('$TMP/.agent-atelier/work-items.json'))['items']))
")
EXPECTED_SPEC_HASH=$(python3 -c "
import sys
sys.path.insert(0, '$PLUGIN_ROOT/scripts')
from _plan_hash import spec_hash
print(spec_hash('$TMP/docs/product/behavior-spec.md'))
")

# Write loop-state with valid plan_approval + mode=BUILD_PLAN (pre-/execute state)
cat > "$TMP/.agent-atelier/loop-state.json" <<LS_EOF
{
  "revision": 1,
  "updated_at": "2026-05-08T10:00:00Z",
  "mode": "BUILD_PLAN",
  "active_spec": "docs/product/behavior-spec.md",
  "active_spec_revision": 1,
  "open_gates": [],
  "active_candidate_set": null,
  "candidate_queue": [],
  "team_name": null,
  "next_action": {"owner": "orchestrator", "type": "draft_first_work_item", "target": null},
  "plan_approval": {
    "approved_at": "2026-05-08T10:00:00Z",
    "wi_plan_hash": "$EXPECTED_PLAN_HASH",
    "spec_hash": "$EXPECTED_SPEC_HASH",
    "approved_by": "user"
  },
  "active_plan_cycle_id": null,
  "plan_gate": null
}
LS_EOF

# Action: transition mode→IMPLEMENT directly (no plan flow), state-commit's gate validates
TX=$(python3 -c "
import json
tx = {
  'writes': [{
    'path': '.agent-atelier/loop-state.json',
    'expected_revision': 1,
    'content': {
      'revision': 2,
      'updated_at': '2026-05-08T10:01:00Z',
      'mode': 'IMPLEMENT',
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
  pass "state-commit accepted IMPLEMENT transition with valid plan_approval"
else
  fail "should accept valid plan_approval transition, got: $RESULT"
fi

LS_PATH="$TMP/.agent-atelier/loop-state.json"
MODE=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['mode'])")
if [ "$MODE" = "IMPLEMENT" ]; then
  pass "mode is IMPLEMENT"
else
  fail "mode should be IMPLEMENT, got: $MODE"
fi

rm -rf "$TMP"
echo ""
echo "execute_with_valid_plan: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
