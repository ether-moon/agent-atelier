#!/usr/bin/env bash
# Scenario: "네가 결정" response logs assumption.
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
JSONL="$CYCLE_DIR/cycle-assume.jsonl"
: > "$JSONL"

# 1) Append a CQ
python3 -c "
import json
entry = {
  'seq': 1,
  'ts': '2026-05-08T10:00:00Z',
  'type': 'clarifying_question',
  'round': 1,
  'phase': 'BUILD_PLAN',
  'from_role': 'Architect',
  'payload': {
    'id': 'CQ-001',
    'from_role': 'Architect',
    'phase': 'BUILD_PLAN',
    'topic': 'storage backend',
    'question': 'Postgres or SQLite?',
    'options': ['postgres', 'sqlite'],
    'recommended': 'postgres',
    'reasoning': 'scales better',
    'blocking': True
  }
}
with open('$JSONL', 'a') as fh:
    fh.write(json.dumps(entry) + '\n')
"

# 2) User responds with '네가 결정' → recommended adopted as assumption
python3 -c "
import json
entry = {
  'seq': 2,
  'ts': '2026-05-08T10:01:00Z',
  'type': 'user_response',
  'round': 1,
  'phase': 'BUILD_PLAN',
  'from_role': 'Orchestrator',
  'payload': {
    'cq_id': 'CQ-001',
    'choice': '네가 결정',
    'accepted_recommendation': True,
    'adopted_value': 'postgres',
    'assumption_marker': True
  }
}
with open('$JSONL', 'a') as fh:
    fh.write(json.dumps(entry) + '\n')
"

# 3) Append an artifact_update marking the assumption was applied
python3 -c "
import json
entry = {
  'seq': 3,
  'ts': '2026-05-08T10:02:00Z',
  'type': 'artifact_update',
  'round': 1,
  'phase': 'BUILD_PLAN',
  'from_role': 'Architect',
  'payload': {
    'artifact_path': 'docs/product/behavior-spec.md',
    'before_revision': 1,
    'after_revision': 2,
    'diff_summary': 'storage backend assumption: postgres (per CQ-001)'
  }
}
with open('$JSONL', 'a') as fh:
    fh.write(json.dumps(entry) + '\n')
"

# Assertions
LINE_COUNT=$(wc -l < "$JSONL" | tr -d ' ')
if [ "$LINE_COUNT" = "3" ]; then
  pass "jsonl has 3 entries"
else
  fail "jsonl should have 3 entries, got: $LINE_COUNT"
fi

# Verify "네가 결정" assumption marker is present in user_response
ASSUME_OK=$(python3 <<PYEOF
import json
with open("$JSONL") as fh:
    lines = [json.loads(l) for l in fh if l.strip()]
ur = [e for e in lines if e['type'] == 'user_response']
if not ur:
    print("no user_response")
elif ur[0]['payload'].get('choice') == '네가 결정' and ur[0]['payload'].get('assumption_marker') is True:
    print("OK")
else:
    print(f"missing assumption marker, payload={ur[0]['payload']}")
PYEOF
)
if [ "$ASSUME_OK" = "OK" ]; then
  pass "user_response carries '네가 결정' choice + assumption_marker"
else
  fail "$ASSUME_OK"
fi

# Verify artifact_update follows the user_response
ARTIFACT_OK=$(python3 <<PYEOF
import json
with open("$JSONL") as fh:
    lines = [json.loads(l) for l in fh if l.strip()]
au = [e for e in lines if e['type'] == 'artifact_update']
if au and 'diff_summary' in au[0].get('payload', {}):
    print("OK")
else:
    print("FAIL")
PYEOF
)
if [ "$ARTIFACT_OK" = "OK" ]; then
  pass "artifact_update logged with diff_summary"
else
  fail "artifact_update missing or malformed"
fi

# Schema validation for all entries
SCHEMA_OK=$(python3 <<PYEOF
import json
schema = json.load(open("$PLUGIN_ROOT/schema/plan-conversation-entry.schema.json"))
required = schema['required']
type_enum = schema['properties']['type']['enum']
errors = []
with open("$JSONL") as fh:
    for i, line in enumerate(fh, 1):
        if not line.strip():
            continue
        entry = json.loads(line)
        for f in required:
            if f not in entry:
                errors.append(f"line {i}: missing {f}")
        if entry.get('type') not in type_enum:
            errors.append(f"line {i}: bad type")
print('OK' if not errors else '; '.join(errors))
PYEOF
)
if [ "$SCHEMA_OK" = "OK" ]; then
  pass "all entries validate against schema"
else
  fail "schema errors: $SCHEMA_OK"
fi

rm -rf "$TMP"
echo ""
echo "pingpong_assume: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
