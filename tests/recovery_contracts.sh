#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  if grep -Fq "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  if grep -Fq "$pattern" "$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

RUN_SKILL="$ROOT/plugins/agent-atelier/skills/run/SKILL.md"
RECOVERY_PROTOCOL="$ROOT/plugins/agent-atelier/references/recovery-protocol.md"
ORCHESTRATOR_PROMPT="$ROOT/plugins/agent-atelier/references/prompts/orchestrator.md"
RECOVERY_SPEC="$ROOT/docs/design/recovery-spec.md"
SYSTEM_DESIGN="$ROOT/docs/design/system-design.md"
CLI_SURFACE="$ROOT/docs/design/cli-surface.md"
SESSION_LIMIT_RETRY="$ROOT/docs/design/session-limit-retry.md"

echo "=== Recovery Contract Tests ==="

assert_contains "$RUN_SKILL" "### Startup Resume Sweep (Run Once After Team Spawn)" \
  "run skill defines startup resume sweep"
assert_contains "$RUN_SKILL" 'cold-resume: owner session unavailable' \
  "run skill reclaims stranded implementing work on cold resume"
assert_contains "$RUN_SKILL" 'Create watchdog recovery job.' \
  "run skill documents watchdog recovery cron creation"
assert_contains "$RUN_SKILL" 'Create monitor poll job.' \
  "run skill documents monitor poll cron creation"

assert_contains "$RECOVERY_PROTOCOL" 'Cold resume assumes the previous runtime is gone.' \
  "recovery protocol forbids owner reuse during cold resume"
assert_contains "$RECOVERY_PROTOCOL" 'Do not separately invoke `/agent-atelier:monitors spawn` after calling `/agent-atelier:run`.' \
  "recovery protocol assigns runtime restoration to run skill"
assert_contains "$RECOVERY_PROTOCOL" 'Still-valid `implementing` leases from the crashed runtime are not cleared by `watchdog tick`.' \
  "recovery protocol separates mechanical tick from startup resume sweep"
assert_not_contains "$RECOVERY_PROTOCOL" 'Resume with the existing owner' \
  "recovery protocol no longer resumes crashed-runtime owners directly"

assert_contains "$ORCHESTRATOR_PROMPT" '## STARTUP RESUME SWEEP' \
  "orchestrator prompt defines startup resume sweep"
assert_contains "$ORCHESTRATOR_PROMPT" 'cold-resume: owner session unavailable' \
  "orchestrator prompt uses cold-resume reclaim reason"

assert_contains "$RECOVERY_SPEC" 'start `/agent-atelier:run`, which recreates the monitor poll cron, the watchdog recovery cron, and one startup resume sweep over the recovered state' \
  "recovery spec routes cold resume through run skill"
assert_contains "$RECOVERY_SPEC" 'Cold resume is distinct from session-limit recovery' \
  "recovery spec distinguishes cold resume from session-limit recovery"

assert_contains "$SYSTEM_DESIGN" 'Two-lane observation + recovery (`*/2` monitor poll + `*/15` watchdog pulse)' \
  "system design documents two-lane monitor/recovery topology"
assert_contains "$SYSTEM_DESIGN" 'run one startup resume sweep that immediately requeues stranded `implementing` WIs from the crashed runtime' \
  "system design documents immediate cold-resume reclaim"

assert_contains "$CLI_SURFACE" '`watchdog tick` is mechanical only.' \
  "cli surface constrains watchdog tick to mechanical recovery"
assert_contains "$CLI_SURFACE" 'creates the `*/15` watchdog recovery cron job' \
  "cli surface assigns watchdog recovery cron ownership to run"

assert_contains "$SESSION_LIMIT_RETRY" 'start `/agent-atelier:run`, which recreates monitors and both cron jobs' \
  "session-limit design delegates full restart recovery to run"

echo ""
echo "Recovery contracts: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
