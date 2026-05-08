#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# Test 1: fresh init
TMP1=$(mktemp -d); cd "$TMP1"; git init -q
"$ROOT/plugins/agent-atelier/scripts/init-helpers.sh" --root "$TMP1" >/tmp/init.out 2>&1
[ -f "$TMP1/.agent-atelier/loop-state.json" ] && pass "init creates loop-state.json" || fail "loop-state.json not created"
[ -f "$TMP1/.agent-atelier/work-items.json" ] && pass "init creates work-items.json" || fail "work-items.json not created"
[ -d "$TMP1/.agent-atelier/plan-conversations" ] && pass "init creates plan-conversations dir" || fail "plan-conversations missing"
python3 -c "import json; d=json.load(open('$TMP1/.agent-atelier/loop-state.json')); assert 'plan_approval' in d and 'active_plan_cycle_id' in d and 'plan_gate' in d" 2>/dev/null && \
  pass "loop-state has new plan_* fields" || fail "loop-state missing plan_* fields"

# Test 2: idempotent re-run
"$ROOT/plugins/agent-atelier/scripts/init-helpers.sh" --root "$TMP1" >/dev/null 2>&1
echo '{"revision":1,"updated_at":"2026-01-01T00:00:00Z","items":[{"id":"WI-CUSTOM"}]}' > "$TMP1/.agent-atelier/work-items.json"  # tamper to detect overwrite
"$ROOT/plugins/agent-atelier/scripts/init-helpers.sh" --root "$TMP1" >/dev/null 2>&1
python3 -c "import json; d=json.load(open('$TMP1/.agent-atelier/work-items.json')); assert d.get('revision') == 1 and d.get('updated_at') == '2026-01-01T00:00:00Z' and d['items'][0].get('id') == 'WI-CUSTOM'" 2>/dev/null && \
  pass "re-run does not overwrite existing values" || fail "re-run overwrote existing values"

# Test 3: migration of legacy state file (missing plan_* fields)
TMP2=$(mktemp -d); cd "$TMP2"; git init -q
mkdir -p .agent-atelier
echo '{"revision":1,"updated_at":"2026-01-01T00:00:00Z","mode":"DISCOVER","open_gates":[],"active_candidate_set":null,"candidate_queue":[],"team_name":null,"next_action":{"owner":"orchestrator","type":"draft_first_work_item","target":null}}' > .agent-atelier/loop-state.json
"$ROOT/plugins/agent-atelier/scripts/init-helpers.sh" --root "$TMP2" >/tmp/migrate.out 2>&1
python3 -c "import json; d=json.load(open('$TMP2/.agent-atelier/loop-state.json')); assert 'plan_approval' in d and d['plan_approval'] is None and d['revision']==1" 2>/dev/null && \
  pass "migration adds missing top-level keys without bumping revision" || fail "migration didn't add keys correctly"

rm -rf "$TMP1" "$TMP2"
echo ""
echo "Init helpers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
