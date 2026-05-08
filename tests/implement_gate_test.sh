#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# Setup: temp repo with initialized state
TMP=$(mktemp -d)
cd "$TMP"
git init -q
mkdir -p .agent-atelier
cat > .agent-atelier/loop-state.json <<'EOF'
{"revision": 1, "updated_at": "2026-05-08T10:00:00Z", "mode": "BUILD_PLAN", "open_gates": [], "active_candidate_set": null, "candidate_queue": [], "plan_approval": null, "active_plan_cycle_id": "cycle-test", "plan_gate": null}
EOF
cat > .agent-atelier/work-items.json <<'EOF'
{"revision": 1, "updated_at": "2026-05-08T10:00:00Z", "items": [{"id":"WI-001","title":"t","description":"d","depends_on":[],"owned_paths":["x"],"verify":["v"],"complexity":"simple","status":"ready","revision":1}]}
EOF

# Test 1: mode→IMPLEMENT without plan_approval should be rejected
TX='{"writes":[{"path":".agent-atelier/loop-state.json","expected_revision":1,"content":{"revision":2,"updated_at":"2026-05-08T10:01:00Z","mode":"IMPLEMENT","open_gates":[],"active_candidate_set":null,"candidate_queue":[],"plan_approval":null,"active_plan_cycle_id":"cycle-test","plan_gate":null}}]}'
RESULT=$(echo "$TX" | "$ROOT/plugins/agent-atelier/scripts/state-commit" --root "$TMP" 2>&1 || true)
if echo "$RESULT" | grep -q "implement_gate_violation"; then
  pass "rejects mode→IMPLEMENT without plan_approval"
else
  fail "should reject mode→IMPLEMENT without plan_approval, got: $RESULT"
fi

# Test 2: mode→IMPLEMENT with valid plan_approval (matching hashes) should succeed
# Compute current hashes
EXPECTED_PLAN_HASH=$(python3 -c "
import sys, json; sys.path.insert(0, '$ROOT/plugins/agent-atelier/scripts')
from _plan_hash import wi_plan_hash
print(wi_plan_hash(json.load(open('$TMP/.agent-atelier/work-items.json'))['items']))
")
EXPECTED_SPEC_HASH="null"

TX2='{"writes":[{"path":".agent-atelier/loop-state.json","expected_revision":1,"content":{"revision":2,"updated_at":"2026-05-08T10:01:00Z","mode":"IMPLEMENT","open_gates":[],"active_candidate_set":null,"candidate_queue":[],"plan_approval":{"approved_at":"2026-05-08T10:01:00Z","wi_plan_hash":"'"$EXPECTED_PLAN_HASH"'","spec_hash":"null","approved_by":"user"},"active_plan_cycle_id":null,"plan_gate":null}}]}'
RESULT2=$(echo "$TX2" | "$ROOT/plugins/agent-atelier/scripts/state-commit" --root "$TMP" 2>&1 || true)
if echo "$RESULT2" | grep -q '"committed": true'; then
  pass "accepts mode→IMPLEMENT with matching plan_approval"
else
  fail "should accept matching plan_approval, got: $RESULT2"
fi

# Test 3: mode→IMPLEMENT with stale wi_plan_hash should be rejected
echo '{"revision": 1, "updated_at": "2026-05-08T10:00:00Z", "mode": "BUILD_PLAN", "open_gates": [], "active_candidate_set": null, "candidate_queue": [], "plan_approval": null, "active_plan_cycle_id": "cycle-test", "plan_gate": null}' > .agent-atelier/loop-state.json
echo '{"revision": 1, "updated_at": "2026-05-08T10:00:00Z", "items": [{"id":"WI-001","title":"t","description":"d","depends_on":[],"owned_paths":["x"],"verify":["v"],"complexity":"simple","status":"ready","revision":1}]}' > .agent-atelier/work-items.json
TX3='{"writes":[{"path":".agent-atelier/loop-state.json","expected_revision":1,"content":{"revision":2,"updated_at":"2026-05-08T10:01:00Z","mode":"IMPLEMENT","open_gates":[],"active_candidate_set":null,"candidate_queue":[],"plan_approval":{"approved_at":"2026-05-08T10:01:00Z","wi_plan_hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","spec_hash":"null","approved_by":"user"},"active_plan_cycle_id":null,"plan_gate":null}}]}'
RESULT3=$(echo "$TX3" | "$ROOT/plugins/agent-atelier/scripts/state-commit" --root "$TMP" 2>&1 || true)
if echo "$RESULT3" | grep -q "implement_gate_violation"; then
  pass "rejects mode→IMPLEMENT with stale wi_plan_hash"
else
  fail "should reject stale hash, got: $RESULT3"
fi

rm -rf "$TMP"
echo ""
echo "Implement gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
