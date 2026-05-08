#!/usr/bin/env bash
# Scenario: ClarifyingQuestion gets logged in jsonl, response advances state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/agent-atelier"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP=$(mktemp -d); cd "$TMP"; git init -q
"$PLUGIN_ROOT/scripts/init-helpers.sh" --root "$TMP" >/dev/null

# Setup: set active_plan_cycle_id, jsonl exists empty
LS_PATH="$TMP/.agent-atelier/loop-state.json"
python3 -c "
import json
ls = json.load(open('$LS_PATH'))
ls['active_plan_cycle_id'] = 'cycle-test'
json.dump(ls, open('$LS_PATH', 'w'), indent=2)
"

CYCLE_DIR="$TMP/.agent-atelier/plan-conversations"
mkdir -p "$CYCLE_DIR"
JSONL="$CYCLE_DIR/cycle-test.jsonl"
: > "$JSONL"

# Append a ClarifyingQuestion (seq 1)
python3 -c "
import json
entry = {
  'seq': 1,
  'ts': '2026-05-08T10:00:00Z',
  'type': 'clarifying_question',
  'round': 1,
  'phase': 'SPEC_DRAFT',
  'from_role': 'PM',
  'payload': {
    'id': 'CQ-001',
    'from_role': 'PM',
    'phase': 'SPEC_DRAFT',
    'topic': 'data flow',
    'question': 'A or B?',
    'options': ['option_a', 'option_b'],
    'recommended': 'option_a',
    'reasoning': 'simpler',
    'blocking': True
  }
}
with open('$JSONL', 'a') as fh:
    fh.write(json.dumps(entry) + '\n')
"

# Append a user_response (seq 2)
python3 -c "
import json
entry = {
  'seq': 2,
  'ts': '2026-05-08T10:01:00Z',
  'type': 'user_response',
  'round': 1,
  'phase': 'SPEC_DRAFT',
  'from_role': 'Orchestrator',
  'payload': {'cq_id': 'CQ-001', 'choice': 'option_a'}
}
with open('$JSONL', 'a') as fh:
    fh.write(json.dumps(entry) + '\n')
"

# Assertions
LINE_COUNT=$(wc -l < "$JSONL" | tr -d ' ')
if [ "$LINE_COUNT" = "2" ]; then
  pass "jsonl has 2 entries"
else
  fail "jsonl should have 2 entries, got: $LINE_COUNT"
fi

# Validate each entry against the schema (minimal: required fields + type enum)
VALIDATE_OUT=$(python3 <<PYEOF
import json
schema_path = "$PLUGIN_ROOT/schema/plan-conversation-entry.schema.json"
schema = json.load(open(schema_path))
required = schema['required']
type_enum = schema['properties']['type']['enum']

errors = []
with open("$JSONL") as fh:
    for i, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except Exception as e:
            errors.append(f"line {i}: invalid JSON ({e})")
            continue
        for field in required:
            if field not in entry:
                errors.append(f"line {i}: missing required field '{field}'")
        if entry.get('type') not in type_enum:
            errors.append(f"line {i}: type '{entry.get('type')}' not in enum")
        if not isinstance(entry.get('seq'), int) or entry['seq'] < 1:
            errors.append(f"line {i}: invalid seq")

if errors:
    print('FAIL: ' + '; '.join(errors))
else:
    print('OK')
PYEOF
)

if [ "$VALIDATE_OUT" = "OK" ]; then
  pass "all jsonl entries validate against plan-conversation-entry schema"
else
  fail "schema validation failed: $VALIDATE_OUT"
fi

# Verify the CQ payload also validates against the clarifying-question schema (required fields)
CQ_VALIDATE=$(python3 <<PYEOF
import json
schema = json.load(open("$PLUGIN_ROOT/schema/clarifying-question.schema.json"))
required = schema['required']
with open("$JSONL") as fh:
    for line in fh:
        entry = json.loads(line)
        if entry.get('type') == 'clarifying_question':
            payload = entry.get('payload', {})
            missing = [f for f in required if f not in payload]
            if missing:
                print(f"missing fields: {missing}")
            else:
                print("OK")
            break
PYEOF
)
if [ "$CQ_VALIDATE" = "OK" ]; then
  pass "ClarifyingQuestion payload has all required fields"
else
  fail "CQ payload incomplete: $CQ_VALIDATE"
fi

rm -rf "$TMP"
echo ""
echo "pingpong_basic: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
