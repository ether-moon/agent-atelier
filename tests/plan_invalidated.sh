#!/usr/bin/env bash
# Scenario: spec hash mismatch causes plan invalidation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/agent-atelier"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP=$(mktemp -d); cd "$TMP"; git init -q
"$PLUGIN_ROOT/scripts/init-helpers.sh" --root "$TMP" >/dev/null

# Setup: original behavior-spec.md
mkdir -p "$TMP/docs/product"
cat > "$TMP/docs/product/behavior-spec.md" <<'SPEC_EOF'
# Behavior Spec
Original content.
SPEC_EOF

# Compute hashes against ORIGINAL spec
ORIG_PLAN_HASH=$(python3 -c "
import sys
sys.path.insert(0, '$PLUGIN_ROOT/scripts')
from _plan_hash import wi_plan_hash
print(wi_plan_hash([]))
")
ORIG_SPEC_HASH=$(python3 -c "
import sys
sys.path.insert(0, '$PLUGIN_ROOT/scripts')
from _plan_hash import spec_hash
print(spec_hash('$TMP/docs/product/behavior-spec.md'))
")

# Write loop-state with plan_approval based on ORIGINAL spec content
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
    "wi_plan_hash": "$ORIG_PLAN_HASH",
    "spec_hash": "$ORIG_SPEC_HASH",
    "approved_by": "user"
  },
  "active_plan_cycle_id": null,
  "plan_gate": null
}
LS_EOF

# Now MODIFY behavior-spec.md (simulating a user edit after approval)
cat > "$TMP/docs/product/behavior-spec.md" <<'SPEC_EOF2'
# Behavior Spec
DIFFERENT content — invalidates the plan.
SPEC_EOF2

# Verify spec_hash actually changed
NEW_SPEC_HASH=$(python3 -c "
import sys
sys.path.insert(0, '$PLUGIN_ROOT/scripts')
from _plan_hash import spec_hash
print(spec_hash('$TMP/docs/product/behavior-spec.md'))
")
if [ "$NEW_SPEC_HASH" != "$ORIG_SPEC_HASH" ]; then
  pass "spec_hash changed after edit"
else
  fail "spec_hash should differ after edit, got same: $NEW_SPEC_HASH"
fi

# Action: attempt mode→IMPLEMENT with stale plan_approval (orig hashes)
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
        'wi_plan_hash': '$ORIG_PLAN_HASH',
        'spec_hash': '$ORIG_SPEC_HASH',
        'approved_by': 'user'
      },
      'active_plan_cycle_id': None,
      'plan_gate': None
    }
  }]
}
print(json.dumps(tx))
")

RESULT=$(echo "$TX" | "$PLUGIN_ROOT/scripts/state-commit" --root "$TMP" 2>&1 || true)

if echo "$RESULT" | grep -q "implement_gate_violation"; then
  pass "state-commit rejected stale plan_approval (spec_hash mismatch)"
else
  fail "should reject stale plan_approval, got: $RESULT"
fi

if echo "$RESULT" | grep -q "spec_hash mismatch"; then
  pass "rejection reason mentions spec_hash mismatch"
else
  fail "rejection reason should mention spec_hash mismatch, got: $RESULT"
fi

# Verify mode did NOT change (still BUILD_PLAN)
LS_PATH="$TMP/.agent-atelier/loop-state.json"
MODE=$(python3 -c "import json; print(json.load(open('$LS_PATH'))['mode'])")
if [ "$MODE" = "BUILD_PLAN" ]; then
  pass "mode preserved after rejection"
else
  fail "mode should still be BUILD_PLAN, got: $MODE"
fi

rm -rf "$TMP"
echo ""
echo "plan_invalidated: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
