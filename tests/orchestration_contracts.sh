#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_VRM="$ROOT/plugins/agent-atelier/scripts/build-vrm-prompt"
HOOK="$ROOT/plugins/agent-atelier/hooks/on-task-completed.sh"
PROMPT_HOOK="$ROOT/plugins/agent-atelier/hooks/on-prompt.sh"
SCHEMA="$ROOT/plugins/agent-atelier/schema/vrm-evidence-input.schema.json"
RUN_SKILL="$ROOT/plugins/agent-atelier/skills/run/SKILL.md"
MONITORS_SKILL="$ROOT/plugins/agent-atelier/skills/monitors/SKILL.md"
EXECUTE_SKILL="$ROOT/plugins/agent-atelier/skills/execute/SKILL.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== Orchestration Contract Tests ==="

# ── Test 1: VRM schema is batch-aware ────────────────────────────────
if python3 - "$SCHEMA" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    schema = json.load(fh)
required = set(schema["required"])
props = schema["properties"]
assert "candidate_set_id" in required
assert "work_item_ids" in required
assert "work_item_id" not in required
assert "candidate_set_id" in props
assert "work_item_ids" in props
assert "work_item_id" not in props
PY
then
  pass "VRM schema requires candidate_set_id + work_item_ids"
else
  fail "VRM schema is not aligned with batch validation"
fi

# ── Test 2: build-vrm-prompt emits schema-aligned batch payload ─────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/.agent-atelier"

cat > "$TMPDIR/.agent-atelier/loop-state.json" <<'EOF'
{
  "revision": 1,
  "updated_at": "2026-04-16T12:00:00Z",
  "mode": "VALIDATE",
  "active_candidate_set": {
    "id": "CS-007",
    "work_item_ids": ["WI-101", "WI-102"],
    "branch": "candidate/batch",
    "commit": "abc1234",
    "type": "batch",
    "activated_at": "2026-04-16T12:00:00Z"
  },
  "candidate_queue": []
}
EOF

cat > "$TMPDIR/.agent-atelier/work-items.json" <<'EOF'
{
  "revision": 1,
  "updated_at": "2026-04-16T12:00:00Z",
  "items": [
    {
      "id": "WI-101",
      "status": "candidate_validating",
      "behavior_spec_revision": 3,
      "behaviors": ["B1"],
      "input_artifacts": ["docs/product/context.md#C1"],
      "owned_paths": ["app/models/order.rb"],
      "verify": ["bundle exec rspec spec/models/order_spec.rb"],
      "relevant_constraints": ["must preserve totals"],
      "non_goals": ["UI polish"]
    },
    {
      "id": "WI-102",
      "status": "candidate_validating",
      "behavior_spec_revision": 5,
      "behaviors": ["B2"],
      "input_artifacts": [],
      "owned_paths": ["app/services/checkout.rb"],
      "verify": ["bundle exec rspec spec/services/checkout_spec.rb"],
      "relevant_constraints": ["no public API change"],
      "non_goals": []
    }
  ]
}
EOF

RESULT="$("$BUILD_VRM" --root "$TMPDIR")"
if RESULT_JSON="$RESULT" python3 - "$SCHEMA" <<'PY'
import json, os, sys
schema_path = sys.argv[1]
payload = json.loads(os.environ["RESULT_JSON"])
with open(schema_path, encoding="utf-8") as fh:
    schema = json.load(fh)

assert payload["candidate_set_id"] == "CS-007"
assert payload["work_item_ids"] == ["WI-101", "WI-102"]
assert "work_item_id" not in payload
assert payload["behavior_spec_revision"] == 5
assert set(payload["files_expected"]) == {"app/models/order.rb", "app/services/checkout.rb"}
assert set(payload["verification_commands"]) == {
    "bundle exec rspec spec/models/order_spec.rb",
    "bundle exec rspec spec/services/checkout_spec.rb",
}
assert set(payload.keys()) <= set(schema["properties"].keys())
assert set(schema["required"]) <= set(payload.keys())
PY
then
  pass "build-vrm-prompt emits batch-aware schema-aligned payload"
else
  fail "build-vrm-prompt payload is not schema-aligned"
fi

# ── Test 3: BUILD_PLAN verify gate blocks ready WI without verify ───
cat > "$TMPDIR/.agent-atelier/loop-state.json" <<'EOF'
{
  "revision": 2,
  "updated_at": "2026-04-16T12:05:00Z",
  "mode": "BUILD_PLAN"
}
EOF

cat > "$TMPDIR/.agent-atelier/work-items.json" <<'EOF'
{
  "revision": 2,
  "updated_at": "2026-04-16T12:05:00Z",
  "items": [
    {"id": "WI-201", "status": "ready", "complexity": "simple", "verify": []}
  ]
}
EOF

RESULT=$(cd "$TMPDIR" && "$HOOK" 2>&1; echo "EXIT:$?")
if echo "$RESULT" | grep -q "BUILD_PLAN cannot advance" && echo "$RESULT" | grep -q "missing verify" && echo "$RESULT" | grep -q "EXIT:2"; then
  pass "TaskCompleted hook blocks BUILD_PLAN when ready WI lacks verify"
else
  fail "TaskCompleted hook did not block missing verify in BUILD_PLAN"
fi

# ── Test 4: BUILD_PLAN complexity gate blocks ready WI with null ────
cat > "$TMPDIR/.agent-atelier/work-items.json" <<'EOF'
{
  "revision": 3,
  "updated_at": "2026-04-16T12:06:00Z",
  "items": [
    {"id": "WI-202", "status": "ready", "complexity": null, "verify": ["bin/test"]}
  ]
}
EOF

RESULT=$(cd "$TMPDIR" && "$HOOK" 2>&1; echo "EXIT:$?")
if echo "$RESULT" | grep -q "missing complexity" && echo "$RESULT" | grep -q "EXIT:2"; then
  pass "TaskCompleted hook blocks BUILD_PLAN when ready WI lacks complexity"
else
  fail "TaskCompleted hook did not block null complexity in BUILD_PLAN"
fi

# ── Test 5: Hook does not block active implementation for verify gate ─
cat > "$TMPDIR/.agent-atelier/loop-state.json" <<'EOF'
{
  "revision": 4,
  "updated_at": "2026-04-16T12:07:00Z",
  "mode": "IMPLEMENT"
}
EOF

cat > "$TMPDIR/.agent-atelier/work-items.json" <<'EOF'
{
  "revision": 4,
  "updated_at": "2026-04-16T12:07:00Z",
  "items": [
    {"id": "WI-203", "status": "implementing", "complexity": "simple", "verify": []}
  ]
}
EOF

if (cd "$TMPDIR" && "$HOOK" >/dev/null 2>&1); then
  pass "TaskCompleted hook does not misapply BUILD_PLAN gate during IMPLEMENT"
else
  fail "TaskCompleted hook should not block IMPLEMENT for missing verify"
fi

# ── Test 6: Fast-track instructions are consistent across docs ──────
if grep -q 'ci_status` (success) → evaluate fast-track, then transition to IMPLEMENT or REVIEW_SYNTHESIS' "$RUN_SKILL" \
  && grep -q 'ci_status` (success) → evaluate fast-track, then transition to IMPLEMENT or REVIEW_SYNTHESIS' "$MONITORS_SKILL"; then
  pass "Run and monitors docs agree on fast-track handling"
else
  fail "Run and monitors docs disagree on fast-track handling"
fi

# ── Test 7: on-prompt reports active_candidate_set, not legacy field ─
cat > "$TMPDIR/.agent-atelier/loop-state.json" <<'EOF'
{
  "revision": 5,
  "updated_at": "2026-04-16T12:08:00Z",
  "mode": "VALIDATE",
  "open_gates": ["HDR-001"],
  "active_candidate_set": {
    "id": "CS-009",
    "work_item_ids": ["WI-301", "WI-302"],
    "branch": "candidate/batch",
    "commit": "abc1234",
    "type": "batch",
    "activated_at": "2026-04-16T12:08:00Z"
  }
}
EOF

RESULT=$(cd "$TMPDIR" && git init -q && "$PROMPT_HOOK")
if echo "$RESULT" | grep -q 'active_candidate_set=CS-009 (WI-301, WI-302)' \
  && ! echo "$RESULT" | grep -q 'active_candidate='; then
  pass "Prompt hook reports active_candidate_set signal"
else
  fail "Prompt hook still reports legacy active_candidate signal"
fi

# ── Test 8: execute complete no longer accepts candidate_validating ──
if grep -q 'For `complete`: work item must be in `reviewing` status' "$EXECUTE_SKILL" \
  && ! grep -q 'reviewing` or `candidate_validating' "$EXECUTE_SKILL"; then
  pass "Execute skill restricts completion to reviewing state"
else
  fail "Execute skill still allows completion from candidate_validating"
fi

echo ""
echo "Orchestration contracts: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
