#!/usr/bin/env bash
# Tests monitor scripts: existence, executability, NDJSON output format,
# heartbeat lease detection, gate change detection, event-tail filtering.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MONITORS_DIR="$ROOT/plugins/agent-atelier/scripts/monitors"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# Helper: validate a string is valid JSON
is_valid_json() {
  python3 -c "import json, sys; json.load(sys.stdin)" <<< "$1" 2>/dev/null
}

# Helper: extract a JSON field value
json_field() {
  python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], ''))" "$2" <<< "$1" 2>/dev/null
}

echo "=== Monitor Script Tests ==="

# ── Existence and executability ──────────────────────────────────────

EXPECTED_MONITORS="heartbeat-watch.sh gate-watch.sh event-tail.sh ci-status.sh branch-divergence.sh"
for script in $EXPECTED_MONITORS; do
  path="$MONITORS_DIR/$script"
  if [ -f "$path" ] && [ -x "$path" ]; then
    pass "monitor script '$script' exists and is executable"
  else
    fail "monitor script '$script' not found or not executable at $path"
  fi
done

# ── Help flags ───────────────────────────────────────────────────────

for script in heartbeat-watch.sh gate-watch.sh branch-divergence.sh; do
  if "$MONITORS_DIR/$script" --help >/dev/null 2>&1; then
    pass "$script --help exits 0"
  else
    fail "$script --help did not exit 0"
  fi
done

# ── event-tail unknown flag rejection ────────────────────────────────
EXIT_CODE=0
"$MONITORS_DIR/event-tail.sh" --bogus >/dev/null 2>&1 || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "event-tail.sh rejects unknown flag with exit 1"
else
  fail "event-tail.sh should exit 1 on unknown flag, got $EXIT_CODE"
fi

# ── heartbeat-watch: bad poll-interval rejected ──────────────────────
EXIT_CODE=0
"$MONITORS_DIR/heartbeat-watch.sh" --poll-interval abc 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "heartbeat-watch rejects non-integer poll-interval"
else
  fail "heartbeat-watch should exit 1 for bad poll-interval, got $EXIT_CODE"
fi

# ── branch-divergence: bad interval rejected ─────────────────────────
EXIT_CODE=0
"$MONITORS_DIR/branch-divergence.sh" --interval xyz 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "branch-divergence rejects non-integer interval"
else
  fail "branch-divergence should exit 1 for bad interval, got $EXIT_CODE"
fi

# ══════════════════════════════════════════════════════════════════════
# Integration tests — heartbeat-watch
# ══════════════════════════════════════════════════════════════════════

echo ""
echo "--- heartbeat-watch integration ---"

# Check jq availability (heartbeat-watch requires it)
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: jq not found — heartbeat-watch integration tests require jq"
else

  # Setup: create state dir with a work item whose lease expires soon
  HB_STATE="$TMPDIR/hb-state"
  mkdir -p "$HB_STATE"

  # Lease expiring 5 minutes from now (within the 10-min warning threshold)
  FUTURE=$(date -u -v+5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+5 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

  cat > "$HB_STATE/work-items.json" <<HBEOF
{
  "revision": 1,
  "updated_at": "2026-04-08T00:00:00Z",
  "items": [
    {
      "id": "WI-TEST-01",
      "status": "implementing",
      "revision": 1,
      "lease_expires_at": "$FUTURE",
      "owner_session_id": "test-session",
      "last_heartbeat_at": "2026-04-08T00:00:00Z"
    },
    {
      "id": "WI-TEST-02",
      "status": "ready",
      "revision": 1,
      "lease_expires_at": null,
      "owner_session_id": null
    }
  ]
}
HBEOF

  # Run heartbeat-watch for one cycle (poll-interval=1, kill after 2s)
  HB_OUTPUT="$TMPDIR/hb-output.txt"
  timeout 3 "$MONITORS_DIR/heartbeat-watch.sh" \
    --state-dir "$HB_STATE" \
    --poll-interval 1 \
    > "$HB_OUTPUT" 2>/dev/null || true

  # Should emit a heartbeat_warning for WI-TEST-01 (lease within 10 min)
  if [ -s "$HB_OUTPUT" ]; then
    FIRST_LINE=$(head -1 "$HB_OUTPUT")
    if is_valid_json "$FIRST_LINE"; then
      pass "heartbeat-watch emits valid JSON"
    else
      fail "heartbeat-watch output is not valid JSON: $FIRST_LINE"
    fi

    EVENT_TYPE=$(json_field "$FIRST_LINE" "event")
    if [ "$EVENT_TYPE" = "heartbeat_warning" ]; then
      pass "heartbeat-watch emits heartbeat_warning event"
    else
      fail "heartbeat-watch event type expected 'heartbeat_warning', got '$EVENT_TYPE'"
    fi

    WI_ID=$(json_field "$FIRST_LINE" "work_item_id")
    if [ "$WI_ID" = "WI-TEST-01" ]; then
      pass "heartbeat-watch targets correct work item (WI-TEST-01)"
    else
      fail "heartbeat-watch targeted '$WI_ID' instead of 'WI-TEST-01'"
    fi

    SEVERITY=$(json_field "$FIRST_LINE" "severity")
    if [ "$SEVERITY" = "warning" ]; then
      pass "heartbeat-watch severity is 'warning' for near-expiry lease"
    else
      fail "heartbeat-watch severity expected 'warning', got '$SEVERITY'"
    fi
  else
    fail "heartbeat-watch produced no output for near-expiry lease"
  fi

  # Test 2: expired lease should produce severity=expired
  HB_STATE2="$TMPDIR/hb-state2"
  mkdir -p "$HB_STATE2"

  PAST=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-5 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

  cat > "$HB_STATE2/work-items.json" <<HBEOF2
{
  "revision": 1,
  "updated_at": "2026-04-08T00:00:00Z",
  "items": [
    {
      "id": "WI-EXPIRED",
      "status": "implementing",
      "revision": 1,
      "lease_expires_at": "$PAST",
      "owner_session_id": "dead-session",
      "last_heartbeat_at": "2026-04-07T00:00:00Z"
    }
  ]
}
HBEOF2

  HB_OUTPUT2="$TMPDIR/hb-output2.txt"
  timeout 3 "$MONITORS_DIR/heartbeat-watch.sh" \
    --state-dir "$HB_STATE2" \
    --poll-interval 1 \
    > "$HB_OUTPUT2" 2>/dev/null || true

  if [ -s "$HB_OUTPUT2" ]; then
    FIRST_LINE2=$(head -1 "$HB_OUTPUT2")
    SEVERITY2=$(json_field "$FIRST_LINE2" "severity")
    if [ "$SEVERITY2" = "expired" ]; then
      pass "heartbeat-watch severity is 'expired' for past-due lease"
    else
      fail "heartbeat-watch severity expected 'expired', got '$SEVERITY2'"
    fi
  else
    fail "heartbeat-watch produced no output for expired lease"
  fi

  # Test 3: no implementing items → no output
  HB_STATE3="$TMPDIR/hb-state3"
  mkdir -p "$HB_STATE3"
  cat > "$HB_STATE3/work-items.json" <<'HBEOF3'
{
  "revision": 1,
  "updated_at": "2026-04-08T00:00:00Z",
  "items": [
    {"id": "WI-DONE", "status": "done", "revision": 1, "lease_expires_at": null}
  ]
}
HBEOF3

  HB_OUTPUT3="$TMPDIR/hb-output3.txt"
  timeout 3 "$MONITORS_DIR/heartbeat-watch.sh" \
    --state-dir "$HB_STATE3" \
    --poll-interval 1 \
    > "$HB_OUTPUT3" 2>/dev/null || true

  if [ ! -s "$HB_OUTPUT3" ]; then
    pass "heartbeat-watch silent when no implementing items"
  else
    fail "heartbeat-watch emitted output for non-implementing items"
  fi

fi  # end jq guard

# ══════════════════════════════════════════════════════════════════════
# Integration tests — gate-watch
# ══════════════════════════════════════════════════════════════════════

echo ""
echo "--- gate-watch integration ---"

GW_STATE="$TMPDIR/gw-state"
mkdir -p "$GW_STATE/human-gates/open"

# Start gate-watch in background with fast polling
GW_OUTPUT="$TMPDIR/gw-output.txt"
"$MONITORS_DIR/gate-watch.sh" \
  --state-dir "$GW_STATE" \
  --poll-interval 1 \
  > "$GW_OUTPUT" 2>/dev/null &
GW_PID=$!

# Wait for initial snapshot
sleep 2

# Add a gate file — should trigger gate_opened
cat > "$GW_STATE/human-gates/open/HDR-101.json" <<'EOF'
{"id": "HDR-101", "state": "open", "question": "Test?"}
EOF

# Wait for detection
sleep 3

# Remove the gate file — should trigger gate_resolved
rm -f "$GW_STATE/human-gates/open/HDR-101.json"

# Wait for detection
sleep 3

# Kill gate-watch
kill "$GW_PID" 2>/dev/null || true
wait "$GW_PID" 2>/dev/null || true

# Validate output
if [ -s "$GW_OUTPUT" ]; then
  LINE_COUNT=$(wc -l < "$GW_OUTPUT" | tr -d ' ')
  if [ "$LINE_COUNT" -ge 2 ]; then
    pass "gate-watch emitted >= 2 events (open + resolve)"
  else
    fail "gate-watch emitted $LINE_COUNT lines, expected >= 2"
  fi

  # Check first event (gate_opened)
  FIRST=$(head -1 "$GW_OUTPUT")
  if is_valid_json "$FIRST"; then
    pass "gate-watch event 1 is valid JSON"
  else
    fail "gate-watch event 1 is not valid JSON"
  fi

  FIRST_EVENT=$(json_field "$FIRST" "event")
  if [ "$FIRST_EVENT" = "gate_opened" ]; then
    pass "gate-watch first event is 'gate_opened'"
  else
    fail "gate-watch first event expected 'gate_opened', got '$FIRST_EVENT'"
  fi

  FIRST_GATE_ID=$(json_field "$FIRST" "gate_id")
  if [ "$FIRST_GATE_ID" = "HDR-101" ]; then
    pass "gate-watch reports correct gate_id 'HDR-101'"
  else
    fail "gate-watch gate_id expected 'HDR-101', got '$FIRST_GATE_ID'"
  fi

  # Check second event (gate_resolved)
  SECOND=$(sed -n '2p' "$GW_OUTPUT")
  if [ -n "$SECOND" ]; then
    SECOND_EVENT=$(json_field "$SECOND" "event")
    if [ "$SECOND_EVENT" = "gate_resolved" ]; then
      pass "gate-watch second event is 'gate_resolved'"
    else
      fail "gate-watch second event expected 'gate_resolved', got '$SECOND_EVENT'"
    fi
  fi
else
  fail "gate-watch produced no output"
fi

# ══════════════════════════════════════════════════════════════════════
# Integration tests — event-tail
# ══════════════════════════════════════════════════════════════════════

echo ""
echo "--- event-tail integration ---"

ET_STATE="$TMPDIR/et-state"
mkdir -p "$ET_STATE"
touch "$ET_STATE/events.ndjson"

# Start event-tail with filter in background
ET_OUTPUT="$TMPDIR/et-output.txt"
"$MONITORS_DIR/event-tail.sh" \
  --state-dir "$ET_STATE" \
  --filter state_committed \
  > "$ET_OUTPUT" 2>/dev/null &
ET_PID=$!

# Wait for tail to attach
sleep 1

# Append events — one matching, one not matching
echo '{"event":"state_committed","revision":1,"timestamp":"2026-04-08T00:00:00Z"}' >> "$ET_STATE/events.ndjson"
echo '{"event":"something_else","data":"ignored"}' >> "$ET_STATE/events.ndjson"
echo '{"event":"state_committed","revision":2,"timestamp":"2026-04-08T00:01:00Z"}' >> "$ET_STATE/events.ndjson"

# Wait for propagation
sleep 2

kill "$ET_PID" 2>/dev/null || true
wait "$ET_PID" 2>/dev/null || true

if [ -s "$ET_OUTPUT" ]; then
  ET_LINES=$(wc -l < "$ET_OUTPUT" | tr -d ' ')
  if [ "$ET_LINES" -eq 2 ]; then
    pass "event-tail filtered correctly: 2 matching events out of 3"
  else
    fail "event-tail expected 2 filtered lines, got $ET_LINES"
  fi

  ET_FIRST=$(head -1 "$ET_OUTPUT")
  if is_valid_json "$ET_FIRST"; then
    pass "event-tail output is valid JSON"
  else
    fail "event-tail output is not valid JSON"
  fi
else
  fail "event-tail produced no output"
fi

# Test: unfiltered mode passes everything
ET_OUTPUT2="$TMPDIR/et-output2.txt"
"$MONITORS_DIR/event-tail.sh" \
  --state-dir "$ET_STATE" \
  > "$ET_OUTPUT2" 2>/dev/null &
ET_PID2=$!

sleep 1

echo '{"event":"test_event","seq":1}' >> "$ET_STATE/events.ndjson"
echo '{"event":"another_event","seq":2}' >> "$ET_STATE/events.ndjson"

sleep 2

kill "$ET_PID2" 2>/dev/null || true
wait "$ET_PID2" 2>/dev/null || true

if [ -s "$ET_OUTPUT2" ]; then
  ET2_LINES=$(wc -l < "$ET_OUTPUT2" | tr -d ' ')
  if [ "$ET2_LINES" -eq 2 ]; then
    pass "event-tail unfiltered passes all new events"
  else
    fail "event-tail unfiltered expected 2 lines, got $ET2_LINES"
  fi
else
  fail "event-tail unfiltered produced no output"
fi

# ══════════════════════════════════════════════════════════════════════
# Integration tests — branch-divergence (requires git repo)
# ══════════════════════════════════════════════════════════════════════

echo ""
echo "--- branch-divergence integration ---"

# Runs inside the real repo, so git precondition is met
EXIT_CODE=0
"$MONITORS_DIR/branch-divergence.sh" --help >/dev/null 2>&1 || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "branch-divergence --help exits 0"
else
  fail "branch-divergence --help did not exit 0"
fi

# Test non-git directory rejection
BD_TMPDIR="$TMPDIR/not-a-repo"
mkdir -p "$BD_TMPDIR"
EXIT_CODE=0
(cd "$BD_TMPDIR" && "$MONITORS_DIR/branch-divergence.sh" --interval 1 --threshold 1) 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 2 ]; then
  pass "branch-divergence exits 2 outside git repo"
else
  fail "branch-divergence expected exit 2 outside git repo, got $EXIT_CODE"
fi

# ══════════════════════════════════════════════════════════════════════
# NDJSON format compliance — all events have required fields
# ══════════════════════════════════════════════════════════════════════

echo ""
echo "--- NDJSON format validation ---"

# Validate all collected outputs have timestamp and event fields
for output_file in "$TMPDIR"/hb-output.txt "$TMPDIR"/hb-output2.txt "$TMPDIR"/gw-output.txt "$TMPDIR"/et-output.txt; do
  if [ ! -s "$output_file" ]; then
    continue
  fi
  base=$(basename "$output_file")
  ALL_VALID=true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert 'event' in d, 'missing event field'
assert 'timestamp' in d or d.get('event') == 'state_committed', 'missing timestamp field'
" "$line" 2>/dev/null; then
      ALL_VALID=false
      break
    fi
  done < "$output_file"

  if $ALL_VALID; then
    pass "$base: all events have required NDJSON fields"
  else
    fail "$base: some events missing required fields"
  fi
done

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "Monitor scripts: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
