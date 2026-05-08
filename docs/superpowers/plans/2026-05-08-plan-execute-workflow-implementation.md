# plan/execute 워크플로우 + 핑퐁 루프 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the plan/execute user-facing workflow per `docs/superpowers/specs/2026-05-08-plan-execute-workflow-design.md` — `/plan` and `/execute` slash commands with mandatory ping-pong gate before IMPLEMENT, and migrate internal skills (wi/gate/watchdog/candidate/validate/execute-lifecycle/monitors) to scripts and references.

**Architecture:** State model adds `plan_approval` (with `wi_plan_hash` + `spec_hash`), `active_plan_cycle_id`, `plan_gate` to `loop-state.json`. `state-commit` enforces a mechanical gate on `mode: BUILD_PLAN → IMPLEMENT` transitions. Internal skill commands move to `scripts/` (mechanical) with `native_task_sync` hint pattern; `monitors` becomes a thin shim delegating to `references/monitor-runtime.md`.

**Tech Stack:** Python 3 (state-commit, scripts), Bash (init-helpers, tests), Claude Code skill markdown, Agent Teams (subagent definitions).

---

## Reference Documents

- **Spec:** `docs/superpowers/specs/2026-05-08-plan-execute-workflow-design.md` — read this first; tasks reference spec sections by name.
- **Existing skills (to be ported):** `plugins/agent-atelier/skills/{wi,gate,watchdog,candidate,validate,execute,monitors,init,run}/SKILL.md` — these have full subcommand contracts; ports must preserve I/O semantics.
- **State writer:** `plugins/agent-atelier/scripts/state-commit` — extend, not replace.

---

## Task Sequence (38 tasks, 7 phases)

### Phase A: State Model Foundation (5 tasks)

#### Task A1: Add new fields to state-defaults

**Files:**
- Modify: `plugins/agent-atelier/references/state-defaults.md`

- [ ] **Step 1: Read current state-defaults.md** to confirm existing JSON shape.

- [ ] **Step 2: Add three fields to `loop-state.json` block.** Edit the JSON block under `## loop-state.json` to include (between `next_action` and the closing brace):

```json
  "plan_approval": null,
  "active_plan_cycle_id": null,
  "plan_gate": null
```

Final block structure (place new fields after `next_action`):

```json
{
  "revision": 1,
  "updated_at": "<now>",
  "mode": "DISCOVER",
  "active_spec": "docs/product/behavior-spec.md",
  "active_spec_revision": 1,
  "open_gates": [],
  "active_candidate_set": null,
  "candidate_queue": [],
  "team_name": null,
  "next_action": {
    "owner": "orchestrator",
    "type": "draft_first_work_item",
    "target": null
  },
  "plan_approval": null,
  "active_plan_cycle_id": null,
  "plan_gate": null
}
```

- [ ] **Step 3: Add new fields to `watchdog-jobs.json` block.** Under `defaults`, add `plan_question_budget: 30`, `plan_question_warn_at: 25`, `plan_user_response_timeout_hours: 24`. Final `defaults` object:

```json
"defaults": {
  "implementing_timeout_minutes": 90,
  "candidate_timeout_minutes": 30,
  "review_timeout_minutes": 30,
  "gate_warn_after_hours": 24,
  "plan_question_budget": 30,
  "plan_question_warn_at": 25,
  "plan_user_response_timeout_hours": 24
}
```

- [ ] **Step 4: Verify schema_validation.sh still passes.** Run `bash tests/schema_validation.sh` — should still pass since we only added optional fields.

- [ ] **Step 5: Commit** with message `feat(state-defaults): add plan_approval/active_plan_cycle_id/plan_gate and watchdog plan-budget fields`.

#### Task A2: Create `clarifying-question.schema.json`

**Files:**
- Create: `plugins/agent-atelier/schema/clarifying-question.schema.json`

- [ ] **Step 1: Create the schema file.** Copy the schema body from spec section "스키마 정의 / clarifying-question.schema.json":

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ClarifyingQuestion",
  "type": "object",
  "required": ["id", "from_role", "phase", "topic", "question", "options", "recommended", "blocking"],
  "properties": {
    "id": {"type": "string", "pattern": "^CQ-[0-9]{3,}$"},
    "from_role": {"enum": ["PM", "Architect"]},
    "phase": {"enum": ["DISCOVER", "SPEC_DRAFT", "SPEC_HARDEN", "BUILD_PLAN"]},
    "topic": {"type": "string", "maxLength": 60},
    "question": {"type": "string"},
    "options": {"type": "array", "items": {"type": "string"}, "maxItems": 5},
    "recommended": {"type": "string"},
    "reasoning": {"type": "string"},
    "blocking": {"type": "boolean"}
  }
}
```

- [ ] **Step 2: Validate the schema is valid JSON Schema.** Run `python3 -c "import json; json.load(open('plugins/agent-atelier/schema/clarifying-question.schema.json'))"` — should exit 0.

#### Task A3: Create `plan-conversation-entry.schema.json`

**Files:**
- Create: `plugins/agent-atelier/schema/plan-conversation-entry.schema.json`

- [ ] **Step 1: Create the schema file.** Copy from spec section "스키마 정의 / plan-conversation-entry.schema.json":

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "PlanConversationEntry",
  "type": "object",
  "required": ["seq", "ts", "type"],
  "properties": {
    "seq": {"type": "integer", "minimum": 1},
    "ts": {"type": "string", "format": "date-time"},
    "type": {"enum": [
      "clarifying_question",
      "user_response",
      "artifact_update",
      "phase_transition",
      "no_more_questions",
      "gate_presented",
      "gate_resolved",
      "round_marker"
    ]},
    "round": {"type": "integer", "minimum": 1},
    "phase": {"enum": ["DISCOVER", "SPEC_DRAFT", "SPEC_HARDEN", "BUILD_PLAN", "FINAL_REVIEW"]},
    "from_role": {"enum": ["PM", "Architect", "Orchestrator"]},
    "payload": {"type": "object"}
  }
}
```

- [ ] **Step 2: Validate JSON.** Same as A2 step 2.

- [ ] **Step 3: Commit (A2+A3 together).** Message: `feat(schema): add clarifying-question and plan-conversation-entry schemas`.

#### Task A4: Extend `schema_validation.sh`

**Files:**
- Modify: `tests/schema_validation.sh`

- [ ] **Step 1: Add validation block for the new fields.** After the existing `extract_and_validate "loop-state.json" ...` line, add a check that the loop-state JSON contains the three new keys (handled by the extract_and_validate function automatically since it parses the full block; just add explicit existence assertions).

After the existing `extract_and_validate` calls, append:

```bash
# Validate new plan_approval / active_plan_cycle_id / plan_gate fields exist in loop-state defaults
LS_BLOCK=$(awk '
  BEGIN { found=0; injson=0 }
  /^## loop-state.json/ { found=1; next }
  found && /^```json/ { injson=1; next }
  injson && /^```/ { exit }
  injson { print }
' "$DEFAULTS_FILE" | sed 's/"<now>"/"2026-04-08T00:00:00Z"/g')

if echo "$LS_BLOCK" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'plan_approval' in d and 'active_plan_cycle_id' in d and 'plan_gate' in d" 2>/dev/null; then
  pass "loop-state.json includes plan_approval, active_plan_cycle_id, plan_gate"
else
  fail "loop-state.json missing one or more of plan_approval/active_plan_cycle_id/plan_gate"
fi

# Validate new watchdog plan_* budgets
WD_BLOCK=$(awk '
  BEGIN { found=0; injson=0 }
  /^## watchdog-jobs.json/ { found=1; next }
  found && /^```json/ { injson=1; next }
  injson && /^```/ { exit }
  injson { print }
' "$DEFAULTS_FILE" | sed 's/"<now>"/"2026-04-08T00:00:00Z"/g')

if echo "$WD_BLOCK" | python3 -c "import json,sys; d=json.load(sys.stdin)['defaults']; assert 'plan_question_budget' in d and 'plan_question_warn_at' in d and 'plan_user_response_timeout_hours' in d" 2>/dev/null; then
  pass "watchdog-jobs defaults include plan_question_budget/warn_at/timeout_hours"
else
  fail "watchdog-jobs defaults missing one or more plan_* fields"
fi

# Validate new schema files
for schema in clarifying-question.schema.json plan-conversation-entry.schema.json; do
  schema_path="$ROOT/plugins/agent-atelier/schema/$schema"
  if [ -f "$schema_path" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$schema_path" 2>/dev/null; then
    pass "$schema is valid JSON Schema"
  else
    fail "$schema not found or invalid"
  fi
done
```

- [ ] **Step 2: Run** `bash tests/schema_validation.sh` — should pass with the new assertions.

- [ ] **Step 3: Commit.** Message: `test(schema): validate new plan_approval/active_plan_cycle_id/plan_gate and schema files`.

#### Task A5: Add `wi_plan_hash` and `spec_hash` helpers

**Files:**
- Create: `plugins/agent-atelier/scripts/_plan_hash.py` (Python helper module imported by state-commit and scripts/wi)
- Test: `tests/plan_hash_test.sh`

- [ ] **Step 1: Write the failing test first.** Create `tests/plan_hash_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/plugins/agent-atelier/scripts/_plan_hash.py"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# Test: execution-state fields (lease, attempt_count) don't affect hash within same status_class
H1=$(python3 -c "
import sys; sys.path.insert(0, '$ROOT/plugins/agent-atelier/scripts')
from _plan_hash import wi_plan_hash
print(wi_plan_hash([
  {'id': 'WI-001', 'title': 't', 'description': 'd', 'depends_on': [],
   'owned_paths': ['x'], 'verify': ['v'], 'complexity': 'simple', 'status': 'implementing'}
]))
")
H2=$(python3 -c "
import sys; sys.path.insert(0, '$ROOT/plugins/agent-atelier/scripts')
from _plan_hash import wi_plan_hash
print(wi_plan_hash([
  {'id': 'WI-001', 'title': 't', 'description': 'd', 'depends_on': [],
   'owned_paths': ['x'], 'verify': ['v'], 'complexity': 'simple', 'status': 'implementing',
   'lease_expires_at': '2026-05-08T01:00:00Z', 'attempt_count': 2}
]))
")
[ "$H1" = "$H2" ] && pass "execution-state fields do not affect hash within same status_class" \
                 || fail "execution-state fields changed hash unexpectedly ($H1 vs $H2)"

# Test: changing depends_on changes the hash
H3=$(python3 -c "
import sys; sys.path.insert(0, '$ROOT/plugins/agent-atelier/scripts')
from _plan_hash import wi_plan_hash
print(wi_plan_hash([
  {'id': 'WI-001', 'title': 't', 'description': 'd', 'depends_on': ['WI-000'],
   'owned_paths': ['x'], 'verify': ['v'], 'complexity': 'simple', 'status': 'ready'}
]))
")
[ "$H1" != "$H3" ] && pass "changing depends_on changes hash" \
                  || fail "depends_on change did not change hash"

# Test: spec_hash null on missing file
H_NULL=$(python3 -c "
import sys; sys.path.insert(0, '$ROOT/plugins/agent-atelier/scripts')
from _plan_hash import spec_hash
print(spec_hash('/nonexistent/path.md'))
")
[ "$H_NULL" = "null" ] && pass "spec_hash returns 'null' for missing file" \
                       || fail "spec_hash should return 'null' for missing file but got $H_NULL"

echo ""
echo "Plan hash: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

Make executable: `chmod +x tests/plan_hash_test.sh`.

- [ ] **Step 2: Run test — confirm it fails.** `bash tests/plan_hash_test.sh` → expected error: `_plan_hash` module not found.

- [ ] **Step 3: Implement helper.** Create `plugins/agent-atelier/scripts/_plan_hash.py`:

```python
"""Plan-level hashing helpers — used by state-commit and wi script.

Hash is stable against IMPLEMENT-phase status mutations (claim, heartbeat, etc.)
because lifecycle status is collapsed into status_class buckets.

Plan-affecting field set:
  id, title, description, depends_on, owned_paths, verify, complexity, status_class
"""
import hashlib
import json
import os

PLAN_FIELDS = ("id", "title", "description", "depends_on", "owned_paths", "verify", "complexity")

STATUS_CLASS = {
    "pending": "unstarted",
    "ready": "unstarted",
    "implementing": "in_progress_or_done",
    "candidate_queued": "in_progress_or_done",
    "candidate_validating": "in_progress_or_done",
    "reviewing": "in_progress_or_done",
    "done": "in_progress_or_done",
    "blocked_on_human_gate": "blocked",
}


def _canonicalize(items):
    """Reduce a list of WIs to plan-shape dicts, sorted by id."""
    canonical = []
    for wi in items:
        d = {f: wi.get(f) for f in PLAN_FIELDS}
        d["status_class"] = STATUS_CLASS.get(wi.get("status"), "unstarted")
        # Stable list ordering
        for k in ("depends_on", "owned_paths", "verify"):
            v = d.get(k)
            if isinstance(v, list):
                d[k] = sorted(v)
        canonical.append(d)
    canonical.sort(key=lambda x: x.get("id") or "")
    return canonical


def wi_plan_hash(items):
    """Compute SHA-256 of canonicalized plan-shape JSON. Returns 'sha256:<hex>'."""
    canonical = _canonicalize(items or [])
    payload = json.dumps(canonical, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    h = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    return f"sha256:{h}"


def spec_hash(path):
    """SHA-256 of a file. Returns 'sha256:<hex>' or string 'null' when missing."""
    if not os.path.exists(path):
        return "null"
    with open(path, "rb") as fh:
        h = hashlib.sha256(fh.read()).hexdigest()
    return f"sha256:{h}"
```

- [ ] **Step 4: Run test — confirm it passes.** `bash tests/plan_hash_test.sh` → all PASS.

- [ ] **Step 5: Wire test into `tests/all.sh`.** After the schema_validation.sh block in `tests/all.sh`, add:

```bash
# ── Plan hash helper tests ───────────────────────────────────────────
if [ -x "$ROOT/tests/plan_hash_test.sh" ]; then
  if "$ROOT/tests/plan_hash_test.sh" >/dev/null 2>&1; then
    pass "Plan hash helper tests pass"
  else
    fail "Plan hash helper tests failed"
  fi
fi
```

- [ ] **Step 6: Commit.** Message: `feat(scripts): add _plan_hash.py with wi_plan_hash and spec_hash helpers`.

---

### Phase B: state-commit Mechanical Gate (1 task)

#### Task B1: Add IMPLEMENT-mode mechanical gate to state-commit

**Files:**
- Modify: `plugins/agent-atelier/scripts/state-commit`
- Test: `tests/implement_gate_test.sh`

- [ ] **Step 1: Write failing test.** Create `tests/implement_gate_test.sh`:

```bash
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
```

`chmod +x tests/implement_gate_test.sh`.

- [ ] **Step 2: Run test — confirm it fails.** `bash tests/implement_gate_test.sh` → all 3 should FAIL (gate not implemented).

- [ ] **Step 3: Implement gate.** In `plugins/agent-atelier/scripts/state-commit`, add a new function above `_commit`:

```python
def _validate_implement_gate(root, writes):
    """Mechanical gate: mode: BUILD_PLAN → IMPLEMENT requires valid plan_approval.

    Returns None on pass, or a (exit_code, reason, kwargs) tuple on rejection.
    """
    # Find loop-state.json write
    ls_write = None
    for w in writes:
        if w["path"].endswith("loop-state.json"):
            ls_write = w
            break
    if ls_write is None:
        return None

    new_content = ls_write.get("content")
    if not isinstance(new_content, dict):
        return None
    new_mode = new_content.get("mode")
    if new_mode != "IMPLEMENT":
        return None

    # Read old mode to detect transition
    old_path = resolve_tx_path(root, ls_write["path"])
    old_mode = None
    if os.path.exists(old_path):
        with open(old_path, encoding="utf-8") as fh:
            old_mode = json.load(fh).get("mode")

    if old_mode == "IMPLEMENT":
        # Already in IMPLEMENT — not a transition; allow.
        return None

    # Validate plan_approval
    pa = new_content.get("plan_approval")
    if not isinstance(pa, dict):
        return (2, "implement_gate_violation",
                {"reason_detail": "plan_approval missing or null"})

    # Compute current hashes
    import sys
    plugin_scripts = os.path.dirname(os.path.realpath(__file__))
    if plugin_scripts not in sys.path:
        sys.path.insert(0, plugin_scripts)
    from _plan_hash import wi_plan_hash, spec_hash

    # Find work-items.json — either in this transaction or on disk
    wi_items = None
    for w in writes:
        if w["path"].endswith("work-items.json"):
            wic = w.get("content")
            if isinstance(wic, dict):
                wi_items = wic.get("items", [])
                break
    if wi_items is None:
        wi_path = resolve_tx_path(root, ".agent-atelier/work-items.json")
        if os.path.exists(wi_path):
            with open(wi_path, encoding="utf-8") as fh:
                wi_items = json.load(fh).get("items", [])
        else:
            wi_items = []

    expected_plan_hash = wi_plan_hash(wi_items)
    if pa.get("wi_plan_hash") != expected_plan_hash:
        return (2, "implement_gate_violation",
                {"reason_detail": "wi_plan_hash mismatch",
                 "expected": expected_plan_hash, "actual": pa.get("wi_plan_hash")})

    spec_path = os.path.join(root, "docs/product/behavior-spec.md")
    expected_spec_hash = spec_hash(spec_path)
    if pa.get("spec_hash") != expected_spec_hash:
        return (2, "implement_gate_violation",
                {"reason_detail": "spec_hash mismatch",
                 "expected": expected_spec_hash, "actual": pa.get("spec_hash")})

    return None
```

In `_commit` after Phase 1 (revision validation) and before Phase 1b (cycle detection), add:

```python
    # Phase 1.5: IMPLEMENT-mode mechanical gate
    gate_violation = _validate_implement_gate(root, writes)
    if gate_violation is not None:
        exit_code, reason, kwargs = gate_violation
        return _reject(exit_code, reason, **kwargs)
```

- [ ] **Step 4: Run test — confirm pass.** `bash tests/implement_gate_test.sh` → all PASS.

- [ ] **Step 5: Wire into all.sh.** Add a block similar to A5 step 5 calling `tests/implement_gate_test.sh`.

- [ ] **Step 6: Commit.** Message: `feat(state-commit): mechanical gate rejecting mode→IMPLEMENT without valid plan_approval`.

---

### Phase C: Scripts Conversion (7 tasks — port skills to scripts)

Each task converts one existing skill into a script. The script preserves the subcommand contract from the source SKILL.md while adding `native_task_sync` hint output where applicable.

**Common pattern for each script task:**
1. Read source `skills/<name>/SKILL.md` for the subcommand contract
2. Write the script (Python preferred for state mutations)
3. Add a contract test to `tests/script_contracts.sh`
4. Make executable
5. Commit

**Skip TDD for ports** — the source SKILL.md is the spec. Tests verify the new script honors the existing contract.

#### Task C1: `scripts/init-helpers.sh`

**Files:**
- Create: `plugins/agent-atelier/scripts/init-helpers.sh`
- Test: `tests/init_helpers_test.sh`

- [ ] **Step 1: Read source.** `plugins/agent-atelier/skills/init/SKILL.md` defines the bootstrap contract: detect git root, create directories under `.agent-atelier/`, write default state files (only if missing), replay WAL. **New behavior:** also merge missing top-level keys into existing state files (do NOT overwrite values).

- [ ] **Step 2: Implement script.** Create `plugins/agent-atelier/scripts/init-helpers.sh`:

```bash
#!/usr/bin/env bash
# init-helpers.sh — Bootstrap and migrate orchestration state files.
#
# Usage:
#   init-helpers.sh [--root <path>] [--migrate-only]
#
# Output: JSON to stdout: {"changed": bool, "created": [...], "migrated_keys": {...}, "wal_recovered": bool}
# Exit codes: 0 success, 3 no git root, 4 IO failure.

set -euo pipefail

ROOT=""
MIGRATE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    --migrate-only) MIGRATE_ONLY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo '{"error":"no_git_root"}' >&2; exit 3; }
fi

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$ROOT/.agent-atelier"

mkdir -p "$STATE_DIR/human-gates/open" "$STATE_DIR/human-gates/resolved" "$STATE_DIR/human-gates/templates" "$STATE_DIR/attempts" "$STATE_DIR/plan-conversations"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Extract default JSON blocks from state-defaults.md and merge missing top-level keys
python3 - "$PLUGIN_ROOT" "$STATE_DIR" "$NOW" <<'PYEOF'
import sys, os, re, json

plugin_root, state_dir, now = sys.argv[1], sys.argv[2], sys.argv[3]
defaults_path = os.path.join(plugin_root, "references", "state-defaults.md")

# Parse JSON blocks under "## <filename>" headers
with open(defaults_path) as fh:
    text = fh.read()

blocks = {}
for m in re.finditer(r'^## ([\w.-]+\.json)\s*\n+```json\n(.*?)\n```', text, re.MULTILINE | re.DOTALL):
    name, body = m.group(1), m.group(2).replace('"<now>"', f'"{now}"')
    blocks[name] = json.loads(body)

results = {"changed": False, "created": [], "migrated_keys": {}}

for name, default_obj in blocks.items():
    if name == "human-decision-request.json":
        target = os.path.join(state_dir, "human-gates", "templates", name)
    elif name == "_index.md":
        continue  # markdown, handled below
    else:
        target = os.path.join(state_dir, name)

    if not os.path.exists(target):
        with open(target, "w") as fh:
            json.dump(default_obj, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        results["created"].append(os.path.relpath(target, state_dir))
        results["changed"] = True
    else:
        # Merge missing top-level keys (NEVER overwrite values, NEVER touch nested)
        with open(target) as fh:
            existing = json.load(fh)
        added = []
        for k, v in default_obj.items():
            if k not in existing:
                existing[k] = v
                added.append(k)
        if added:
            with open(target, "w") as fh:
                json.dump(existing, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            results["migrated_keys"][os.path.relpath(target, state_dir)] = added
            results["changed"] = True

# Bootstrap _index.md (markdown) only when missing
index_path = os.path.join(state_dir, "human-gates", "_index.md")
if not os.path.exists(index_path):
    m = re.search(r'^## human-gates/_index\.md\s*\n+```markdown\n(.*?)\n```', text, re.MULTILINE | re.DOTALL)
    if m:
        with open(index_path, "w") as fh:
            fh.write(m.group(1) + "\n")
        results["created"].append("human-gates/_index.md")
        results["changed"] = True

print(json.dumps(results, ensure_ascii=False))
PYEOF

# WAL replay
WAL="$STATE_DIR/.pending-tx.json"
WAL_RECOVERED=false
if [ -f "$WAL" ]; then
  "$PLUGIN_ROOT/scripts/state-commit" --root "$ROOT" --replay >/dev/null 2>&1 && WAL_RECOVERED=true || true
fi

# Final summary (init-helpers prints its own JSON; orchestration consumers parse)
# (The python block above already wrote results to stdout.)
```

`chmod +x plugins/agent-atelier/scripts/init-helpers.sh`.

- [ ] **Step 3: Write contract test.** Create `tests/init_helpers_test.sh`:

```bash
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

# Test 2: idempotent re-run preserves existing values
"$ROOT/plugins/agent-atelier/scripts/init-helpers.sh" --root "$TMP1" >/dev/null 2>&1
echo '{"revision":1,"updated_at":"2026-01-01T00:00:00Z","items":[{"id":"WI-CUSTOM"}]}' > "$TMP1/.agent-atelier/work-items.json"  # all top-level keys present, custom marker
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
```

`chmod +x tests/init_helpers_test.sh`.

- [ ] **Step 4: Run test — passes.** `bash tests/init_helpers_test.sh`.

- [ ] **Step 5: Wire into all.sh.** Add invocation block.

- [ ] **Step 6: Commit.** Message: `feat(scripts): init-helpers.sh with idempotent bootstrap and top-level migration`.

#### Task C2-C7: Port `wi`, `lifecycle`, `gate`, `watchdog`, `candidate`, `validate` to scripts

Each task follows the same pattern. **Generic step list (apply to each):**

- [ ] **Step 1: Read source SKILL.md** for full subcommand contract — invocation, stdin, stdout JSON shape, exit codes, idempotency, error cases.

- [ ] **Step 2: Implement Python script.** All scripts:
  - Argument parser using `argparse`
  - State reads via `json.load`
  - State writes via `state-commit` subprocess (preserve single-writer model)
  - For mutating commands on `work-items.json`, `candidate_queue`, etc., **emit `native_task_sync` hint in stdout JSON**:
    ```python
    print(json.dumps({
        "accepted": True,
        "committed_revision": new_rev,
        "artifacts": [...],
        "native_task_sync": {"action": "update", "subject_prefix": f"WI-{wi_id}:", "new_status": "...", "metadata": {...}}
    }))
    ```
  - Exit codes: 0 success, 1 invalid input, 2 stale revision, 4 IO/runtime.

- [ ] **Step 3: Add contract test row to `tests/script_contracts.sh`** (file created in Phase C8).

- [ ] **Step 4: `chmod +x` and commit.**

**Per-script subcommand reminder (port from existing SKILL.md):**

| Task | Script | Subcommands | Native task sync |
|------|--------|-------------|------------------|
| C2 | `scripts/wi` | `list`, `show <id>`, `upsert <json>` | `upsert` emits hint (TaskCreate or TaskUpdate based on whether WI is new) |
| C3 | `scripts/lifecycle` | `claim <id> --owner <session>`, `heartbeat <id>`, `requeue <id> --reason <text>`, `complete <id>`, `attempt <json>` | `claim`/`requeue`/`complete` emit hint (status mapping per AGENTS.md WI status table) |
| C4 | `scripts/gate` | `list`, `open <json>`, `resolve <HDR-ID> <chosen>` | none (gates are not native tasks) |
| C5 | `scripts/watchdog` | `tick` | scoped to its mechanical recovery; **does not** sync native tasks (orchestrator does that after reading `actions[]` output) |
| C6 | `scripts/candidate` | `enqueue <wi-ids> --branch <name> --commit <sha>`, `activate`, `clear --reason <completed\|demoted>` | `enqueue`/`activate`/`clear` emit hint (status flips for WIs in the set) |
| C7 | `scripts/validate` | `record` (JSON manifest via stdin) | emits hint (status: `candidate_validating → reviewing` on success) |

For each, copy the existing SKILL.md's subcommand procedure logic into the Python script. Preserve all error messages and exit codes verbatim.

**Each task: 6 steps (read source, implement, test row, chmod, run test, commit).**

#### Task C8: Aggregate `tests/script_contracts.sh`

**Files:**
- Create: `tests/script_contracts.sh`

- [ ] **Step 1: Create the harness.** Skeleton:

```bash
#!/usr/bin/env bash
# Script contracts — verify each scripts/* honors the contract from spec section "스크립트 계약".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# For each script, do a smoke check: it exists, it's executable, --help works, basic command returns valid JSON.
for s in init-helpers.sh wi lifecycle gate watchdog candidate validate; do
  SP="$ROOT/plugins/agent-atelier/scripts/$s"
  if [ -x "$SP" ]; then
    pass "$s exists and is executable"
  else
    fail "$s missing or not executable"
  fi
done

# Per-script smoke tests (set up tmp repo, run command, parse stdout JSON).
# (Each test block writes minimal state, invokes the script, asserts JSON shape and key presence.)

# ... (one block per script — concrete example for `wi list`):
TMP=$(mktemp -d); cd "$TMP"; git init -q
"$ROOT/plugins/agent-atelier/scripts/init-helpers.sh" --root "$TMP" >/dev/null
WI_OUT=$("$ROOT/plugins/agent-atelier/scripts/wi" list)
echo "$WI_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'items' in d" 2>/dev/null && \
  pass "wi list returns JSON with items field" || fail "wi list output invalid"
rm -rf "$TMP"

# ... (similar blocks for lifecycle smoke, gate list, watchdog tick, candidate list etc.)

echo ""
echo "Script contracts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

`chmod +x tests/script_contracts.sh`. Add invocation in `tests/all.sh`.

- [ ] **Step 2: Add per-script smoke blocks** for each of the 7 scripts (one block each — minimal happy-path JSON shape assertion).

- [ ] **Step 3: Run.** `bash tests/script_contracts.sh` → all PASS.

- [ ] **Step 4: Commit.** Message: `test(scripts): script_contracts.sh harness validating 7 mechanical scripts`.

---

### Phase D: References (3 tasks)

#### Task D1: Create `references/monitor-runtime.md`

**Files:**
- Create: `plugins/agent-atelier/references/monitor-runtime.md`

- [ ] **Step 1: Concatenate source content.** Copy the full body of `plugins/agent-atelier/skills/monitors/SKILL.md` (sections: Subcommands, Output formats, Idempotency, Error handling) AND `plugins/agent-atelier/skills/monitors/reference/event-classification.md` into a single new file. Header:

```markdown
# Monitor Runtime — LLM-Driven Procedure

This reference documents the procedures invoked by `skills/monitors/SKILL.md` (a thin shim) and by cron jobs created during `/agent-atelier:execute`.

Tools used: `Bash run_in_background`, `TaskOutput`, `TaskStop`. Read this entire file before executing any subcommand.

## Subcommands

(... copied from skills/monitors/SKILL.md ...)
```

- [ ] **Step 2: Update internal cross-references.** Any `<plugin-root>/references/...` path in the copied content should be left as-is — callers resolve at invocation time via `${CLAUDE_PLUGIN_ROOT}` or absolute paths.

- [ ] **Step 3: Commit.** Message: `feat(references): monitor-runtime.md (extracted from skills/monitors)`.

#### Task D2: Update `references/paths.md`

**Files:**
- Modify: `plugins/agent-atelier/references/paths.md`

- [ ] **Step 1: Add scripts table.** After the existing Monitor Scripts section, add a new section:

```markdown
## Mechanical Scripts (scripts/)

| Path | Purpose |
|------|---------|
| `plugins/agent-atelier/scripts/state-commit` | Atomic multi-file writer for `.agent-atelier/**` (sole writer) |
| `plugins/agent-atelier/scripts/init-helpers.sh` | Bootstrap and migrate state files |
| `plugins/agent-atelier/scripts/wi` | Work item planning (list/show/upsert) |
| `plugins/agent-atelier/scripts/lifecycle` | WI execution lifecycle (claim/heartbeat/requeue/complete/attempt) |
| `plugins/agent-atelier/scripts/gate` | Human gate lifecycle (list/open/resolve) |
| `plugins/agent-atelier/scripts/watchdog` | Mechanical recovery tick |
| `plugins/agent-atelier/scripts/candidate` | Candidate set lifecycle (enqueue/activate/clear) |
| `plugins/agent-atelier/scripts/validate` | Validation evidence recording |
| `plugins/agent-atelier/scripts/_plan_hash.py` | Plan-level hash helpers (used by state-commit and wi) |

All scripts emit JSON to stdout. Mutating scripts include a `native_task_sync` hint that callers (Orchestrator/SM) must execute as `TaskCreate`/`TaskUpdate` after success. See spec section "Native Task Sync 패턴".
```

- [ ] **Step 2: Add plan-conversations directory entry** to State Files section:

```markdown
| `.agent-atelier/plan-conversations/<cycle-id>.jsonl` | Per-cycle ping-pong conversation log (Orchestrator-only writer) |
```

- [ ] **Step 3: Commit.** Message: `docs(paths): scripts/* and plan-conversations directory entries`.

#### Task D3: Update `references/recovery-protocol.md`

**Files:**
- Modify: `plugins/agent-atelier/references/recovery-protocol.md`

- [ ] **Step 1: Add Step 2.5 — Plan Cycle Cold Resume.** After "Step 2: WAL Recovery", insert:

```markdown
### Step 2.5: Plan Cycle Cold Resume

If `loop-state.active_plan_cycle_id` is non-null, the previous session was mid-ping-pong. Read `plan-conversations/<cycle-id>.jsonl`'s last entry to determine where to resume:

| Last entry type | Resume action |
|----------------|---------------|
| `clarifying_question` | Re-present the questions to the user via AskUserQuestion |
| `user_response` | Forward to the role that emitted the corresponding question; continue phase |
| `phase_transition` | Continue with new phase's first round |
| `no_more_questions` | Check whether all required roles have signaled; advance phase if so |
| `gate_presented` | Re-present the final gate to the user |
| `gate_resolved` (with `y`) but `plan_approval` is null | This indicates a crash mid-transaction; replay via WAL is canonical, then re-check `loop-state.plan_approval` |

Cycle id is the authoritative anchor — never infer from "newest jsonl file".
```

- [ ] **Step 2: Update slash command references.** Search for `/agent-atelier:` in the file and replace per the spec migration table:
  - `/agent-atelier:init` → `bash <plugin-root>/scripts/init-helpers.sh`
  - `/agent-atelier:run` → `/agent-atelier:execute`
  - `/agent-atelier:watchdog tick` → `bash <plugin-root>/scripts/watchdog tick`
  - `/agent-atelier:monitors *` → unchanged (shim retained)

- [ ] **Step 3: Add new mandatory test scenario** to "Mandatory Test Scenarios":

```markdown
9. **Plan cycle cold resume** — Session crashes during ping-pong. Next `/plan` or `/execute` reads `active_plan_cycle_id` and resumes from last jsonl entry without losing user decisions.
10. **state-commit IMPLEMENT-mode mechanical gate** — Direct attempt to write `mode: IMPLEMENT` without valid `plan_approval` is rejected with `implement_gate_violation`.
```

- [ ] **Step 4: Commit.** Message: `docs(recovery-protocol): plan cycle cold resume + script-call updates`.

---

### Phase E: Role Prompts (4 tasks)

#### Task E1: Update `references/prompts/orchestrator.md`

**Files:**
- Modify: `plugins/agent-atelier/references/prompts/orchestrator.md`

- [ ] **Step 1: Add new section "PLAN CYCLE PROTOCOL"** before "BUILDER WORK ASSIGNMENT". Body covers:
  - Hosting the ping-pong loop (PM/Architect → Orchestrator → user via AskUserQuestion → user response → role)
  - Question batching (max 3 per AskUserQuestion call)
  - Real-time question budget enforcement (warn at 25, halt at 30)
  - JSONL append responsibility (Orchestrator is sole writer of `plan-conversations/<cycle-id>.jsonl`)
  - Gate presentation logic (final review + 0-WI shortcut to DONE)
  - Atomic gate-pass transaction format (per spec section "Atomicity 요구")
  - Modify-feedback routing (return mode to specific phase)

Reference spec sections "계획 단계의 핑퐁 루프" and "최종 승인 게이트" for exact text. Embed examples of state-commit transaction JSON for both `/execute` gate-pass and `/plan` gate-pass.

- [ ] **Step 2: Add "MUTATING SCRIPT CALLS" section** (right after PLAN CYCLE PROTOCOL):

```markdown
## MUTATING SCRIPT CALLS

When you invoke `bash <plugin-root>/scripts/{wi,lifecycle,candidate,validate} ...`, the script returns JSON with a `native_task_sync` hint. After confirming `accepted: true`, you MUST execute the hint as a `TaskCreate` or `TaskUpdate` call before returning to your loop:

- `action: "create"` → `TaskCreate({subject: subject_prefix + " " + title, description: ..., metadata: ...})`
- `action: "update"` → find the task with subject prefix matching `subject_prefix`, then `TaskUpdate({taskId, status: new_status, metadata: ...})`

Skipping this step desyncs native tasks from `work-items.json`. Treat the script call + sync as one logical operation.
```

- [ ] **Step 3: Replace slash references.** Find/replace per spec migration table:
  - `/agent-atelier:execute claim X` → `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lifecycle claim X --owner <session>`
  - `/agent-atelier:execute requeue X` → `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lifecycle requeue X --reason ...`
  - `/agent-atelier:execute complete X` → `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lifecycle complete X`
  - `/agent-atelier:watchdog tick` → `bash ${CLAUDE_PLUGIN_ROOT}/scripts/watchdog tick`
  - `/agent-atelier:candidate enqueue X,Y` → `bash ${CLAUDE_PLUGIN_ROOT}/scripts/candidate enqueue X Y --branch <name> --commit <sha>`
  - `/agent-atelier:candidate activate` → `bash ${CLAUDE_PLUGIN_ROOT}/scripts/candidate activate`
  - `/agent-atelier:candidate clear --reason demoted` → `bash ${CLAUDE_PLUGIN_ROOT}/scripts/candidate clear --reason demoted`
  - `/agent-atelier:monitors *` → unchanged
  - `/agent-atelier:run` → `/agent-atelier:execute`

- [ ] **Step 4: Commit.** Message: `docs(orchestrator-prompt): plan cycle protocol + script-call migration`.

#### Task E2: Update `agents/pm.md`

**Files:**
- Modify: `plugins/agent-atelier/agents/pm.md`

- [ ] **Step 1: Add OPERATING RULE** to the OPERATING RULES list (existing): "**Surface uncertainty as ClarifyingQuestion.** When a spec gap or ambiguous requirement appears in DISCOVER/SPEC_DRAFT/SPEC_HARDEN, send a structured `ClarifyingQuestion` payload (per `schema/clarifying-question.schema.json`) to Orchestrator via SendMessage. Never proceed with silent assumptions during plan cycles. Mark `blocking: true` when the answer changes spec content; `blocking: false` when only operational defaults are in question."

- [ ] **Step 2: Add no_more_questions signal rule** to the same section: "At the end of each round in a plan phase, if you have no further uncertainties, send `{type: 'no_more_questions', from_role: 'PM', phase: <current>, round: <N>}` to Orchestrator."

- [ ] **Step 3: Commit.** Message: `docs(pm-prompt): require ClarifyingQuestion during plan phases`.

#### Task E3: Update `agents/architect.md`

**Files:**
- Modify: `plugins/agent-atelier/agents/architect.md`

- [ ] **Step 1: Add OPERATING RULE** mirroring PM: "**Surface decomposition uncertainty as ClarifyingQuestion.** During BUILD_PLAN, when WI granularity, dependencies, or complexity has multiple valid options, send a `ClarifyingQuestion` to Orchestrator instead of choosing silently. Examples: 'split this into 2 WIs or keep as 1?', 'mock external API or wait for real?', 'borderline complexity M vs L'."

- [ ] **Step 2: Replace slash references.** All `/agent-atelier:wi upsert ...` → `bash ${CLAUDE_PLUGIN_ROOT}/scripts/wi upsert <json>`. Add note: "After successful upsert, follow Orchestrator's MUTATING SCRIPT CALLS protocol — script returns `native_task_sync` hint that needs to become a `TaskCreate`/`TaskUpdate` call by the Orchestrator." (Architect doesn't call native task tools directly.)

- [ ] **Step 3: Add no_more_questions rule** (same as PM E2 step 2 but for Architect/BUILD_PLAN).

- [ ] **Step 4: Commit.** Message: `docs(architect-prompt): ClarifyingQuestion during BUILD_PLAN + script-call migration`.

#### Task E4: Update `agents/builder.md` and `references/prompts/output-discipline.md`

**Files:**
- Modify: `plugins/agent-atelier/agents/builder.md`
- Modify: `plugins/agent-atelier/references/prompts/output-discipline.md`

- [ ] **Step 1: Builder slash → script.** In `agents/builder.md`, replace `/agent-atelier:execute claim` mentions with `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lifecycle claim` (note: builder does NOT call this directly — it remains an Orchestrator-only path; just update the textual reference).

- [ ] **Step 2: output-discipline.md.** Replace `/agent-atelier:monitors check` reference (no change — monitors retained as shim, so the slash still works). If any other slash references appear, migrate per spec table.

- [ ] **Step 3: Commit.** Message: `docs(role-prompts): finish slash → script migration in builder + output-discipline`.

---

### Phase F: User Skills (4 tasks)

#### Task F1: Create `skills/plan/SKILL.md`

**Files:**
- Create: `plugins/agent-atelier/skills/plan/SKILL.md`

- [ ] **Step 1: Write frontmatter and outline:**

```markdown
---
name: plan
description: "Run a planning cycle (DISCOVER → SPEC_DRAFT → SPEC_HARDEN → BUILD_PLAN) with ping-pong clarifying questions and a final approval gate. Use when starting a new feature, when spec or work items need rework, or when the user wants explicit plan review before execution. Triggers on 'plan', 'planning', 'review the plan', 'rework spec', 'redesign work items'."
argument-hint: "(no args)"
---

# Plan — Planning Cycle Entry Point
```

- [ ] **Step 2: Body sections** (write each as concrete steps):
  1. **When This Skill Runs** — copy from spec section "사용자 멘탈 모델"
  2. **Prerequisites** — git repo
  3. **Allowed Tools** — Read, Bash, AskUserQuestion, Agent, SendMessage
  4. **Phase 1: Bootstrap** — call `bash <plugin-root>/scripts/init-helpers.sh --root <repo>` (auto-init if missing)
  5. **Phase 2: Resume or Start Cycle** — read `loop-state.active_plan_cycle_id`. If non-null, resume from `plan-conversations/<id>.jsonl` per recovery-protocol Step 2.5. If null, generate new id `cycle-<UTC>`, write to `loop-state` via state-commit (single transaction with `plan_gate.opened_at`).
  6. **Phase 3: Spawn Core Team** — PM, Architect, State Manager (per spec; no Builders/VRM/reviewers in plan cycle)
  7. **Phase 4: Ping-Pong Loop** — drive DISCOVER → SPEC_DRAFT → SPEC_HARDEN → BUILD_PLAN per spec section "계획 단계의 핑퐁 루프". Orchestrator handles ClarifyingQuestion routing per its updated role prompt.
  8. **Phase 5: Final Gate** — present spec/WI summary via output (or AskUserQuestion). On `y`, write atomic transaction (per spec atomicity table for `/plan` context). On `더 검토`, run one more empty round. On `수정 <text>`, route to phase + restart loop.
  9. **Output Contract** — JSON: `{plan_approval: {...}, cycle_id: "...", artifacts: [...]}`
  10. **Exit Codes** — 0 success, 1 usage, 2 user declined, 4 runtime

- [ ] **Step 3: Reference spec sections explicitly** so the implementer can verify completeness against canonical text.

- [ ] **Step 4: Commit.** Message: `feat(skills/plan): planning cycle entry point with ping-pong loop`.

#### Task F2: Create `skills/execute/SKILL.md` (rename + augment from `skills/run/SKILL.md`)

**Files:**
- Create: `plugins/agent-atelier/skills/execute/SKILL.md` (note: directory clash with old execute skill — old execute skill is removed in Phase H)
- Move: `plugins/agent-atelier/skills/run/reference/{state-machine.md,team-lifecycle.md}` → `plugins/agent-atelier/skills/execute/reference/`

- [ ] **Step 1: Copy `skills/run/SKILL.md` content** as starting point.

- [ ] **Step 2: Add "Phase 0: Plan Gate Check"** at the top of the procedure:

```markdown
## Phase 0: Plan Gate Check

1. Bootstrap: `bash <plugin-root>/scripts/init-helpers.sh --root <repo>` (auto-init if missing)
2. Read `loop-state.json`. Compute current `wi_plan_hash` (using scripts/_plan_hash.py) and current `spec_hash` of `docs/product/behavior-spec.md`.
3. Compare to stored `loop-state.plan_approval`:
   - If `plan_approval` is `null` OR hashes differ → invoke planning. Either dispatch the same flow as `/agent-atelier:plan` inline, or chain by setting `loop-state.active_plan_cycle_id` and entering Phase 4 of the plan skill body.
   - If hashes match → skip to Phase 1 (Pre-Flight) of original execute body.
4. After plan gate passes, the atomic transaction sets `mode: IMPLEMENT` and clears `active_plan_cycle_id` and `plan_gate`. From here, original run-skill behavior takes over.
```

- [ ] **Step 3: Replace slash references** in the entire body per spec migration table:
  - `/agent-atelier:init` → script call
  - `/agent-atelier:run` → `/agent-atelier:execute` (self-reference)
  - All `wi/gate/watchdog/candidate/validate/lifecycle` calls → `bash <plugin-root>/scripts/<name> ...`
  - `/agent-atelier:monitors *` → unchanged (shim)

- [ ] **Step 4: Update cron prompt creation.** When the skill creates cron jobs via `CronCreate`, it must substitute `<plugin-root>` with an absolute path resolved at creation time:

```python
plugin_root = os.path.realpath(os.path.join(repo_root, "plugins/agent-atelier"))
cron_prompt = f"Read {plugin_root}/references/monitor-runtime.md and execute a check tick with task IDs {{...}}."
```

(In Markdown skill body, document this requirement clearly.)

- [ ] **Step 5: Update frontmatter:**
```yaml
---
name: execute
description: "Run the development loop end-to-end. Auto-runs plan cycle if no valid plan_approval exists; otherwise drives IMPLEMENT → VALIDATE → REVIEW_SYNTHESIS → AUTOFIX → DONE. Use when starting or resuming work after planning. Triggers on 'execute', 'run', 'go', 'start', 'continue', 'pick up where we left off'."
argument-hint: "(no args)"
---
```

- [ ] **Step 6: Move reference files.** `git mv plugins/agent-atelier/skills/run/reference/state-machine.md plugins/agent-atelier/skills/execute/reference/state-machine.md` (and team-lifecycle.md). Update internal cross-references inside those files.

- [ ] **Step 7: Commit.** Message: `feat(skills/execute): user-facing execute with plan gate check (renamed from run)`.

#### Task F3: Create `skills/monitors/SKILL.md` thin shim

**Files:**
- Modify: `plugins/agent-atelier/skills/monitors/SKILL.md`
- Delete: `plugins/agent-atelier/skills/monitors/reference/event-classification.md` (already copied to monitor-runtime.md in D1)

- [ ] **Step 1: Replace SKILL.md body** with shim version:

```markdown
---
name: monitors
description: "[INTERNAL — invoked by orchestrator/cron, not for direct user use] Background monitor lifecycle — spawn continuous monitors, poll for events, stop monitors, or check health. Triggers on 'spawn monitors', 'check monitors', 'stop monitors', 'monitor status', 'spawn ci monitor', 'poll events', 'respawn'."
argument-hint: "spawn | check <task-ids-json> | stop [all | <name>] | status | spawn-ci --run-id <ID> | --pr <NUM>"
---

# Monitors — Internal Skill Shim

This skill is invoked **only** by the orchestrator or cron jobs. Users should not invoke it directly. Full procedure is documented in `${CLAUDE_PLUGIN_ROOT}/references/monitor-runtime.md` — read that file before executing any subcommand.

## Behavior

Read `references/monitor-runtime.md` and execute the requested subcommand per its procedure. The subcommand argument is in `$ARGS` (e.g., `spawn`, `check '{...}'`, `stop all`).

## Output

JSON per subcommand as documented in `references/monitor-runtime.md`. No deviation.

## Idempotency

Each subcommand's idempotency is documented in the reference.
```

- [ ] **Step 2: Delete the now-empty reference file.** `git rm plugins/agent-atelier/skills/monitors/reference/event-classification.md` and `rmdir` the parent if empty.

- [ ] **Step 3: Commit.** Message: `refactor(skills/monitors): reduce to thin shim, body moved to references/monitor-runtime.md`.

#### Task F4: Update `skills/status/SKILL.md`

**Files:**
- Modify: `plugins/agent-atelier/skills/status/SKILL.md`

- [ ] **Step 1: Update frontmatter** to mention plan_approval / active_plan_cycle_id surfacing in the dashboard.

- [ ] **Step 2: In the dashboard rendering procedure**, add a "Plan State" section that reports:
  - Current `mode`
  - `active_plan_cycle_id` (if non-null, with elapsed time since `plan_gate.opened_at`)
  - `plan_approval` summary (if present, age + hash match status)
  - Most recent ping-pong activity (if `active_plan_cycle_id` present, last 3 jsonl entries)

- [ ] **Step 3: Replace `/agent-atelier:init` references** with `bash ${CLAUDE_PLUGIN_ROOT}/scripts/init-helpers.sh`.

- [ ] **Step 4: Commit.** Message: `feat(skills/status): surface plan state in dashboard`.

---

### Phase G: Hooks (2 tasks)

#### Task G1: Update `hooks/on-stop.sh` and `hooks/on-task-completed.sh`

**Files:**
- Modify: `plugins/agent-atelier/hooks/on-stop.sh`
- Modify: `plugins/agent-atelier/hooks/on-task-completed.sh`

- [ ] **Step 1: Replace slash mentions** per spec table. Common pattern:
  - In `on-stop.sh`: replace `/agent-atelier:execute requeue` and `/agent-atelier:watchdog tick` and `/agent-atelier:init` with the corresponding `bash ${CLAUDE_PLUGIN_ROOT}/scripts/...` calls.
  - In `on-task-completed.sh`: replace `/agent-atelier:execute complete` similarly.

- [ ] **Step 2: Verify hooks still execute.** Run `bash plugins/agent-atelier/hooks/on-stop.sh` (in a tmp repo with state files) — should not error.

- [ ] **Step 3: Commit.** Message: `chore(hooks): migrate slash command references to scripts/*`.

#### Task G2: PreToolUse hook audit

**Files:**
- Modify: `plugins/agent-atelier/hooks/on-pre-tool-use.sh` (likely existing — verify path)

- [ ] **Step 1: Find the hook.** Search: `ls plugins/agent-atelier/hooks/` and identify the PreToolUse handler.

- [ ] **Step 2: Audit destructive bash patterns.** Open the hook and check what regex patterns it blocks. Particularly:
  - `requeue`, `clear`, `delete`, `remove` verbs
  - Could these match `bash <plugin-root>/scripts/lifecycle requeue` or `scripts/candidate clear`?

- [ ] **Step 3: Add allowlist if needed.** If patterns conflict, add an early-exit when the command starts with `bash` and contains `/scripts/` (i.e., scripts under the plugin root):

```bash
# Allow plugin scripts past the destructive-pattern filter
if [[ "$BASH_COMMAND" =~ /scripts/(state-commit|init-helpers|wi|lifecycle|gate|watchdog|candidate|validate) ]]; then
  exit 0
fi
```

- [ ] **Step 4: Test the hook.** Manually invoke a script call and verify no false rejections.

- [ ] **Step 5: Commit.** Message: `chore(hooks): allowlist plugin scripts past destructive-pattern filter`.

---

### Phase H: Removals (1 task)

#### Task H1: Remove old skill directories

**Files (delete entirely):**
- Delete: `plugins/agent-atelier/skills/init/`
- Delete: `plugins/agent-atelier/skills/run/`
- Delete: `plugins/agent-atelier/skills/wi/`
- Delete: `plugins/agent-atelier/skills/gate/`
- Delete: `plugins/agent-atelier/skills/watchdog/`
- Delete: `plugins/agent-atelier/skills/candidate/`
- Delete: `plugins/agent-atelier/skills/validate/`

**Files (cleanup of stale subdirs, NOT the SKILL.md):**
- `plugins/agent-atelier/skills/execute/reference/subcommands.md` (and similar) — the OLD lifecycle reference files. The SKILL.md itself was replaced by F2; only stale auxiliary files (subcommands.md, transactions.md, etc., if any) need removal.

**Important — `skills/execute/` directory is NOT deleted.** F2 overwrote `skills/execute/SKILL.md` in place with the new user-facing content and moved `skills/run/reference/{state-machine.md,team-lifecycle.md}` into `skills/execute/reference/`. Any leftover lifecycle-era files (e.g., `skills/execute/reference/subcommands.md`) are stale and must be removed here.

- [ ] **Step 1: Identify stale files in `skills/execute/reference/`.** Run `ls plugins/agent-atelier/skills/execute/reference/` and any file NOT matching `state-machine.md` or `team-lifecycle.md` is stale.

- [ ] **Step 2: `git rm` stale files.** `git rm plugins/agent-atelier/skills/execute/reference/<stale-file>` for each.

- [ ] **Step 3: `git rm -r` the 7 obsolete skill directories** listed above. Verify `skills/execute/`, `skills/plan/`, `skills/status/`, `skills/monitors/` remain.

- [ ] **Step 4: Run** `bash tests/all.sh` — expect failures from EXPECTED_SKILLS hardcoded list (Phase I1 fixes this). Other tests should still pass.

- [ ] **Step 5: Commit.** Message: `refactor(skills): remove 7 obsolete skill directories; lifecycle now in scripts/`.

---

### Phase I: Tests + Migration (5 tasks)

#### Task I1: Update `tests/all.sh` expected lists

**Files:**
- Modify: `tests/all.sh`

- [ ] **Step 1: Update `EXPECTED_SKILLS`:**

```bash
EXPECTED_SKILLS="plan execute status monitors"
```

- [ ] **Step 2: Add `EXPECTED_SCRIPTS` block** (after EXPECTED_SKILLS):

```bash
EXPECTED_SCRIPTS="state-commit init-helpers.sh wi gate watchdog candidate validate lifecycle"
SCRIPTS_DIR="$ROOT/plugins/agent-atelier/scripts"
SCRIPT_COUNT=0
for script_name in $EXPECTED_SCRIPTS; do
  script_path="$SCRIPTS_DIR/$script_name"
  if [ -f "$script_path" ] && [ -x "$script_path" ]; then
    pass "script '$script_name' exists and is executable"
    SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
  else
    fail "script '$script_name' not found or not executable at $script_path"
  fi
done
```

- [ ] **Step 3: Update `EXPECTED_REFS`** to include `monitor-runtime.md`:

```bash
EXPECTED_REFS="paths.md state-defaults.md wi-schema.md recovery-protocol.md success-metrics-routing.md monitor-runtime.md"
```

- [ ] **Step 4: Run** `bash tests/all.sh` → all pass.

- [ ] **Step 5: Commit.** Message: `test(all): expected skills/scripts/refs lists for new structure`.

#### Task I2: Migrate slash references in test scenarios

**Files:**
- Modify: `tests/orchestration_contracts.sh`
- Modify: `tests/recovery_contracts.sh`

- [ ] **Step 1: Find all slash references.** `grep -n "/agent-atelier:" tests/orchestration_contracts.sh tests/recovery_contracts.sh`.

- [ ] **Step 2: Replace per migration table.** For each match:
  - `/agent-atelier:wi *` → `bash <plugin-root>/scripts/wi *`
  - `/agent-atelier:execute *` (lifecycle subcommands) → `bash <plugin-root>/scripts/lifecycle *`
  - `/agent-atelier:gate *` → `bash <plugin-root>/scripts/gate *`
  - `/agent-atelier:watchdog tick` → `bash <plugin-root>/scripts/watchdog tick`
  - `/agent-atelier:candidate *` → `bash <plugin-root>/scripts/candidate *`
  - `/agent-atelier:validate *` → `bash <plugin-root>/scripts/validate *`
  - `/agent-atelier:init` → `bash <plugin-root>/scripts/init-helpers.sh`
  - `/agent-atelier:run` → `/agent-atelier:execute` (this is now a user-facing skill so slash form remains)
  - `/agent-atelier:monitors *` → unchanged

- [ ] **Step 3: Run** both test files — expect them to pass.

- [ ] **Step 4: Commit.** Message: `test(contracts): migrate slash references to scripts/*`.

#### Task I3: Add new scenario tests

**Files:**
- Create: `tests/plan_only.sh`
- Create: `tests/execute_no_plan.sh`
- Create: `tests/execute_with_valid_plan.sh`
- Create: `tests/plan_invalidated.sh`
- Create: `tests/pingpong_basic.sh`
- Create: `tests/pingpong_modify.sh`
- Create: `tests/pingpong_assume.sh`
- Create: `tests/pingpong_budget.sh`
- Create: `tests/cold_resume_pingpong.sh`

For each, follow this template:

```bash
#!/usr/bin/env bash
# Scenario: <description from spec section "테스트">
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP=$(mktemp -d); cd "$TMP"; git init -q
"$ROOT/plugins/agent-atelier/scripts/init-helpers.sh" --root "$TMP" >/dev/null

# <scenario-specific setup>
# <scenario-specific actions>
# <scenario-specific assertions>

rm -rf "$TMP"
echo ""
echo "<scenario>: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 1: Implement `plan_only.sh`** — happy path: `/plan` runs, ping-pong with mocked role responses, gate `y`, plan_approval recorded with mode unchanged.

- [ ] **Step 2: Implement `execute_no_plan.sh`** — `/execute` with no plan_approval invokes plan flow, gate `y`, transitions atomically to `mode: IMPLEMENT` + clears cycle/gate.

- [ ] **Step 3: Implement `execute_with_valid_plan.sh`** — plan_approval present + hashes match, `/execute` skips plan flow.

- [ ] **Step 4: Implement `plan_invalidated.sh`** — plan_approval present, modify `behavior-spec.md`, `/execute` recomputes spec_hash, mismatch → re-enters plan.

- [ ] **Step 5: Implement `pingpong_basic.sh`** — single ClarifyingQuestion → user response → spec updated → next phase.

- [ ] **Step 6: Implement `pingpong_modify.sh`** — gate `수정 <피드백>` → loop returns to specified phase.

- [ ] **Step 7: Implement `pingpong_assume.sh`** — `네가 결정` → recommended adopted, assumptions log entry.

- [ ] **Step 8: Implement `pingpong_budget.sh`** — issue >25 questions → all subsequent become `blocking: false`; >30 → user alerted, plan paused.

- [ ] **Step 9: Implement `cold_resume_pingpong.sh`** — set up active cycle with jsonl entries, simulate session restart, verify `/plan` resumes from last entry.

- [ ] **Step 10: `chmod +x` all 9 files** and add invocation blocks in `tests/all.sh`.

- [ ] **Step 11: Commit.** Message: `test(scenarios): plan/execute workflow + ping-pong test scenarios`.

#### Task I4: Update `docs/design/*.md`

**Files:**
- Modify: `docs/design/cli-surface.md`
- Modify: `docs/design/system-design.md`
- Modify: `docs/design/session-limit-retry.md`
- Modify: `docs/design/recovery-spec.md`

- [ ] **Step 1: For each file, find all slash and skill references.** `grep -n "/agent-atelier:\|skills/" docs/design/*.md`.

- [ ] **Step 2: Update prose** to reflect new structure:
  - Mention `plan`/`execute`/`status` as user-facing skills
  - Reference `scripts/*` as internal mechanical commands
  - Note `monitors` as internal-by-usage shim
  - Migrate slash references per spec table

- [ ] **Step 3: Commit.** Message: `docs(design): update CLI surface and system design for plan/execute structure`.

#### Task I5: Update `AGENTS.md`

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update Plugin Structure section** with new layout:

```markdown
## Plugin Structure

- `plugins/agent-atelier/skills/` — 4 skills total: `plan`, `execute`, `status` (user-facing) + `monitors` (internal shim invoked by orchestrator/cron)
- `plugins/agent-atelier/scripts/` — Mechanical commands invoked by orchestrator and roles: `state-commit`, `init-helpers.sh`, `wi`, `lifecycle`, `gate`, `watchdog`, `candidate`, `validate`, `_plan_hash.py`. All emit JSON; mutating scripts include `native_task_sync` hint.
- `plugins/agent-atelier/hooks/` — Lifecycle hooks (unchanged composition)
- `plugins/agent-atelier/schema/` — `vrm-evidence-input.schema.json`, `clarifying-question.schema.json`, `plan-conversation-entry.schema.json`
- `plugins/agent-atelier/references/` — paths, state-defaults, wi-schema, recovery-protocol, success-metrics-routing, monitor-runtime
- `plugins/agent-atelier/references/prompts/` — orchestrator (lead), output-discipline (shared), ui-designer, aesthetic-ux-reviewer
- `plugins/agent-atelier/agents/` — 7 subagent definitions (state-manager, pm, architect, builder, vrm, qa-reviewer, ux-reviewer)
```

- [ ] **Step 2: Replace any `/run` or `/init` user-flow text** with `/plan` and `/execute`.

- [ ] **Step 3: Add a "Plan/Execute Workflow" subsection** with a one-paragraph summary:

```markdown
## Plan/Execute Workflow

Two user-facing entry points: `/agent-atelier:plan` runs DISCOVER → BUILD_PLAN with mandatory ClarifyingQuestion ping-pong + final approval gate; `/agent-atelier:execute` runs the same plan cycle if no valid `plan_approval` exists, then drives IMPLEMENT → DONE. The mechanical IMPLEMENT-mode gate is enforced by `scripts/state-commit` (mode: IMPLEMENT requires matching `wi_plan_hash` and `spec_hash` in `plan_approval`). Plan cycle conversation log lives at `.agent-atelier/plan-conversations/<cycle-id>.jsonl` (Orchestrator-only writer). See `docs/superpowers/specs/2026-05-08-plan-execute-workflow-design.md` for full design.
```

- [ ] **Step 4: Commit.** Message: `docs(AGENTS.md): plan/execute workflow + new plugin structure`.

---

## Final Verification

- [ ] **Run full test suite.** `bash tests/all.sh` — every check should pass.
- [ ] **Manual smoke test** of `/agent-atelier:status` — verify it loads and reports plan state correctly.
- [ ] **Verify no orphaned references.** `grep -rn "/agent-atelier:\(init\|run\|wi\|gate\|watchdog\|candidate\|validate\)" plugins/ docs/ tests/ AGENTS.md` — should return 0 matches (only `monitors` slash should remain).

---

## Self-Review Checklist (after Phase I, before merge)

1. **Spec coverage:** Every spec section has ≥1 task implementing it.
2. **No placeholders:** All `<...>` in tasks are illustrative; concrete code shown for non-obvious parts.
3. **Type/name consistency:** `wi_plan_hash`, `spec_hash`, `active_plan_cycle_id`, `plan_gate`, `native_task_sync` used uniformly.
4. **Script contracts:** Each of 7 scripts has a contract test row in `script_contracts.sh`.
5. **Slash → script migration:** All callers grep-clean for old slash patterns (except `monitors`).
6. **Atomic transactions:** Both `/plan`-only gate-pass and `/execute` gate-pass produce single state-commit transactions per spec atomicity table.
7. **Existing install migration:** `init-helpers.sh` merges missing top-level keys without overwriting values.
