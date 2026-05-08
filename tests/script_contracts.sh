#!/usr/bin/env bash
# Script contracts — verify each scripts/* honors the contract from spec section "스크립트 계약".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/agent-atelier/scripts"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# ── Existence + executability (only assert what's expected to exist) ──
EXPECTED_SCRIPTS="init-helpers.sh wi lifecycle gate watchdog candidate validate"
for s in $EXPECTED_SCRIPTS; do
  SP="$SCRIPTS/$s"
  if [ -x "$SP" ]; then
    pass "$s exists and is executable"
  else
    fail "$s missing or not executable ($SP)"
  fi
done

# ── Helpers ────────────────────────────────────────────────────────────
_setup_tmp() {
  local tmp
  tmp=$(mktemp -d)
  (cd "$tmp" && git init -q)
  "$SCRIPTS/init-helpers.sh" --root "$tmp" >/dev/null
  echo "$tmp"
}

_assert_json() {
  local raw="$1" check="$2" name="$3"
  if echo "$raw" | python3 -c "import json,sys
d=json.load(sys.stdin)
$check" 2>/dev/null; then
    pass "$name"
  else
    fail "$name (output: ${raw:0:200})"
  fi
}

# ── init-helpers.sh smoke ─────────────────────────────────────────────
TMP=$(mktemp -d); (cd "$TMP" && git init -q)
INIT_OUT=$("$SCRIPTS/init-helpers.sh" --root "$TMP")
_assert_json "$INIT_OUT" "assert 'changed' in d and 'created' in d" \
  "init-helpers.sh returns JSON with changed+created"
[ -f "$TMP/.agent-atelier/work-items.json" ] && pass "init-helpers creates work-items.json" || fail "work-items.json not created"
rm -rf "$TMP"

# ── wi smoke ───────────────────────────────────────────────────────────
if [ -x "$SCRIPTS/wi" ]; then
  TMP=$(_setup_tmp)
  WI_OUT=$(cd "$TMP" && "$SCRIPTS/wi" list)
  _assert_json "$WI_OUT" "assert 'items' in d and 'revision' in d" \
    "wi list returns JSON with items+revision"

  WI_UPSERT=$(cd "$TMP" && "$SCRIPTS/wi" upsert '{"id":"WI-001","title":"Smoke","status":"ready","complexity":"simple"}')
  _assert_json "$WI_UPSERT" "
assert d.get('accepted') is True
assert 'committed_revision' in d
hint = d.get('native_task_sync')
assert hint is not None and hint.get('action') == 'create' and hint.get('new_status') == 'pending'
" "wi upsert (new) returns native_task_sync hint with action=create"

  WI_UPDATE=$(cd "$TMP" && "$SCRIPTS/wi" upsert '{"id":"WI-001","status":"implementing"}')
  _assert_json "$WI_UPDATE" "
hint = d.get('native_task_sync')
assert hint.get('action') == 'update' and hint.get('new_status') == 'in_progress'
" "wi upsert (existing) returns action=update + in_progress status"

  WI_SHOW=$(cd "$TMP" && "$SCRIPTS/wi" show WI-001)
  _assert_json "$WI_SHOW" "assert d.get('id') == 'WI-001'" \
    "wi show returns full WI JSON"
  rm -rf "$TMP"
fi

# ── lifecycle smoke ───────────────────────────────────────────────────
if [ -x "$SCRIPTS/lifecycle" ]; then
  TMP=$(_setup_tmp)
  (cd "$TMP" && "$SCRIPTS/wi" upsert '{"id":"WI-100","title":"LC","status":"ready","complexity":"simple"}' >/dev/null)
  LC_CLAIM=$(cd "$TMP" && "$SCRIPTS/lifecycle" claim WI-100 --owner exec-WI-100-1)
  _assert_json "$LC_CLAIM" "
assert d.get('accepted') is True
hint = d.get('native_task_sync')
assert hint and hint.get('new_status') == 'in_progress'
" "lifecycle claim returns native_task_sync new_status=in_progress"

  LC_HB=$(cd "$TMP" && "$SCRIPTS/lifecycle" heartbeat WI-100)
  _assert_json "$LC_HB" "assert d.get('accepted') is True" \
    "lifecycle heartbeat returns accepted"

  LC_RQ=$(cd "$TMP" && "$SCRIPTS/lifecycle" requeue WI-100 --reason "test")
  _assert_json "$LC_RQ" "
assert d.get('accepted') is True
hint = d.get('native_task_sync')
assert hint and hint.get('new_status') == 'pending'
" "lifecycle requeue returns native_task_sync new_status=pending"
  rm -rf "$TMP"
fi

# ── gate smoke ────────────────────────────────────────────────────────
if [ -x "$SCRIPTS/gate" ]; then
  TMP=$(_setup_tmp)
  G_LIST=$(cd "$TMP" && "$SCRIPTS/gate" list)
  _assert_json "$G_LIST" "assert 'open' in d and 'resolved' in d" \
    "gate list returns JSON with open+resolved"

  G_OPEN=$(cd "$TMP" && "$SCRIPTS/gate" open '{"question":"Test gate?","options":[{"label":"A","description":"yes"},{"label":"B","description":"no"}],"recommended_option":"A","blocking":false}')
  _assert_json "$G_OPEN" "
assert d.get('accepted') is True
assert d.get('gate_id', '').startswith('HDR-')
assert d.get('native_task_sync') is None
" "gate open returns gate_id without native_task_sync"

  HDR_ID=$(echo "$G_OPEN" | python3 -c "import json,sys; print(json.load(sys.stdin)['gate_id'])")
  G_RESOLVE=$(cd "$TMP" && "$SCRIPTS/gate" resolve "$HDR_ID" --chosen A)
  _assert_json "$G_RESOLVE" "assert d.get('accepted') is True" \
    "gate resolve returns accepted"
  rm -rf "$TMP"
fi

# ── watchdog smoke ────────────────────────────────────────────────────
if [ -x "$SCRIPTS/watchdog" ]; then
  TMP=$(_setup_tmp)
  WD_OUT=$(cd "$TMP" && "$SCRIPTS/watchdog" tick)
  _assert_json "$WD_OUT" "
assert 'actions' in d
assert 'alerts' in d
assert 'auto_transitioned' in d
assert 'native_task_sync' not in d
" "watchdog tick returns actions+alerts+auto_transitioned (no native_task_sync)"
  rm -rf "$TMP"
fi

# ── candidate smoke ───────────────────────────────────────────────────
if [ -x "$SCRIPTS/candidate" ]; then
  TMP=$(_setup_tmp)
  # Set up an implementing WI
  (cd "$TMP" && "$SCRIPTS/wi" upsert '{"id":"WI-200","title":"Cand","status":"ready","complexity":"simple"}' >/dev/null)
  (cd "$TMP" && "$SCRIPTS/lifecycle" claim WI-200 --owner exec-1 >/dev/null)
  C_ENQ=$(cd "$TMP" && "$SCRIPTS/candidate" enqueue WI-200 --branch test/b --commit deadbeef)
  _assert_json "$C_ENQ" "
assert d.get('accepted') is True
assert d.get('candidate_set_id', '').startswith('CS-')
assert d.get('native_task_sync') is not None
" "candidate enqueue returns candidate_set_id + native_task_sync"

  C_ACT=$(cd "$TMP" && "$SCRIPTS/candidate" activate)
  _assert_json "$C_ACT" "
assert d.get('accepted') is True
assert d.get('native_task_sync') is not None
" "candidate activate returns native_task_sync"

  C_CLR=$(cd "$TMP" && "$SCRIPTS/candidate" clear --reason demoted)
  _assert_json "$C_CLR" "
assert d.get('accepted') is True
" "candidate clear returns accepted"
  rm -rf "$TMP"
fi

# ── validate smoke ────────────────────────────────────────────────────
if [ -x "$SCRIPTS/validate" ]; then
  TMP=$(_setup_tmp)
  (cd "$TMP" && "$SCRIPTS/wi" upsert '{"id":"WI-300","title":"V","status":"ready","complexity":"simple"}' >/dev/null)
  (cd "$TMP" && "$SCRIPTS/lifecycle" claim WI-300 --owner exec-1 >/dev/null)
  (cd "$TMP" && "$SCRIPTS/candidate" enqueue WI-300 --branch test/v --commit cafef00d >/dev/null)
  C_ACT=$(cd "$TMP" && "$SCRIPTS/candidate" activate)
  CS_ID=$(echo "$C_ACT" | python3 -c "import json,sys; print(json.load(sys.stdin)['candidate_set_id'])")
  MANIFEST=$(cat <<JSON
{"id":"RUN-2026-05-08-01","candidate_set_id":"$CS_ID","work_item_ids":["WI-300"],"candidate_branch":"test/v","candidate_commit":"cafef00d","started_at":"2026-05-08T12:00:00Z","finished_at":"2026-05-08T12:05:00Z","status":"passed","checks":[{"name":"smoke","status":"passed"}]}
JSON
)
  V_OUT=$(cd "$TMP" && echo "$MANIFEST" | "$SCRIPTS/validate" record)
  _assert_json "$V_OUT" "
assert d.get('accepted') is True
hint = d.get('native_task_sync')
assert hint and hint.get('new_status') == 'in_progress'
" "validate record (passed) returns native_task_sync new_status=in_progress"
  rm -rf "$TMP"
fi

echo ""
echo "Script contracts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
