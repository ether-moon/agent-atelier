#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/plugins/agent-atelier/scripts/_plan_hash.py"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# Test: same plan structure → same hash regardless of execution-state fields
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
[ "$H1" = "$H2" ] && pass "status_class collapsing: execution-state fields do not change hash" \
                 || fail "execution-state fields changed hash ($H1 vs $H2)"

# Test: changing depends_on changes the hash
H3=$(python3 -c "
import sys; sys.path.insert(0, '$ROOT/plugins/agent-atelier/scripts')
from _plan_hash import wi_plan_hash
print(wi_plan_hash([
  {'id': 'WI-001', 'title': 't', 'description': 'd', 'depends_on': ['WI-000'],
   'owned_paths': ['x'], 'verify': ['v'], 'complexity': 'simple', 'status': 'implementing'}
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
