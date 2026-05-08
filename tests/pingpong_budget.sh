#!/usr/bin/env bash
# Scenario: 30+ questions trigger budget alert + blocking force-false.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/agent-atelier"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP=$(mktemp -d); cd "$TMP"; git init -q
"$PLUGIN_ROOT/scripts/init-helpers.sh" --root "$TMP" >/dev/null

CYCLE_DIR="$TMP/.agent-atelier/plan-conversations"
mkdir -p "$CYCLE_DIR"
JSONL="$CYCLE_DIR/cycle-budget.jsonl"
: > "$JSONL"

# Generate 31 ClarifyingQuestion entries: blocking=true for first 25,
# blocking=false for entries 26..31 (orchestrator force-false rule per spec).
python3 <<PYEOF
import json
entries = []
for i in range(1, 32):  # 31 questions
    blocking = i <= 25
    entries.append({
        'seq': i,
        'ts': f'2026-05-08T10:{i:02d}:00Z',
        'type': 'clarifying_question',
        'round': 1,
        'phase': 'BUILD_PLAN',
        'from_role': 'PM',
        'payload': {
            'id': f'CQ-{i:03d}',
            'from_role': 'PM',
            'phase': 'BUILD_PLAN',
            'topic': f'topic_{i}',
            'question': f'Q{i}?',
            'options': ['a', 'b'],
            'recommended': 'a',
            'reasoning': '',
            'blocking': blocking
        }
    })
with open("$JSONL", 'a') as fh:
    for e in entries:
        fh.write(json.dumps(e) + '\n')
PYEOF

# Assertions
LINE_COUNT=$(wc -l < "$JSONL" | tr -d ' ')
if [ "$LINE_COUNT" = "31" ]; then
  pass "jsonl has 31 entries"
else
  fail "expected 31 entries, got: $LINE_COUNT"
fi

# Count CQs
Q_COUNT=$(python3 -c "
import json
n = 0
with open('$JSONL') as fh:
    for line in fh:
        if not line.strip(): continue
        if json.loads(line)['type'] == 'clarifying_question':
            n += 1
print(n)
")
if [ "$Q_COUNT" -gt 30 ]; then
  pass "question count > 30 (= $Q_COUNT)"
else
  fail "expected >30 CQs, got: $Q_COUNT"
fi

# Verify entries 26-31 have blocking=false (force-false per spec)
FORCE_FALSE_OK=$(python3 <<PYEOF
import json
violations = []
with open("$JSONL") as fh:
    for line in fh:
        if not line.strip(): continue
        e = json.loads(line)
        if e['type'] != 'clarifying_question':
            continue
        seq = e['seq']
        blocking = e['payload'].get('blocking')
        if seq > 25 and blocking is True:
            violations.append(f'seq {seq} should be non-blocking')
print('OK' if not violations else '; '.join(violations))
PYEOF
)
if [ "$FORCE_FALSE_OK" = "OK" ]; then
  pass "questions beyond budget warn-at (25) are non-blocking"
else
  fail "$FORCE_FALSE_OK"
fi

# Verify the budget threshold values are present in watchdog defaults
WATCHDOG_PATH="$TMP/.agent-atelier/watchdog-jobs.json"
BUDGET_OK=$(python3 -c "
import json
d = json.load(open('$WATCHDOG_PATH'))['defaults']
ok = d.get('plan_question_budget') == 30 and d.get('plan_question_warn_at') == 25
print('OK' if ok else f'budget={d.get(\"plan_question_budget\")} warn={d.get(\"plan_question_warn_at\")}')
")
if [ "$BUDGET_OK" = "OK" ]; then
  pass "watchdog defaults include plan_question_budget=30, warn_at=25"
else
  fail "watchdog defaults wrong: $BUDGET_OK"
fi

rm -rf "$TMP"
echo ""
echo "pingpong_budget: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
