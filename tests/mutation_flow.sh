#!/usr/bin/env bash
# Tests state-commit mutation flows: atomic writes, stale revision rejection,
# cross-file consistency, WAL recovery, multi-file transactions, and path boundaries.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="$ROOT/plugins/agent-atelier/scripts/state-commit"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

assert_json() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if not eval(sys.argv[2], {"__builtins__": {}}, {"data": data}):
    raise SystemExit(1)
PY
}

echo "=== Mutation Flow Tests ==="

# ── Setup: create initial state ──────────────────────────────────────
mkdir -p "$TMPDIR/.agent-atelier"

cat > "$TMPDIR/.agent-atelier/work-items.json" <<'EOF'
{
  "revision": 1,
  "updated_at": "2026-04-08T00:00:00Z",
  "items": [
    {
      "id": "WI-001",
      "status": "ready",
      "revision": 1,
      "title": "Test item",
      "owner_session_id": null,
      "lease_expires_at": null
    }
  ]
}
EOF

cat > "$TMPDIR/.agent-atelier/loop-state.json" <<'EOF'
{
  "revision": 1,
  "updated_at": "2026-04-08T00:00:00Z",
  "mode": "IMPLEMENT",
  "open_gates": [],
  "active_candidate": null,
  "candidate_activated_at": null
}
EOF

# ── Test 1: Single-file write with correct revision ──────────────────
RESULT=$(echo '{
  "writes": [{
    "path": ".agent-atelier/work-items.json",
    "expected_revision": 1,
    "content": {
      "revision": 2,
      "updated_at": "2026-04-08T01:00:00Z",
      "items": [{"id": "WI-001", "status": "implementing", "revision": 2, "title": "Test item", "owner_session_id": "exec-01", "lease_expires_at": "2026-04-08T02:30:00Z"}]
    }
  }]
}' | "$COMMIT" --root "$TMPDIR")

if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['committed'] is True" 2>/dev/null; then
  pass "Single-file write with correct revision commits"
else
  fail "Single-file write with correct revision rejected"
fi

assert_json "$TMPDIR/.agent-atelier/work-items.json" "data['revision'] == 2 and data['items'][0]['status'] == 'implementing'"
pass "Written content matches expected state"

# ── Test 2: Stale revision is rejected ───────────────────────────────
RESULT=$(echo '{
  "writes": [{
    "path": ".agent-atelier/work-items.json",
    "expected_revision": 1,
    "content": {"revision": 3, "items": []}
  }]
}' | "$COMMIT" --root "$TMPDIR" 2>/dev/null; echo "EXIT:$?")

if echo "$RESULT" | grep -q '"committed": false'; then
  pass "Stale revision is rejected (expected 1, actual 2)"
else
  fail "Stale revision was not rejected"
fi

if echo "$RESULT" | grep -q 'EXIT:2'; then
  pass "Stale revision exits with code 2"
else
  fail "Stale revision did not exit with code 2"
fi

# Verify file was not modified
assert_json "$TMPDIR/.agent-atelier/work-items.json" "data['revision'] == 2"
pass "File unchanged after stale revision rejection"

# ── Test 3: Multi-file transaction (cross-file consistency) ──────────
RESULT=$(echo '{
  "writes": [
    {
      "path": ".agent-atelier/work-items.json",
      "expected_revision": 2,
      "content": {
        "revision": 3,
        "updated_at": "2026-04-08T02:00:00Z",
        "items": [{"id": "WI-001", "status": "candidate_validating", "revision": 3}]
      }
    },
    {
      "path": ".agent-atelier/loop-state.json",
      "expected_revision": 1,
      "content": {
        "revision": 2,
        "updated_at": "2026-04-08T02:00:00Z",
        "mode": "VALIDATE",
        "open_gates": [],
        "active_candidate": {"work_item_id": "WI-001", "branch": "candidate/WI-001"},
        "candidate_activated_at": "2026-04-08T02:00:00Z"
      }
    }
  ]
}' | "$COMMIT" --root "$TMPDIR")

if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['committed'] is True and len(d['artifacts']) == 2" 2>/dev/null; then
  pass "Multi-file transaction commits both files"
else
  fail "Multi-file transaction failed"
fi

assert_json "$TMPDIR/.agent-atelier/work-items.json" "data['revision'] == 3"
assert_json "$TMPDIR/.agent-atelier/loop-state.json" "data['revision'] == 2 and data['active_candidate']['work_item_id'] == 'WI-001'"
pass "Cross-file state is consistent after multi-file transaction"

# ── Test 4: Multi-file tx rejected if ANY revision is stale ──────────
RESULT=$(echo '{
  "writes": [
    {
      "path": ".agent-atelier/work-items.json",
      "expected_revision": 3,
      "content": {"revision": 4, "items": []}
    },
    {
      "path": ".agent-atelier/loop-state.json",
      "expected_revision": 999,
      "content": {"revision": 3}
    }
  ]
}' | "$COMMIT" --root "$TMPDIR" 2>/dev/null; echo "EXIT:$?")

if echo "$RESULT" | grep -q '"committed": false'; then
  pass "Multi-file tx rejected when second file has stale revision"
else
  fail "Multi-file tx should have been rejected"
fi

# Verify NEITHER file was modified (all-or-nothing at validation phase)
assert_json "$TMPDIR/.agent-atelier/work-items.json" "data['revision'] == 3"
assert_json "$TMPDIR/.agent-atelier/loop-state.json" "data['revision'] == 2"
pass "Neither file modified after partial stale revision (all-or-nothing)"

# ── Test 5: WAL file written and cleaned up ──────────────────────────
WAL_PATH="$TMPDIR/.agent-atelier/.pending-tx.json"

# WAL should not exist from previous successful commits
if [ ! -f "$WAL_PATH" ]; then
  pass "No WAL file after successful commits"
else
  fail "WAL file should not exist after successful commits"
fi

# ── Test 6: New file creation (expected_revision null) ───────────────
RESULT=$(echo '{
  "writes": [{
    "path": ".agent-atelier/human-gates/open/HDR-001.json",
    "expected_revision": null,
    "content": {"id": "HDR-001", "state": "open", "question": "Test gate?"}
  }]
}' | "$COMMIT" --root "$TMPDIR")

if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['committed'] is True" 2>/dev/null; then
  pass "New file creation with null expected_revision"
else
  fail "New file creation failed"
fi

test -f "$TMPDIR/.agent-atelier/human-gates/open/HDR-001.json"
pass "HDR file created on disk"

# ── Test 7: Text content (non-JSON) ─────────────────────────────────
RESULT=$(echo '{
  "writes": [{
    "path": ".agent-atelier/human-gates/_index.md",
    "expected_revision": null,
    "content": "# Human Gate Dashboard\n\nUpdated."
  }]
}' | "$COMMIT" --root "$TMPDIR")

if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['committed'] is True" 2>/dev/null; then
  pass "Text (non-JSON) content write"
else
  fail "Text content write failed"
fi

# ── Test 8: Unapplied WAL recovery ───────────────────────────────────
# WAL exists but no files were written yet (crash between phase 2 and 3)
cat > "$WAL_PATH" <<'EOF'
{
  "writes": [{
    "path": ".agent-atelier/work-items.json",
    "expected_revision": 3,
    "content": {
      "revision": 4,
      "updated_at": "2026-04-08T03:00:00Z",
      "items": [{"id": "WI-001", "status": "done", "revision": 4}]
    }
  }]
}
EOF

RESULT=$(cat "$WAL_PATH" | "$COMMIT" --root "$TMPDIR" --replay)
if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['committed'] is True" 2>/dev/null; then
  pass "Unapplied WAL replay commits"
else
  fail "Unapplied WAL replay failed"
fi

assert_json "$TMPDIR/.agent-atelier/work-items.json" "data['revision'] == 4 and data['items'][0]['status'] == 'done'"
pass "State correct after unapplied WAL recovery"

if [ ! -f "$WAL_PATH" ]; then
  pass "WAL cleaned up after unapplied replay"
else
  fail "WAL not cleaned up"
fi

# ── Test 9: PARTIALLY applied WAL recovery ───────────────────────────
# Simulate: crash after writing work-items (rev 5) but before loop-state (rev 3)
# work-items is already at rev 4 from previous test, loop-state at rev 2.

# First, write the WAL as if the transaction intended to write both files
cat > "$WAL_PATH" <<'EOF'
{
  "writes": [
    {
      "path": ".agent-atelier/work-items.json",
      "expected_revision": 4,
      "content": {
        "revision": 5,
        "updated_at": "2026-04-08T04:00:00Z",
        "items": [{"id": "WI-001", "status": "ready", "revision": 5}]
      }
    },
    {
      "path": ".agent-atelier/loop-state.json",
      "expected_revision": 2,
      "content": {
        "revision": 3,
        "updated_at": "2026-04-08T04:00:00Z",
        "mode": "IMPLEMENT",
        "open_gates": [],
        "active_candidate": null,
        "candidate_activated_at": null
      }
    }
  ]
}
EOF

# Simulate partial apply: write work-items to rev 5 directly (as if crash happened after this)
cat > "$TMPDIR/.agent-atelier/work-items.json" <<'EOF'
{
  "revision": 5,
  "updated_at": "2026-04-08T04:00:00Z",
  "items": [{"id": "WI-001", "status": "ready", "revision": 5}]
}
EOF
# loop-state remains at rev 2 (not yet written)

# Normal commit would FAIL here because work-items expected_revision=4 but actual=5.
# --replay should detect that work-items already has target rev 5, skip it,
# and only write loop-state.
RESULT=$(cat "$WAL_PATH" | "$COMMIT" --root "$TMPDIR" --replay)
if echo "$RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['committed'] is True
assert d.get('replayed') is True
assert '.agent-atelier/work-items.json' in d.get('skipped', [])
assert '.agent-atelier/loop-state.json' in d.get('artifacts', [])
" 2>/dev/null; then
  pass "Partial WAL replay: skips already-applied file, writes remaining"
else
  fail "Partial WAL replay did not behave correctly"
fi

# Both files should now be at their target revisions
assert_json "$TMPDIR/.agent-atelier/work-items.json" "data['revision'] == 5"
assert_json "$TMPDIR/.agent-atelier/loop-state.json" "data['revision'] == 3"
pass "Both files consistent after partial WAL recovery"

if [ ! -f "$WAL_PATH" ]; then
  pass "WAL cleaned up after partial replay"
else
  fail "WAL not cleaned up after partial replay"
fi

# ── Test 10: Transaction with deletes ────────────────────────────────
# Create a file to be deleted
mkdir -p "$TMPDIR/.agent-atelier/human-gates/open"
cat > "$TMPDIR/.agent-atelier/human-gates/open/HDR-002.json" <<'EOF'
{"id": "HDR-002", "state": "open"}
EOF

RESULT=$(echo '{
  "writes": [{
    "path": ".agent-atelier/human-gates/resolved/HDR-002.json",
    "expected_revision": null,
    "content": {"id": "HDR-002", "state": "resolved", "resolution": {"chosen_option": "A"}}
  }],
  "deletes": [".agent-atelier/human-gates/open/HDR-002.json"]
}' | "$COMMIT" --root "$TMPDIR")

if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['committed'] is True" 2>/dev/null; then
  pass "Transaction with write+delete commits"
else
  fail "Transaction with delete failed"
fi

# Resolved copy should exist, open copy should be gone
test -f "$TMPDIR/.agent-atelier/human-gates/resolved/HDR-002.json"
pass "Resolved HDR file created"

if [ ! -f "$TMPDIR/.agent-atelier/human-gates/open/HDR-002.json" ]; then
  pass "Open HDR file deleted in same transaction"
else
  fail "Open HDR file still exists after delete"
fi

# ── Test 11: Concurrent writers — flock serialization ────────────────
# Both try to commit with expected_revision=5, bumping to 6.
# flock serializes them: first wins, second sees stale revision.

echo '{
  "writes": [{
    "path": ".agent-atelier/work-items.json",
    "expected_revision": 5,
    "content": {"revision": 6, "updated_at": "2026-04-08T05:00:00Z", "items": [{"id": "WI-001", "status": "implementing", "revision": 6, "owner_session_id": "agent-A"}]}
  }]
}' | "$COMMIT" --root "$TMPDIR" > "$TMPDIR/race-1.json" 2>/dev/null &
PID1=$!

echo '{
  "writes": [{
    "path": ".agent-atelier/work-items.json",
    "expected_revision": 5,
    "content": {"revision": 6, "updated_at": "2026-04-08T05:00:00Z", "items": [{"id": "WI-001", "status": "implementing", "revision": 6, "owner_session_id": "agent-B"}]}
  }]
}' | "$COMMIT" --root "$TMPDIR" > "$TMPDIR/race-2.json" 2>/dev/null &
PID2=$!

# wait returns the bg process exit code; use || true to prevent set -e from aborting
E1=0; wait $PID1 || E1=$?
E2=0; wait $PID2 || E2=$?

# Exactly one should succeed (exit 0) and one fail (exit 2)
if { [ "$E1" -eq 0 ] && [ "$E2" -eq 2 ]; } || { [ "$E1" -eq 2 ] && [ "$E2" -eq 0 ]; }; then
  pass "Concurrent writers: one commits, other gets stale revision"
else
  fail "Concurrent writers: expected exits (0,2) or (2,0), got ($E1,$E2)"
fi

# The winner's content should be on disk
assert_json "$TMPDIR/.agent-atelier/work-items.json" "data['revision'] == 6"
pass "Winner's content persisted after concurrent write"

# ── Test 12: WAL replay with deletes ─────────────────────────────────
# Simulate: WAL has a delete, but the file was already deleted (partial apply)
mkdir -p "$TMPDIR/.agent-atelier/human-gates/open"
cat > "$WAL_PATH" <<'EOF'
{
  "writes": [],
  "deletes": [".agent-atelier/human-gates/open/HDR-GHOST.json"]
}
EOF

RESULT=$(cat "$WAL_PATH" | "$COMMIT" --root "$TMPDIR" --replay)
if echo "$RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['committed'] is True
assert '.agent-atelier/human-gates/open/HDR-GHOST.json' in d.get('skipped', [])
" 2>/dev/null; then
  pass "WAL replay skips already-deleted file"
else
  fail "WAL replay failed on already-deleted file"
fi

# ── Test 13: Reject traversal writes outside .agent-atelier ───────
mkdir -p "$TMPDIR/docs"
printf 'safe\n' > "$TMPDIR/docs/escape-write.txt"

RESULT=$(echo '{
  "writes": [{
    "path": ".agent-atelier/../escape-write.txt",
    "expected_revision": null,
    "content": "pwned"
  }]
}' | "$COMMIT" --root "$TMPDIR" 2>/dev/null; echo "EXIT:$?")

if echo "$RESULT" | grep -q '"reason": "invalid_path"'; then
  pass "Traversal write outside .agent-atelier is rejected"
else
  fail "Traversal write should be rejected as invalid_path"
fi

if echo "$RESULT" | grep -q 'EXIT:1'; then
  pass "Invalid path exits with code 1"
else
  fail "Invalid path did not exit with code 1"
fi

if [ "$(cat "$TMPDIR/docs/escape-write.txt")" = "safe" ]; then
  pass "Out-of-bounds traversal target unchanged"
else
  fail "Traversal target was modified"
fi

# ── Test 14: Reject absolute delete paths outside .agent-atelier ──
ABS_DELETE="$TMPDIR/absolute-delete.txt"
printf 'safe\n' > "$ABS_DELETE"

RESULT=$(python3 - <<'PY' "$ABS_DELETE" | "$COMMIT" --root "$TMPDIR" 2>/dev/null; echo "EXIT:$?"
import json, sys
print(json.dumps({
    "writes": [],
    "deletes": [sys.argv[1]],
}))
PY
)

if echo "$RESULT" | grep -q '"reason": "invalid_path"'; then
  pass "Absolute delete path outside .agent-atelier is rejected"
else
  fail "Absolute delete path should be rejected as invalid_path"
fi

if echo "$RESULT" | grep -q 'EXIT:1'; then
  pass "Invalid delete path exits with code 1"
else
  fail "Invalid delete path did not exit with code 1"
fi

if [ -f "$ABS_DELETE" ]; then
  pass "Out-of-bounds absolute delete target preserved"
else
  fail "Absolute delete path removed a file outside .agent-atelier"
fi

# ── Test 15: Event emission to events.ndjson ─────────────────────────
# After a successful commit, state-commit should append a compact NDJSON
# event to events.ndjson with the "state_committed" event type.

EVENTS_FILE="$TMPDIR/.agent-atelier/events.ndjson"

# Count existing events (may have been emitted by prior tests)
EVENTS_BEFORE=0
if [ -f "$EVENTS_FILE" ]; then
  EVENTS_BEFORE=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
fi

# Perform a successful commit (bump from rev 6 to 7)
echo '{
  "writes": [{
    "path": ".agent-atelier/work-items.json",
    "expected_revision": 6,
    "content": {"revision": 7, "updated_at": "2026-04-08T06:00:00Z", "items": [{"id": "WI-001", "status": "done", "revision": 7}]},
    "message": "event-test commit"
  }],
  "message": "verify event emission"
}' | "$COMMIT" --root "$TMPDIR" >/dev/null

if [ -f "$EVENTS_FILE" ]; then
  EVENTS_AFTER=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
  if [ "$EVENTS_AFTER" -gt "$EVENTS_BEFORE" ]; then
    pass "events.ndjson grew after commit"
  else
    fail "events.ndjson did not grow after commit (before=$EVENTS_BEFORE after=$EVENTS_AFTER)"
  fi

  # Validate the last line is compact NDJSON with expected fields
  LAST_EVENT=$(tail -1 "$EVENTS_FILE")
  if python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['event'] == 'state_committed', f\"event={d['event']}\"
assert 'timestamp' in d, 'missing timestamp'
assert d['revision'] == 7, f\"revision={d['revision']}\"
assert 'work-items.json' in d['mutations'], f\"mutations={d['mutations']}\"
# Compact NDJSON: no spaces after colons or commas
assert ': ' not in sys.argv[1].split('\"timestamp\"')[0], 'not compact JSON'
" "$LAST_EVENT" 2>/dev/null; then
    pass "Event line is compact NDJSON with correct fields (event, timestamp, revision, mutations)"
  else
    fail "Event line format or content is incorrect: $LAST_EVENT"
  fi

  # Verify the event can be matched by event-tail's grep -F pattern
  if echo "$LAST_EVENT" | grep -qF '"event":"state_committed"'; then
    pass "Event line matches event-tail grep -F filter pattern"
  else
    fail "Event line does NOT match grep -F '\"event\":\"state_committed\"' — event-tail will miss it"
  fi
else
  fail "events.ndjson not created after commit"
fi

# ── Test 16: Stale-revision rejection does NOT emit event ────────────
if [ -f "$EVENTS_FILE" ]; then
  EVENTS_BEFORE=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
fi

echo '{
  "writes": [{
    "path": ".agent-atelier/work-items.json",
    "expected_revision": 1,
    "content": {"revision": 99}
  }]
}' | "$COMMIT" --root "$TMPDIR" 2>/dev/null || true

if [ -f "$EVENTS_FILE" ]; then
  EVENTS_AFTER=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
  if [ "$EVENTS_AFTER" -eq "$EVENTS_BEFORE" ]; then
    pass "No event emitted for rejected (stale-revision) commit"
  else
    fail "Event emitted for rejected commit"
  fi
else
  pass "No event emitted for rejected commit (no events file)"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "Mutation flow: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
