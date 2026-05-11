#!/usr/bin/env bash
# Scenario: cold resume reads active_plan_cycle_id and continues from last jsonl entry.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/agent-atelier"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP=$(mktemp -d); cd "$TMP"; git init -q
"$PLUGIN_ROOT/scripts/init-helpers.sh" --root "$TMP" >/dev/null

LS_PATH="$TMP/.agent-atelier/loop-state.json"

# Setup: write loop-state with active_plan_cycle_id = "cycle-resume"
python3 -c "
import json
ls = json.load(open('$LS_PATH'))
ls['active_plan_cycle_id'] = 'cycle-resume'
ls['mode'] = 'BUILD_PLAN'
json.dump(ls, open('$LS_PATH', 'w'), indent=2)
"

# Build jsonl with 5 entries ending in a clarifying_question
CYCLE_DIR="$TMP/.agent-atelier/plan-conversations"
mkdir -p "$CYCLE_DIR"
JSONL="$CYCLE_DIR/cycle-resume.jsonl"

python3 <<PYEOF
import json
entries = [
    {'seq': 1, 'ts': '2026-05-08T10:00:00Z', 'type': 'phase_transition',
     'round': 1, 'phase': 'DISCOVER', 'from_role': 'Orchestrator',
     'payload': {'from': None, 'to': 'DISCOVER'}},
    {'seq': 2, 'ts': '2026-05-08T10:01:00Z', 'type': 'clarifying_question',
     'round': 1, 'phase': 'DISCOVER', 'from_role': 'PM',
     'payload': {'id': 'CQ-001', 'from_role': 'PM', 'phase': 'DISCOVER',
                 'topic': 'scope', 'question': 'in or out?',
                 'options': ['in', 'out'], 'recommended': 'in',
                 'reasoning': '', 'blocking': True}},
    {'seq': 3, 'ts': '2026-05-08T10:02:00Z', 'type': 'user_response',
     'round': 1, 'phase': 'DISCOVER', 'from_role': 'Orchestrator',
     'payload': {'cq_id': 'CQ-001', 'choice': 'in'}},
    {'seq': 4, 'ts': '2026-05-08T10:03:00Z', 'type': 'phase_transition',
     'round': 1, 'phase': 'SPEC_DRAFT', 'from_role': 'Orchestrator',
     'payload': {'from': 'DISCOVER', 'to': 'SPEC_DRAFT'}},
    {'seq': 5, 'ts': '2026-05-08T10:04:00Z', 'type': 'clarifying_question',
     'round': 2, 'phase': 'SPEC_DRAFT', 'from_role': 'PM',
     'payload': {'id': 'CQ-002', 'from_role': 'PM', 'phase': 'SPEC_DRAFT',
                 'topic': 'shape', 'question': 'A or B?',
                 'options': ['A', 'B'], 'recommended': 'A',
                 'reasoning': '', 'blocking': True}},
]
with open("$JSONL", 'w') as fh:
    for e in entries:
        fh.write(json.dumps(e) + '\n')
PYEOF

# Action: simulate cold resume — read active_plan_cycle_id, locate jsonl, find last entry
RESUME_RESULT=$(python3 <<PYEOF
import json
ls = json.load(open("$LS_PATH"))
cycle_id = ls.get('active_plan_cycle_id')
if not cycle_id:
    print("FAIL: no active_plan_cycle_id")
else:
    jsonl_path = f"$TMP/.agent-atelier/plan-conversations/{cycle_id}.jsonl"
    with open(jsonl_path) as fh:
        lines = [json.loads(l) for l in fh if l.strip()]
    if not lines:
        print("FAIL: empty jsonl")
    else:
        last = lines[-1]
        print(f"OK|{cycle_id}|{len(lines)}|{last['type']}|{last['seq']}")
PYEOF
)

if [[ "$RESUME_RESULT" == OK\|* ]]; then
  pass "cold resume located active cycle and read jsonl"
else
  fail "resume failed: $RESUME_RESULT"
fi

# Parse the result
IFS='|' read -r _ CYCLE_ID LINE_CT LAST_TYPE LAST_SEQ <<< "$RESUME_RESULT"

if [ "$CYCLE_ID" = "cycle-resume" ]; then
  pass "cycle id matches: $CYCLE_ID"
else
  fail "cycle id should be cycle-resume, got: $CYCLE_ID"
fi

if [ "$LINE_CT" = "5" ]; then
  pass "jsonl has 5 entries"
else
  fail "expected 5 entries, got: $LINE_CT"
fi

if [ "$LAST_TYPE" = "clarifying_question" ]; then
  pass "last entry type = clarifying_question"
else
  fail "last entry should be clarifying_question, got: $LAST_TYPE"
fi

if [ "$LAST_SEQ" = "5" ]; then
  pass "last entry seq = 5"
else
  fail "last seq should be 5, got: $LAST_SEQ"
fi

rm -rf "$TMP"
echo ""
echo "cold_resume_pingpong: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
